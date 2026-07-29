#!/usr/bin/env bash

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$TEST_DIR/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

BIN_DIR="$TEMP_DIR/bin"
KUBECONFIG="$TEMP_DIR/kubeconfig"
SECRET_FILE="$TEMP_DIR/runtime.env"
CAPTURED_ENV="$TEMP_DIR/captured.env"
CAPTURED_MANIFEST="$TEMP_DIR/manifest.yaml"
mkdir -p "$BIN_DIR"
touch "$KUBECONFIG"

cat >"$BIN_DIR/kubectl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$*" in
  *"get namespace"*) exit 0 ;;
  *"get secret"*) exit 1 ;;
  *"create secret generic"*)
    env_file=""
    for argument in "$@"; do
      case "$argument" in
        --from-env-file=*) env_file="${argument#*=}" ;;
      esac
    done
    [[ -n "$env_file" ]]
    cp "$env_file" "$CAPTURED_ENV"
    printf '%s\n' 'apiVersion: v1' 'kind: Secret' 'metadata:' '  name: test' 'type: Opaque' 'data:'
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
      encoded="$(printf '%s' "$value" | base64 | tr -d '\n')"
      printf '  %s: %s\n' "$key" "$encoded"
    done <"$env_file"
    ;;
  *"apply -f"*)
    manifest="${@: -1}"
    cp "$manifest" "$CAPTURED_MANIFEST"
    ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$BIN_DIR/kubectl"

printf '%s\r\n%s\r\n%s' \
  'POSTGRES_PASSWORD=file password with = and # hash' \
  'TELEGRAM_BOT_TOKEN=file-token' \
  'TELEGRAM_CHAT_ID=-100123' >"$SECRET_FILE"

PATH="$BIN_DIR:$PATH" \
  CAPTURED_ENV="$CAPTURED_ENV" \
  CAPTURED_MANIFEST="$CAPTURED_MANIFEST" \
  KUBECONFIG="$KUBECONFIG" \
  APP_SECRET_FILE="$SECRET_FILE" \
  TELEGRAM_BOT_TOKEN="environment-token=override" \
  "$INFRA_ROOT/scripts/apply-runtime-secrets.sh" >/dev/null

grep -Fxq 'POSTGRES_PASSWORD=file password with = and # hash' "$CAPTURED_ENV"
grep -Fxq 'TELEGRAM_BOT_TOKEN=environment-token=override' "$CAPTURED_ENV"
grep -Fxq 'TELEGRAM_CHAT_ID=-100123' "$CAPTURED_ENV"

postgres_password="$(
  awk '/POSTGRES_PASSWORD:/ {print $2}' "$CAPTURED_MANIFEST" |
    base64 --decode
)"
telegram_token="$(
  awk '/TELEGRAM_BOT_TOKEN:/ {print $2}' "$CAPTURED_MANIFEST" |
    base64 --decode
)"
[[ "$postgres_password" == 'file password with = and # hash' ]]
[[ "$telegram_token" == 'environment-token=override' ]]
echo "runtime secret tests: OK"
