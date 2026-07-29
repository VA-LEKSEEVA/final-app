#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

for command in terraform ansible-playbook kubectl jq ssh ssh-keygen curl openssl make; do
  require_command "$command"
done

require_nonempty "GITOPS_URL" "${GITOPS_URL:-}"
require_nonempty "APP_HOST" "${APP_HOST:-}"

if is_example_domain "$APP_HOST"; then
  die "APP_HOST must be a real domain you control; example/placeholder domains are rejected"
fi
validate_hostname "$APP_HOST" || die "APP_HOST is not a valid fully-qualified hostname: $APP_HOST"

if [[ ! "$GITOPS_URL" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/[^[:space:]?#]+\.git$ ]]; then
  die "GITOPS_URL must be an HTTPS Git repository URL without embedded credentials and ending in .git"
fi
if [[ "$GITOPS_URL" == *"<"* || "$GITOPS_URL" == *">"* || "$GITOPS_URL" == *example* || "$GITOPS_URL" == *"@"* ]]; then
  die "GITOPS_URL contains a placeholder; provide the real GitOps repository URL"
fi
if [[ -n "${GITOPS_TOKEN:-}" ]]; then
  require_nonempty "GITOPS_USERNAME" "${GITOPS_USERNAME:-}"
  [[ "$GITOPS_USERNAME" != *$'\n'* && "$GITOPS_TOKEN" != *$'\n'* ]] ||
    die "GitOps credentials must not contain newlines"
fi

case "$WAIT_TIMEOUT" in
  '' | *[!0-9]*) die "WAIT_TIMEOUT must be a positive integer number of seconds" ;;
esac
((WAIT_TIMEOUT > 0)) || die "WAIT_TIMEOUT must be greater than zero"
case "$WAIT_DNS_TIMEOUT" in
  '' | *[!0-9]*) die "WAIT_DNS_TIMEOUT must be a positive integer number of seconds" ;;
esac
((WAIT_DNS_TIMEOUT > 0)) || die "WAIT_DNS_TIMEOUT must be greater than zero"
case "$MIN_ARGO_APPS" in
  '' | *[!0-9]*) die "MIN_ARGO_APPS must be a positive integer" ;;
esac
((MIN_ARGO_APPS > 0)) || die "MIN_ARGO_APPS must be greater than zero"

if [[ -n "${TF_VARS_FILE:-}" ]]; then
  [[ -f "$TF_VARS_FILE" ]] || die "TF_VARS_FILE does not exist: $TF_VARS_FILE"
fi

if ! terraform -chdir="$TF_DIR" fmt -check -recursive >/dev/null; then
  die "Terraform files are not formatted; run terraform -chdir=$TF_DIR fmt -recursive"
fi

terraform_outputs="$(terraform -chdir="$TF_DIR" output -json 2>/dev/null || true)"
if [[ -z "$terraform_outputs" || "$terraform_outputs" == "{}" ]]; then
  variables_file=""
  [[ -f "$TF_DIR/terraform.tfvars" ]] && variables_file="$TF_DIR/terraform.tfvars"
  [[ -n "${TF_VARS_FILE:-}" ]] && variables_file="$TF_VARS_FILE"
  manages_dns=true
  if [[ -n "$variables_file" ]] &&
    grep -Eq '^[[:space:]]*manage_dns_record[[:space:]]*=[[:space:]]*false' "$variables_file"; then
    manages_dns=false
  fi
  if [[ "$manages_dns" == false ]]; then
    :
  elif [[ -n "${TF_VAR_dns_zone_id:-}" ]]; then
    [[ "$TF_VAR_dns_zone_id" =~ ^dns[a-z0-9]+$ && ${#TF_VAR_dns_zone_id} -ge 8 ]] ||
      die "TF_VAR_dns_zone_id must be a real Yandex Cloud DNS zone ID"
  elif [[ -f "$TF_DIR/terraform.tfvars" ]]; then
    grep -Eq '^[[:space:]]*dns_zone_id[[:space:]]*=[[:space:]]*"[^"]+"' "$TF_DIR/terraform.tfvars" ||
      die "first bootstrap requires dns_zone_id in terraform.tfvars so Terraform can create APP_HOST automatically"
  elif [[ -n "${TF_VARS_FILE:-}" ]]; then
    grep -Eq '^[[:space:]]*dns_zone_id[[:space:]]*=[[:space:]]*"[^"]+"' "$TF_VARS_FILE" ||
      die "first bootstrap requires dns_zone_id in TF_VARS_FILE so Terraform can create APP_HOST automatically"
  else
    die "first bootstrap requires terraform.tfvars (or TF_VARS_FILE) with a real dns_zone_id"
  fi
fi

log "Preflight passed"
log "Application host: $APP_HOST"
log "GitOps repository: $GITOPS_URL"

app_ip="$(tf_output_raw_optional app_public_ip)"
if [[ -n "$app_ip" ]] && command -v dig >/dev/null 2>&1; then
  resolved_ips="$(dig +short A "$APP_HOST" | sort -u)"
  if [[ -z "$resolved_ips" ]]; then
    warn "$APP_HOST does not resolve yet; create an A record pointing to $app_ip before cert-manager runs"
  elif ! printf '%s\n' "$resolved_ips" | grep -Fxq "$app_ip"; then
    die "$APP_HOST resolves to ${resolved_ips//$'\n'/, }, but Terraform app_public_ip is $app_ip"
  fi
fi
