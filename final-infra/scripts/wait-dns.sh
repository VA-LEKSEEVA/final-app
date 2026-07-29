#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_command terraform
require_command dig
require_nonempty "APP_HOST" "${APP_HOST:-}"
is_example_domain "$APP_HOST" && die "APP_HOST must not be an example/placeholder domain"

app_ip="$(tf_output_raw_optional app_public_ip)"
require_nonempty "Terraform output app_public_ip" "$app_ip"

dns_matches() {
  dig +short A "$APP_HOST" | grep -Fxq "$app_ip"
}

log "Waiting for $APP_HOST to resolve to $app_ip"
wait_until "$WAIT_DNS_TIMEOUT" 10 "DNS A record $APP_HOST -> $app_ip" dns_matches
log "DNS is ready: $APP_HOST -> $app_ip"
