#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_command terraform

state_file="$TF_DIR/terraform.tfstate"
if [[ -s "$state_file" ]]; then
  log "Destroying Terraform-managed infrastructure"
  args=(-auto-approve -input=false)
  if [[ -n "${TF_VARS_FILE:-}" ]]; then
    [[ -f "$TF_VARS_FILE" ]] || die "TF_VARS_FILE does not exist: $TF_VARS_FILE"
    args+=("-var-file=$TF_VARS_FILE")
  fi

  terraform -chdir="$TF_DIR" init -input=false
  terraform -chdir="$TF_DIR" destroy "${args[@]}"
else
  log "No local Terraform state found; nothing to destroy"
fi

cleanup_file "$KUBECONFIG"
cleanup_file "$INVENTORY"
cleanup_file "$INFRA_ROOT/known_hosts"
find "$INFRA_ROOT" -maxdepth 1 -type f -name '.backup-secret.*.yaml' -delete
find "$INFRA_ROOT" -maxdepth 1 -type f -name '.backup-secret.*.env' -delete
find "$INFRA_ROOT" -maxdepth 1 -type f -name '.runtime-secret.*.yaml' -delete
find "$INFRA_ROOT" -maxdepth 1 -type f -name '.runtime-secret.*.env' -delete
log "Infrastructure destroyed; generated local files removed"
