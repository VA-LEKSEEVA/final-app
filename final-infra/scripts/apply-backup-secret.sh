#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_command terraform
require_command jq
require_command kubectl
require_file "$KUBECONFIG"

outputs="$(tf_output_json)" || die "cannot read Terraform outputs"

read_output_optional() {
  local name="$1"
  jq -r --arg name "$name" '.[$name].value // empty' <<<"$outputs"
}

bucket="$(read_output_optional backup_bucket)"
[[ -n "$bucket" ]] || bucket="${BACKUP_BUCKET:-}"
require_nonempty "backup bucket output or BACKUP_BUCKET" "$bucket"
endpoint="$(jq -r '.backup_s3_endpoint.value // "https://storage.yandexcloud.net"' <<<"$outputs")"
access_key="$(read_output_optional backup_access_key)"
secret_key="$(read_output_optional backup_secret_key)"
session_token="${AWS_SESSION_TOKEN:-}"
[[ -n "$access_key" ]] || access_key="${AWS_ACCESS_KEY_ID:-}"
[[ -n "$secret_key" ]] || secret_key="${AWS_SECRET_ACCESS_KEY:-}"
require_nonempty "backup access key output or AWS_ACCESS_KEY_ID" "$access_key"
require_nonempty "backup secret key output or AWS_SECRET_ACCESS_KEY" "$secret_key"
namespace="$(jq -r '.backup_namespace.value // "guestbook-prod"' <<<"$outputs")"
secret_name="$(jq -r '.backup_secret_name.value // "backup-s3-creds"' <<<"$outputs")"

[[ "$namespace" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "invalid backup namespace: $namespace"
[[ "$secret_name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "invalid backup secret name: $secret_name"

kubectl_cmd get namespace "$namespace" >/dev/null 2>&1 ||
  kubectl_cmd create namespace "$namespace" >/dev/null

secret_env="$(mktemp "${TMPDIR:-/tmp}/final-infra-backup-secret.XXXXXX.env")"
manifest="$(mktemp "${TMPDIR:-/tmp}/final-infra-backup-secret.XXXXXX.yaml")"
trap 'rm -f "$secret_env" "$manifest"' EXIT
chmod 0600 "$secret_env" "$manifest"

cat >"$secret_env" <<EOF
AWS_ACCESS_KEY_ID=$access_key
AWS_SECRET_ACCESS_KEY=$secret_key
AWS_ENDPOINT_URL=$endpoint
BACKUP_BUCKET=$bucket
S3_BUCKET=$bucket
EOF
if [[ -n "$session_token" ]]; then
  printf 'AWS_SESSION_TOKEN=%s\n' "$session_token" >>"$secret_env"
fi
kubectl_cmd -n "$namespace" create secret generic "$secret_name" \
  --from-env-file="$secret_env" \
  --dry-run=client -o yaml >"$manifest"

kubectl_cmd apply -f "$manifest" >/dev/null
log "Applied backup secret $namespace/$secret_name (secret values were not printed)"
