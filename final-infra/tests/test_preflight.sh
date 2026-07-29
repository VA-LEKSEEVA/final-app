#!/usr/bin/env bash

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$TEST_DIR/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
BIN_DIR="$TEMP_DIR/bin"
mkdir -p "$BIN_DIR"

for command in ansible-playbook kubectl jq ssh ssh-keygen curl openssl make; do
  cat >"$BIN_DIR/$command" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$BIN_DIR/$command"
done

cat >"$BIN_DIR/terraform" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"output -json"* ]]; then
  printf '{"server_public_ip":{"value":"203.0.113.10"}}\n'
fi
exit 0
EOF
chmod +x "$BIN_DIR/terraform"

run_preflight() {
  PATH="$BIN_DIR:/usr/bin:/bin" \
    TF_DIR="$TEMP_DIR/tf" \
    WAIT_TIMEOUT=30 \
    GITOPS_URL="$1" \
    APP_HOST="$2" \
    "$INFRA_ROOT/scripts/preflight.sh"
}
mkdir -p "$TEMP_DIR/tf"

if run_preflight "https://gitlab.com/user/repo.git" "guestbook.example.ru" >/dev/null 2>&1; then
  echo "example domain must be rejected" >&2
  exit 1
fi

if run_preflight "https://gitlab.com/<user>/repo.git" "guestbook.real-domain.ru" >/dev/null 2>&1; then
  echo "placeholder Git URL must be rejected" >&2
  exit 1
fi

run_preflight "https://gitlab.com/user/repo.git" "guestbook.real-domain.ru" >/dev/null
echo "preflight tests: OK"
