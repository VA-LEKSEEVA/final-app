#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_command terraform
require_command jq
require_command ssh
require_command ssh-keyscan

outputs="$(tf_output_json)" || die "cannot read Terraform outputs; run make tf-apply first"
nodes="$(jq -ce '
  def normalize:
    if type == "array" then .
    elif type == "object" then
      to_entries | map(
        if (.value | type) == "object"
        then .value + {name: (.value.name // .key)}
        else {name: .key, public_ip: .value}
        end
      )
    else [] end;
  (
    if (.nodes.value? != null) then .nodes.value
    elif (.instances.value? != null) then .instances.value
    elif (.vm_instances.value? != null) then .vm_instances.value
    else empty
    end
  ) | normalize
' <<<"$outputs" 2>/dev/null || true)"

if [[ -z "$nodes" || "$nodes" == "[]" ]]; then
  die "Terraform must expose nodes, instances, or vm_instances as an array/object"
fi

node_count="$(jq 'length' <<<"$nodes")"
((node_count == 3)) || die "expected exactly 3 cluster nodes, Terraform returned $node_count"

duplicates="$(
  {
    jq -r 'sort_by(.name // "") | group_by(.name // "")[] |
      select((.[0].name // "") != "" and length > 1) |
      "name=" + .[0].name' <<<"$nodes"
    jq -r 'sort_by(.public_ip // .ip // "") | group_by(.public_ip // .ip // "")[] |
      select((.[0].public_ip // .[0].ip // "") != "" and length > 1) |
      "public_ip=" + (.[0].public_ip // .[0].ip)' <<<"$nodes"
    jq -r 'sort_by(.private_ip // "") | group_by(.private_ip // "")[] |
      select((.[0].private_ip // "") != "" and length > 1) |
      "private_ip=" + .[0].private_ip' <<<"$nodes"
  } | sed '/^$/d'
)"
[[ -z "$duplicates" ]] || die "duplicate nodes in Terraform outputs: ${duplicates//$'\n'/, }"

ssh_user="$(jq -r '.ssh_user.value // empty' <<<"$outputs")"
ssh_private_key_path="$(jq -r '.ssh_private_key_path.value // empty' <<<"$outputs")"
[[ -n "$ssh_user" ]] || ssh_user="ubuntu"
[[ -n "$ssh_private_key_path" ]] || ssh_private_key_path="$HOME/.ssh/id_ed25519"
ssh_private_key_path="$(expand_home_path "$ssh_private_key_path")"
require_file "$ssh_private_key_path"
known_hosts_target="$INFRA_ROOT/known_hosts"
if [[ "$INVENTORY" != "$TF_DIR/inventory.ini" ]]; then
  known_hosts_target="$(dirname "$INVENTORY")/known_hosts"
fi

server_count="$(jq '[.[] | select((.role // .k3s_role // "") == "server")] | length' <<<"$nodes")"
if ((server_count == 0)); then
  nodes="$(jq '
    sort_by(.name) |
    to_entries |
    map(.value + {role: (if .key == 0 then "server" else "agent" end)})
  ' <<<"$nodes")"
elif ((server_count != 1)); then
  die "expected exactly one server node, found $server_count"
fi

for index in $(seq 0 $((node_count - 1))); do
  name="$(jq -r ".[$index].name // empty" <<<"$nodes")"
  ip="$(jq -r ".[$index].public_ip // .[$index].ip // empty" <<<"$nodes")"
  private_ip="$(jq -r ".[$index].private_ip // empty" <<<"$nodes")"
  role="$(jq -r ".[$index].role // .[$index].k3s_role // empty" <<<"$nodes")"
  require_nonempty "node name at index $index" "$name"
  require_nonempty "public IP for node $name" "$ip"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid Ansible host name: $name"
  validate_ipv4 "$ip" || die "invalid public IPv4 address for node $name: $ip"
  if [[ -n "$private_ip" ]]; then
    validate_ipv4 "$private_ip" || die "invalid private IPv4 address for node $name: $private_ip"
  fi
  [[ "$role" == "server" || "$role" == "agent" ]] ||
    die "invalid role for node $name: ${role:-empty}; expected server or agent"
done

inventory_body="$(
  {
    printf '[k3s_server]\n'
    jq -r '.[] | select((.role // .k3s_role) == "server") |
      "\(.name) ansible_host=\(.public_ip // .ip) k3s_role=server" +
      (if (.private_ip // "") != "" then " k3s_private_ip=\(.private_ip)" else "" end)' <<<"$nodes"
    printf '\n[k3s_agents]\n'
    jq -r '.[] | select((.role // .k3s_role) != "server") |
      "\(.name) ansible_host=\(.public_ip // .ip) k3s_role=agent" +
      (if (.private_ip // "") != "" then " k3s_private_ip=\(.private_ip)" else "" end)' <<<"$nodes"
    printf '\n[k3s_cluster:children]\nk3s_server\nk3s_agents\n'
    printf '\n[k3s_cluster:vars]\n'
    printf 'ansible_user=%s\n' "$ssh_user"
    printf 'ansible_ssh_private_key_file=%s\n' "$ssh_private_key_path"
    printf 'ansible_python_interpreter=/usr/bin/python3\n'
    printf 'ansible_ssh_common_args=-o StrictHostKeyChecking=yes -o UserKnownHostsFile=%s\n' "$known_hosts_target"
  }
)"

known_hosts_temp="$(mktemp "${TMPDIR:-/tmp}/final-infra-known-hosts.XXXXXX")"
host_key_temp="$(mktemp "${TMPDIR:-/tmp}/final-infra-host-key.XXXXXX")"
trap 'rm -f "$known_hosts_temp" "$host_key_temp"' EXIT

scan_host_key() {
  local ip="$1"
  : >"$host_key_temp"
  ssh-keyscan -T 5 -H "$ip" >"$host_key_temp" 2>/dev/null && [[ -s "$host_key_temp" ]]
}

for ip in $(jq -r '.[] | .public_ip // .ip // empty' <<<"$nodes" | sort -u); do
  log "Waiting for SSH host key on $ip"
  wait_until "$WAIT_TIMEOUT" 5 "SSH host key on $ip" scan_host_key "$ip"
  cat "$host_key_temp" >>"$known_hosts_temp"
done

sort -u -o "$known_hosts_temp" "$known_hosts_temp"

ssh_ready() {
  local ip="$1"
  ssh \
    -i "$ssh_private_key_path" \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$known_hosts_temp" \
    "$ssh_user@$ip" true </dev/null >/dev/null 2>&1
}

for ip in $(jq -r '.[] | .public_ip // .ip // empty' <<<"$nodes" | sort -u); do
  log "Waiting for SSH authentication on $ip"
  wait_until "$WAIT_TIMEOUT" 5 "SSH authentication on $ip" ssh_ready "$ip"
done

printf '%s\n' "$inventory_body" | atomic_write "$INVENTORY" 0600
atomic_write "$known_hosts_target" 0600 <"$known_hosts_temp"

log "Generated inventory: $INVENTORY"
log "Generated pinned SSH host keys: $known_hosts_target"
