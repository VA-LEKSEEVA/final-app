#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_command kubectl
require_command terraform
require_command jq
require_command yc
require_file "$KUBECONFIG"

bucket="$(tf_output_raw_optional backup_bucket)"
namespace="$(tf_output_raw_optional backup_namespace)"
cronjob="$(tf_output_raw_optional backup_cronjob_name)"
[[ -n "$namespace" ]] || namespace="guestbook"
[[ -n "$cronjob" ]] || cronjob="guestbook-backup"
require_nonempty "Terraform output backup_bucket" "$bucket"

job_name="${cronjob}-manual-$(date +%s)"
before_objects="$(yc storage s3api list-objects --bucket "$bucket" --format json |
  jq -cS '[.Contents[]? | {Key, LastModified, Size}]')"
log "Starting backup Job $namespace/$job_name"
kubectl_cmd -n "$namespace" create job --from="cronjob/$cronjob" "$job_name" >/dev/null

if ! kubectl_cmd -n "$namespace" wait \
  --for=condition=complete "job/$job_name" --timeout="${WAIT_TIMEOUT}s"; then
  kubectl_cmd -n "$namespace" logs "job/$job_name" --all-containers=true >&2 || true
  die "backup Job did not complete"
fi

after_json="$(yc storage s3api list-objects --bucket "$bucket" --format json)"
after_objects="$(jq -cS '[.Contents[]? | {Key, LastModified, Size}]' <<<"$after_json")"
after_count="$(jq '[.Contents[]?] | length' <<<"$after_json")"
((after_count > 0)) || die "backup Job completed, but bucket $bucket has no objects"
[[ "$after_objects" != "$before_objects" ]] ||
  die "backup Job completed, but the bucket object list did not change"
log "Backup verified: bucket $bucket contains $after_count object(s) and changed after the manual Job"
