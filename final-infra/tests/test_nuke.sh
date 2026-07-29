#!/usr/bin/env bash

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$TEST_DIR/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

BIN_DIR="$TEMP_DIR/bin"
TF_DIR="$TEMP_DIR/tf"
KUBECONFIG="$TEMP_DIR/kubeconfig"
INVENTORY="$TEMP_DIR/inventory.ini"
mkdir -p "$BIN_DIR" "$TF_DIR"
touch "$KUBECONFIG" "$INVENTORY"

cat >"$BIN_DIR/terraform" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *" init "*) exit 0 ;;
  *" state list"*) exit 0 ;;
  *" destroy "*) echo "destroy must not run for empty state" >&2; exit 99 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$BIN_DIR/terraform"

PATH="$BIN_DIR:$PATH" \
  TF_DIR="$TF_DIR" \
  KUBECONFIG="$KUBECONFIG" \
  INVENTORY="$INVENTORY" \
  "$INFRA_ROOT/scripts/nuke.sh" >/dev/null

[[ ! -e "$KUBECONFIG" ]]
[[ ! -e "$INVENTORY" ]]
echo "nuke tests: OK"
