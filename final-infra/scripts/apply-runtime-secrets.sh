#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_command kubectl
require_command openssl
require_command base64
require_file "$KUBECONFIG"

namespace="${APP_NAMESPACE:-guestbook}"
secret_name="${APP_SECRET_NAME:-guestbook-runtime}"
secret_file="${APP_SECRET_FILE:-$INFRA_ROOT/runtime-secrets.env}"

[[ "$namespace" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "invalid APP_NAMESPACE: $namespace"
[[ "$secret_name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "invalid APP_SECRET_NAME: $secret_name"

keys=()
values=()
generated_postgres_password=false

set_value() {
  local key="$1"
  local value="$2"
  local index

  [[ "$value" != *$'\n'* ]] || die "$key must not contain a newline"
  for index in "${!keys[@]}"; do
    if [[ "${keys[$index]}" == "$key" ]]; then
      values[index]="$value"
      return
    fi
  done
  keys[${#keys[@]}]="$key"
  values[${#values[@]}]="$value"
}

get_value() {
  local key="$1"
  local index

  for index in "${!keys[@]}"; do
    if [[ "${keys[$index]}" == "$key" ]]; then
      printf '%s' "${values[$index]}"
      return
    fi
  done
}

if [[ -f "$secret_file" ]]; then
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    key="${key#"${key%%[![:space:]]*}"}"           # strip leading whitespace
    key="${key%"${key##*[![:space:]]}"}"           # strip trailing whitespace
    value="${value%$'\r'}"                          # tolerate CRLF line endings
    [[ -z "$key" || "$key" == \#* ]] && continue
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "invalid key in $secret_file: $key"
    set_value "$key" "$value"
  done <"$secret_file"
fi

if [[ -n "${POSTGRES_PASSWORD:-}" ]]; then
  set_value POSTGRES_PASSWORD "$POSTGRES_PASSWORD"
fi
if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  set_value TELEGRAM_BOT_TOKEN "$TELEGRAM_BOT_TOKEN"
fi
if [[ -n "${TELEGRAM_CHAT_ID:-}" ]]; then
  set_value TELEGRAM_CHAT_ID "$TELEGRAM_CHAT_ID"
fi

postgres_password="$(get_value POSTGRES_PASSWORD)"
if [[ -z "$postgres_password" ]]; then
  existing_password="$(
    kubectl_cmd -n "$namespace" get secret "$secret_name" \
      -o jsonpath='{.data.POSTGRES_PASSWORD}' 2>/dev/null | base64 --decode 2>/dev/null || true
  )"
  if [[ -n "$existing_password" ]]; then
    set_value POSTGRES_PASSWORD "$existing_password"
    log "Reusing the existing PostgreSQL password"
  else
    set_value POSTGRES_PASSWORD "$(openssl rand -base64 36 | tr -d '\n')"
    generated_postgres_password=true
    log "Generated a random PostgreSQL password"
  fi
fi

if [[ -z "$(get_value TELEGRAM_BOT_TOKEN)" || -z "$(get_value TELEGRAM_CHAT_ID)" ]]; then
  warn "Telegram credentials are not configured; alert delivery cannot be demonstrated"
  warn "Set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID or create $secret_file"
fi

kubectl_cmd get namespace "$namespace" >/dev/null 2>&1 ||
  kubectl_cmd create namespace "$namespace" >/dev/null

secret_env="$(mktemp "${TMPDIR:-/tmp}/final-infra-runtime-secret.XXXXXX.env")"
manifest="$(mktemp "${TMPDIR:-/tmp}/final-infra-runtime-secret.XXXXXX.yaml")"
trap 'rm -f "$secret_env" "$manifest"' EXIT
chmod 0600 "$secret_env" "$manifest"

for index in "${!keys[@]}"; do
  printf '%s=%s\n' "${keys[$index]}" "${values[$index]}" >>"$secret_env"
done

kubectl_cmd -n "$namespace" create secret generic "$secret_name" \
  --from-env-file="$secret_env" \
  --dry-run=client -o yaml >"$manifest"
kubectl_cmd apply -f "$manifest" >/dev/null
log "Applied runtime secret $namespace/$secret_name (values were not printed)"
if [[ "$generated_postgres_password" == true ]]; then
  warn "The generated password lives only in Kubernetes. Back it up securely if the database chart requires disaster recovery."
fi
