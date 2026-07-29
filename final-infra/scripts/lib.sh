#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="${TF_DIR:-$INFRA_ROOT/terraform/envs/prod}"
KUBECONFIG="${KUBECONFIG:-$INFRA_ROOT/kubeconfig}"
INVENTORY="${INVENTORY:-$TF_DIR/inventory.ini}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-900}"
WAIT_DNS_TIMEOUT="${WAIT_DNS_TIMEOUT:-300}"
MIN_ARGO_APPS="${MIN_ARGO_APPS:-6}"

log() {
  printf '==> %s\n' "$*"
}

warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is not installed: $1"
}

require_file() {
  [[ -f "$1" ]] || die "required file does not exist: $1"
}

require_nonempty() {
  local name="$1"
  local value="${2:-}"
  [[ -n "${value//[[:space:]]/}" ]] || die "$name must not be empty"
}

tf_output_json() {
  terraform -chdir="$TF_DIR" output -json
}

tf_output_raw_optional() {
  terraform -chdir="$TF_DIR" output -raw "$1" 2>/dev/null || true
}

kubectl_cmd() {
  KUBECONFIG="$KUBECONFIG" kubectl "$@"
}

is_example_domain() {
  local host
  host="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [[ "$host" == "example.com" ||
    "$host" == "example.net" ||
    "$host" == "example.org" ||
    "$host" == *.example.com ||
    "$host" == *.example.net ||
    "$host" == *.example.org ||
    "$host" == *.example.ru ||
    "$host" == *"<"* ||
    "$host" == *">"* ]]
}

validate_hostname() {
  local host="$1"
  [[ ${#host} -le 253 ]] || return 1
  [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

validate_ipv4() {
  local address="$1"
  local first second third fourth extra octet

  IFS=. read -r first second third fourth extra <<EOF
$address
EOF
  [[ -n "$first" && -n "$second" && -n "$third" && -n "$fourth" && -z "$extra" ]] || return 1
  for octet in "$first" "$second" "$third" "$fourth"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
    ((10#$octet <= 255)) || return 1
  done
}

wait_until() {
  local timeout="$1"
  local interval="$2"
  local description="$3"
  shift 3

  local deadline=$((SECONDS + timeout))
  until "$@"; do
    if ((SECONDS >= deadline)); then
      die "timed out after ${timeout}s waiting for ${description}"
    fi
    sleep "$interval"
  done
}

atomic_write() {
  local destination="$1"
  local mode="$2"
  local temp
  mkdir -p "$(dirname "$destination")"
  temp="$(mktemp "${destination}.tmp.XXXXXX")"
  cat >"$temp"
  chmod "$mode" "$temp"
  mv -f "$temp" "$destination"
}

cleanup_file() {
  local path="$1"
  if [[ -e "$path" ]]; then
    rm -f "$path"
  fi
}

expand_home_path() {
  local path="$1"
  if [[ "$path" == "~" ]]; then
    printf '%s\n' "$HOME"
  elif [[ "${path:0:2}" == \~/ ]]; then
    printf '%s/%s\n' "$HOME" "${path#\~/}"
  else
    printf '%s\n' "$path"
  fi
}
