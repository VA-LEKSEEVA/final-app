#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_command kubectl
require_command jq
require_command curl
require_command openssl
require_file "$KUBECONFIG"
require_nonempty "APP_HOST" "${APP_HOST:-}"
is_example_domain "$APP_HOST" && die "APP_HOST must not be an example/placeholder domain"
validate_hostname "$APP_HOST" || die "invalid APP_HOST: $APP_HOST"

failures=0
check() {
  local description="$1"
  shift
  printf '%-65s' "$description"
  if "$@" >/dev/null 2>&1; then
    printf 'OK\n'
  else
    printf 'FAIL\n'
    failures=$((failures + 1))
  fi
}

exactly_three_ready_nodes() {
  local json
  json="$(kubectl_cmd get nodes -o json)" || return 1
  [[ "$(jq '.items | length' <<<"$json")" == 3 ]] &&
    [[ "$(jq '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length' <<<"$json")" == 3 ]]
}

all_pods_healthy() {
  local json
  json="$(kubectl_cmd get pods -A -o json)" || return 1
  jq -e '
    def bad_reason:
      . == "CrashLoopBackOff" or . == "ImagePullBackOff" or
      . == "ErrImagePull" or . == "CreateContainerConfigError" or
      . == "CreateContainerError" or . == "InvalidImageName" or
      . == "RunContainerError";
    [.items[] | select(
      if .status.phase == "Succeeded" then
        false
      elif .metadata.deletionTimestamp != null then
        true
      elif .status.phase != "Running" then
        true
      else
        ([.status.initContainerStatuses[]?.state.waiting.reason // empty] | any(bad_reason)) or
        ([.status.containerStatuses[]?.state.waiting.reason // empty] | any(bad_reason)) or
        ([.status.containerStatuses[]?.state.terminated.reason // empty]
          | any(. == "Error" or . == "OOMKilled")) or
        ([.status.containerStatuses[]? | select(.ready != true)] | length > 0) or
        ([.status.containerStatuses[]? | select((.restartCount // 0) >= 5)] | length > 0)
      end
    )] | length == 0
  ' <<<"$json"
}

all_apps_green() {
  kubectl_cmd -n argocd get applications.argoproj.io -o json |
    jq -e '.items | length > 0 and all(.[]; .status.sync.status == "Synced" and .status.health.status == "Healthy")'
}

app_tls_works() {
  local body
  body="$(curl --fail --silent --show-error --location \
    --connect-timeout 10 --max-time 30 \
    --proto '=https' --tlsv1.2 "https://$APP_HOST/")" || return 1
  [[ -n "$body" ]]
}

certificate_valid() {
  local not_after epoch now
  not_after="$(printf '' | openssl s_client -servername "$APP_HOST" -connect "$APP_HOST:443" 2>/dev/null |
    openssl x509 -noout -enddate | cut -d= -f2-)" || return 1
  [[ -n "$not_after" ]] || return 1
  epoch="$(date -j -f '%b %e %T %Y %Z' "$not_after" +%s 2>/dev/null ||
    date -d "$not_after" +%s 2>/dev/null)" || return 1
  now="$(date +%s)"
  ((epoch - now > 86400))
}

grafana_dashboard_exists() {
  local count
  count="$(kubectl_cmd -n monitoring get configmaps \
    -l grafana_dashboard=1 -o json 2>/dev/null | jq '.items | length')" || return 1
  ((count > 0))
}

loki_exists() {
  kubectl_cmd get pods -A -l app.kubernetes.io/name=loki -o json |
    jq -e '.items | length > 0'
}

guestbook_workload_exists() {
  kubectl_cmd get deployments,statefulsets -A -l app.kubernetes.io/name=guestbook -o json |
    jq -e '.items | length > 0'
}

cert_manager_ready() {
  local json
  json="$(kubectl_cmd -n cert-manager get deployments -o json)" || return 1
  jq -e '
    .items | length >= 3 and
    all(.[];
      (.status.availableReplicas // 0) >= 1 and
      (.status.availableReplicas // 0) == (.status.replicas // 0)
    )
  ' <<<"$json"
}

ingress_controller_ready() {
  local json
  json="$(kubectl_cmd -n ingress-nginx get pods -l app.kubernetes.io/component=controller -o json)" || return 1
  jq -e '
    .items | length > 0 and
    all(.[];
      .status.phase == "Running" and
      all(.status.containerStatuses[]?; .ready == true)
    )
  ' <<<"$json"
}

application_certificate_ready() {
  local json
  json="$(kubectl_cmd get certificates.cert-manager.io -A -o json)" || return 1
  jq -e --arg host "$APP_HOST" '
    any(.items[];
      ((.spec.dnsNames // []) | index($host)) != null and
      any(.status.conditions[]?; .type == "Ready" and .status == "True")
    )
  ' <<<"$json"
}

backup_cronjob_exists() {
  local namespace cronjob
  namespace="$(tf_output_raw_optional backup_namespace)"
  cronjob="$(tf_output_raw_optional backup_cronjob_name)"
  [[ -n "$namespace" ]] || namespace="guestbook-prod"
  [[ -n "$cronjob" ]] || cronjob="guestbook-prod-backup"
  kubectl_cmd -n "$namespace" get cronjob "$cronjob"
}

backup_secret_exists() {
  local namespace secret_name
  namespace="$(tf_output_raw_optional backup_namespace)"
  secret_name="$(tf_output_raw_optional backup_secret_name)"
  [[ -n "$namespace" ]] || namespace="guestbook-prod"
  [[ -n "$secret_name" ]] || secret_name="backup-s3-creds"
  kubectl_cmd -n "$namespace" get secret "$secret_name"
}

all_checks_pass() {
  exactly_three_ready_nodes &&
    all_pods_healthy &&
    all_apps_green &&
    cert_manager_ready &&
    ingress_controller_ready &&
    guestbook_workload_exists &&
    application_certificate_ready &&
    app_tls_works &&
    certificate_valid &&
    grafana_dashboard_exists &&
    loki_exists &&
    backup_cronjob_exists &&
    backup_secret_exists
}

log "Waiting for the complete production checklist"
verification_deadline=$((SECONDS + WAIT_TIMEOUT))
until all_checks_pass >/dev/null 2>&1; do
  if ((SECONDS >= verification_deadline)); then
    warn "Verification timeout reached; printing the failed checks"
    break
  fi
  sleep 15
done

check "3 Kubernetes nodes are Ready" exactly_three_ready_nodes
check "No failed/crash-looping pods in any namespace" all_pods_healthy
check "All Argo CD Applications are Synced and Healthy" all_apps_green
check "cert-manager deployments are available" cert_manager_ready
check "ingress-nginx controller Pods are Ready" ingress_controller_ready
check "Guestbook workload exists" guestbook_workload_exists
check "Application Certificate is Ready" application_certificate_ready
check "Application opens over trusted HTTPS" app_tls_works
check "TLS certificate is valid for more than 24 hours" certificate_valid
check "Grafana dashboard ConfigMap exists" grafana_dashboard_exists
check "Loki pods exist" loki_exists
check "Backup CronJob exists" backup_cronjob_exists
check "Backup Secret exists" backup_secret_exists

printf '\nCurrent cluster state:\n'
kubectl_cmd get nodes
kubectl_cmd get pods -A
kubectl_cmd -n argocd get applications.argoproj.io \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'

((failures == 0)) || die "$failures verification checks failed"
log "Automated verification passed"
warn "Telegram delivery is an external side effect. Trigger an alert and confirm receipt manually during the demo."
