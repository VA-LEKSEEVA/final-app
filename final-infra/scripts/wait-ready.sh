#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_command kubectl
require_command jq
require_file "$KUBECONFIG"

# On any failure (including a wait timeout), print a strictly redacted snapshot
# of the cluster so the exact stuck Argo CD Application/pod is visible on the CI
# run page instead of an opaque timeout. Only non-sensitive status fields are
# emitted: never node names, IP addresses, free-text condition/event messages,
# or cloud folder/subnet/security-group/request identifiers. A final regex pass
# redacts any IPv4/IPv6 literal or hostname that might slip through.
redact_sensitive() {
  sed -E \
    -e 's/([0-9]{1,3}\.){3}[0-9]{1,3}/<ip>/g' \
    -e 's/([0-9a-fA-F]{1,4}:){2,}[0-9a-fA-F]{0,4}/<ipv6>/g' \
    -e 's/[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?){2,}/<host>/g'
}
dump_cluster_diagnostics() {
  local exit_code="$?"
  # Only emit diagnostics when the script is failing (timeout via die uses
  # exit 1, which would not fire an ERR trap, so an EXIT trap is used).
  ((exit_code != 0)) || return 0
  {
    printf '\n===== CLUSTER DIAGNOSTICS (exit %s) =====\n' "$exit_code"
    printf '\n--- Nodes (counts only) ---\n'
    kubectl_cmd get nodes -o json 2>/dev/null |
      jq -r '
        "total=\(.items | length)\t" +
        "ready=\([.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length)"
      ' 2>/dev/null || true
    printf '\n--- Argo CD Applications (sync / health / condition types) ---\n'
    kubectl_cmd -n argocd get applications.argoproj.io -o json 2>/dev/null |
      jq -r '
        .items[]? |
        "\(.metadata.name)\tsync=\(.status.sync.status // "?")\thealth=\(.status.health.status // "?")\t" +
        ("condtypes=" + ((.status.conditions // []) | map(.type) | unique | join(","))) +
        ("\tophase=" + (.status.operationState.phase // "-"))
      ' 2>/dev/null || true
    printf '\n--- Pods not Running/Ready (namespace / workload / reason) ---\n'
    kubectl_cmd get pods -A -o json 2>/dev/null |
      jq -r '
        .items[]? |
        select(
          (.status.phase != "Running" and .status.phase != "Succeeded") or
          ([.status.containerStatuses[]? | select(.ready != true)] | length > 0)
        ) |
        (.metadata.labels["app.kubernetes.io/name"] // (.metadata.ownerReferences[0].name // .metadata.name)) as $workload |
        "\(.metadata.namespace)/\($workload)\tphase=\(.status.phase)\t" +
        ("waiting=" + ([.status.containerStatuses[]?.state.waiting.reason // empty] | join(","))) +
        ("\trestarts=" + ([.status.containerStatuses[]?.restartCount // 0] | max | tostring))
      ' 2>/dev/null || true
    printf '\n--- Warning event reasons (namespace / reason / count) ---\n'
    kubectl_cmd get events -A --field-selector type=Warning \
      -o json 2>/dev/null |
      jq -r '
        [.items[]? | {ns: .metadata.namespace, reason: .reason}] |
        group_by([.ns, .reason]) |
        map("\(.[0].ns)\t\(.[0].reason)\tcount=\(length)") |
        .[]
      ' 2>/dev/null || true
    printf '===== END CLUSTER DIAGNOSTICS =====\n'
  } | redact_sensitive | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}" >&2

  local stuck
  stuck="$(kubectl_cmd -n argocd get applications.argoproj.io -o json 2>/dev/null |
    jq -r '[.items[]? | select(.status.sync.status != "Synced" or .status.health.status != "Healthy") | .metadata.name] | join(", ")' 2>/dev/null || true)"
  if [[ -n "$stuck" ]]; then
    printf '::error title=Argo CD not converged::Applications not Synced+Healthy: %s\n' "$stuck" |
      redact_sensitive >&2
  fi
}
trap dump_cluster_diagnostics EXIT

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
