#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_command terraform

log "Initializing Terraform state"
terraform -chdir="$TF_DIR" init -input=false

state_resources="$(terraform -chdir="$TF_DIR" state list 2>/dev/null || true)"
if [[ -n "$state_resources" ]]; then
  log "Destroying Terraform-managed infrastructure"
  args=(-auto-approve -input=false)
  if [[ -n "${TF_VARS_FILE:-}" ]]; then
    [[ -f "$TF_VARS_FILE" ]] || die "TF_VARS_FILE does not exist: $TF_VARS_FILE"
    args+=("-var-file=$TF_VARS_FILE")
  fi

  terraform -chdir="$TF_DIR" destroy "${args[@]}"
else
  log "Terraform state has no resources; nothing to destroy"
fi

cleanup_file "$KUBECONFIG"
cleanup_file "$INVENTORY"
cleanup_file "$INFRA_ROOT/known_hosts"
find "$INFRA_ROOT" -maxdepth 1 -type f -name '.backup-secret.*.yaml' -delete
find "$INFRA_ROOT" -maxdepth 1 -type f -name '.backup-secret.*.env' -delete
find "$INFRA_ROOT" -maxdepth 1 -type f -name '.runtime-secret.*.yaml' -delete
find "$INFRA_ROOT" -maxdepth 1 -type f -name '.runtime-secret.*.env' -delete
log "Infrastructure destroyed; generated local files removed"
