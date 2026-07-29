#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_command terraform
require_command jq
require_command kubectl
require_file "$KUBECONFIG"

outputs="$(tf_output_json)" || die "cannot read Terraform outputs"

read_output() {
  local name="$1"
  jq -er --arg name "$name" '.[$name].value | select(type == "string" and length > 0)' <<<"$outputs" 2>/dev/null ||
    die "required Terraform output is missing or empty: $name"
}

bucket="$(read_output backup_bucket)"
endpoint="$(jq -r '.backup_s3_endpoint.value // "https://storage.yandexcloud.net"' <<<"$outputs")"
access_key="$(read_output backup_access_key)"
secret_key="$(read_output backup_secret_key)"
namespace="$(jq -r '.backup_namespace.value // "guestbook"' <<<"$outputs")"
secret_name="$(jq -r '.backup_secret_name.value // "guestbook-backup"' <<<"$outputs")"

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
EOF
kubectl_cmd -n "$namespace" create secret generic "$secret_name" \
  --from-env-file="$secret_env" \
  --dry-run=client -o yaml >"$manifest"

kubectl_cmd apply -f "$manifest" >/dev/null
log "Applied backup secret $namespace/$secret_name (secret values were not printed)"
