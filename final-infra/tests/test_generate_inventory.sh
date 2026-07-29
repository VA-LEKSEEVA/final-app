#!/usr/bin/env bash

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$TEST_DIR/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

BIN_DIR="$TEMP_DIR/bin"
TF_DIR="$TEMP_DIR/tf"
INVENTORY="$TEMP_DIR/inventory.ini"
HOME="$TEMP_DIR/home"
mkdir -p "$BIN_DIR" "$TF_DIR" "$HOME/.ssh"
touch "$HOME/.ssh/id_ed25519"
chmod 0600 "$HOME/.ssh/id_ed25519"

cat >"$BIN_DIR/terraform" <<'EOF'
#!/usr/bin/env bash
cat "$MOCK_TF_OUTPUT"
EOF

cat >"$BIN_DIR/ssh-keyscan" <<'EOF'
#!/usr/bin/env bash
ip="${@: -1}"
printf '%s ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMockedHostKey\n' "$ip"
EOF

cat >"$BIN_DIR/ssh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$BIN_DIR/terraform" "$BIN_DIR/ssh-keyscan" "$BIN_DIR/ssh"

assert_contains() {
  local file="$1"
  local expected="$2"
  grep -Fq "$expected" "$file" || {
    printf 'Expected %s to contain: %s\n' "$file" "$expected" >&2
    cat "$file" >&2
    exit 1
  }
}

valid="$TEMP_DIR/valid.json"
cat >"$valid" <<EOF
{
  "nodes": {
    "value": [
      {"name":"server-1","role":"server","public_ip":"203.0.113.10","private_ip":"10.20.0.10"},
      {"name":"agent-1","role":"agent","public_ip":"203.0.113.11","private_ip":"10.20.0.11"},
      {"name":"agent-2","role":"agent","public_ip":"203.0.113.12","private_ip":"10.20.0.12"}
    ]
  },
  "ssh_user": {"value":"ubuntu"},
  "ssh_private_key_path": {"value":"~/.ssh/id_ed25519"}
}
EOF

PATH="$BIN_DIR:$PATH" \
  MOCK_TF_OUTPUT="$valid" \
  TF_DIR="$TF_DIR" \
  INVENTORY="$INVENTORY" \
  HOME="$HOME" \
  "$INFRA_ROOT/scripts/generate-inventory.sh"

assert_contains "$INVENTORY" "[k3s_server]"
assert_contains "$INVENTORY" "server-1 ansible_host=203.0.113.10 k3s_role=server k3s_private_ip=10.20.0.10"
assert_contains "$INVENTORY" "agent-2 ansible_host=203.0.113.12 k3s_role=agent k3s_private_ip=10.20.0.12"
assert_contains "$INVENTORY" "ansible_ssh_private_key_file=$HOME/.ssh/id_ed25519"
[[ "$(grep -c '^server-1 ' "$INVENTORY")" == 1 ]]
[[ -s "$TEMP_DIR/known_hosts" ]]

duplicate="$TEMP_DIR/duplicate.json"
cat >"$duplicate" <<EOF
{
  "nodes": {
    "value": [
      {"name":"server-1","role":"server","public_ip":"203.0.113.10"},
      {"name":"agent-1","role":"agent","public_ip":"203.0.113.11"},
      {"name":"agent-1","role":"agent","public_ip":"203.0.113.12"}
    ]
  },
  "ssh_private_key_path": {"value":"$HOME/.ssh/id_ed25519"}
}
EOF

if PATH="$BIN_DIR:$PATH" \
  MOCK_TF_OUTPUT="$duplicate" \
  TF_DIR="$TF_DIR" \
  INVENTORY="$INVENTORY" \
  HOME="$HOME" \
  "$INFRA_ROOT/scripts/generate-inventory.sh" >/dev/null 2>&1; then
  echo "duplicate node names must be rejected" >&2
  exit 1
fi

echo "generate-inventory tests: OK"
