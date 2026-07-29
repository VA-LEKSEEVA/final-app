#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_command make
require_command shellcheck

log "Checking shell scripts"
shellcheck -x -P "$SCRIPT_DIR" "$SCRIPT_DIR"/*.sh "$INFRA_ROOT"/tests/*.sh

log "Checking Makefile parsing"
make -C "$INFRA_ROOT" --no-print-directory help >/dev/null

log "Checking YAML syntax"
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
  python3 - "$INFRA_ROOT" <<'PY'
import pathlib
import sys
import yaml

root = pathlib.Path(sys.argv[1])
for path in sorted((root / "ansible").rglob("*.yml")):
    with path.open(encoding="utf-8") as stream:
        yaml.safe_load(stream)
    print(f"YAML OK: {path.relative_to(root)}")
PY
elif command -v ruby >/dev/null 2>&1; then
  ruby - "$INFRA_ROOT" <<'RUBY'
require "yaml"
root = ARGV.fetch(0)
Dir[File.join(root, "ansible", "**", "*.yml")].sort.each do |path|
  YAML.load_file(path)
  puts "YAML OK: #{path.delete_prefix(root + "/")}"
end
RUBY
else
  die "python3 with PyYAML or ruby is required to validate YAML"
fi

if command -v terraform >/dev/null 2>&1; then
  log "Checking Terraform formatting and validation"
  terraform -chdir="$TF_DIR" fmt -check -recursive
  terraform -chdir="$TF_DIR" init -backend=false -input=false
  terraform -chdir="$TF_DIR" validate
else
  warn "terraform is not installed; skipping Terraform validation"
fi

if command -v ansible-playbook >/dev/null 2>&1; then
  log "Checking Ansible syntax"
  temp_inventory="$(mktemp)"
  ansible_local_temp="$(mktemp -d "${TMPDIR:-/tmp}/final-infra-ansible-local.XXXXXX")"
  ansible_remote_temp="$(mktemp -d "${TMPDIR:-/tmp}/final-infra-ansible-remote.XXXXXX")"
  trap 'rm -f "$temp_inventory"; rm -rf "$ansible_local_temp" "$ansible_remote_temp"' EXIT
  cat >"$temp_inventory" <<'EOF'
[k3s_server]
server ansible_host=127.0.0.1
[k3s_agents]
agent1 ansible_host=127.0.0.1
agent2 ansible_host=127.0.0.1
[k3s_cluster:children]
k3s_server
k3s_agents
EOF
  ANSIBLE_LOCAL_TEMP="$ansible_local_temp" ANSIBLE_REMOTE_TEMP="$ansible_remote_temp" \
    ansible-playbook -i "$temp_inventory" "$INFRA_ROOT/ansible/playbook.yml" \
    --syntax-check \
    --extra-vars "gitops_repo_url=https://git.invalid/repo.git app_host=invalid.test kubeconfig_path=/tmp/kubeconfig"
else
  warn "ansible-playbook is not installed; skipping Ansible syntax check"
fi

log "Validation completed"
