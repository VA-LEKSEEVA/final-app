#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_command kubectl
require_command jq
require_file "$KUBECONFIG"

log "Waiting for Kubernetes API"
wait_until "$WAIT_TIMEOUT" 10 "Kubernetes API" kubectl_cmd version --request-timeout=5s

log "Waiting for exactly 3 Ready nodes"
nodes_ready() {
  local node_json count ready
  node_json="$(kubectl_cmd get nodes -o json 2>/dev/null)" || return 1
  count="$(jq '.items | length' <<<"$node_json")"
  ready="$(jq '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length' <<<"$node_json")"
  [[ "$count" == 3 && "$ready" == 3 ]]
}
wait_until "$WAIT_TIMEOUT" 10 "3 Ready nodes" nodes_ready

log "Waiting for Argo CD Applications to be discovered"
applications_exist() {
  local count
  count="$(kubectl_cmd -n argocd get applications.argoproj.io -o json 2>/dev/null | jq '.items | length')" || return 1
  ((count >= MIN_ARGO_APPS))
}
wait_until "$WAIT_TIMEOUT" 10 "at least $MIN_ARGO_APPS Argo CD Applications" applications_exist

log "Waiting for all Argo CD Applications to become Synced and Healthy"
applications_ready() {
  local json total ready
  json="$(kubectl_cmd -n argocd get applications.argoproj.io -o json 2>/dev/null)" || return 1
  total="$(jq '.items | length' <<<"$json")"
  ready="$(jq '[.items[] | select(.status.sync.status == "Synced" and .status.health.status == "Healthy")] | length' <<<"$json")"
  ((total >= MIN_ARGO_APPS && total == ready))
}
wait_until "$WAIT_TIMEOUT" 15 "all Argo CD Applications to be Synced and Healthy" applications_ready

log "Cluster and Argo CD are ready"
