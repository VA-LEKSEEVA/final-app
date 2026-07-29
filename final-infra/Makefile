SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help
.NOTPARALLEL:

ROOT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
TF_DIR := $(ROOT_DIR)/terraform/envs/prod
ANSIBLE_DIR := $(ROOT_DIR)/ansible
SCRIPTS_DIR := $(ROOT_DIR)/scripts

KUBECONFIG ?= $(ROOT_DIR)/kubeconfig
INVENTORY ?= $(TF_DIR)/inventory.ini
GITOPS_URL ?=
GITOPS_USERNAME ?= oauth2
GITOPS_TOKEN ?=
APP_HOST ?=
TF_VARS_FILE ?=
WAIT_TIMEOUT ?= 900
WAIT_DNS_TIMEOUT ?= 300
MIN_ARGO_APPS ?= 6

export KUBECONFIG
export INVENTORY
export GITOPS_URL
export GITOPS_USERNAME
export GITOPS_TOKEN
export APP_HOST
export TF_VARS_FILE
export WAIT_TIMEOUT
export WAIT_DNS_TIMEOUT
export MIN_ARGO_APPS
ifneq ($(strip $(APP_HOST)),)
export TF_VAR_app_host := $(APP_HOST)
endif

.PHONY: help validate test preflight tf-init tf-apply tf-destroy dns inventory ansible \
	apply-runtime-secrets apply-backup-secret wait verify backup-check bootstrap nuke \
	tf-apply-step dns-step inventory-step ansible-step apply-runtime-secrets-step \
	apply-backup-secret-step wait-step verify-step

help:
	@printf '%s\n' \
		'Usage:' \
		'  make bootstrap GITOPS_URL=$$GITOPS_URL APP_HOST=$$APP_HOST' \
		'  make nuke' \
		'' \
		'Targets:' \
		'  validate             Static validation of Makefile, shell, Terraform, and Ansible syntax' \
		'  test                 Run local shell behavior tests' \
		'  preflight            Validate tools, variables, credentials, and DNS inputs' \
		'  tf-init              terraform init' \
		'  tf-apply             terraform apply -auto-approve' \
		'  tf-destroy           terraform destroy -auto-approve' \
		'  dns                  Wait until APP_HOST resolves to the Terraform load-balancer IP' \
		'  inventory            Generate inventory.ini and kubeconfig from Terraform outputs' \
		'  ansible              Install k3s and bootstrap Argo CD' \
		'  apply-runtime-secrets Generate/apply app and Telegram runtime Secret' \
		'  apply-backup-secret  Generate/apply the backup Secret from Terraform outputs' \
		'  wait                 Wait for nodes and Argo CD Applications' \
		'  verify               Run the final deployment checklist' \
		'  backup-check         Run backup Job and verify an object appeared in Object Storage' \
		'  bootstrap            One command: Terraform -> inventory -> Ansible -> Secret -> wait -> verify' \
		'  nuke                 Destroy Terraform resources and remove generated local files'

validate:
	@"$(SCRIPTS_DIR)/validate.sh"

test:
	@for test_script in "$(ROOT_DIR)"/tests/test_*.sh; do \
		printf '=== %s ===\n' "$$(basename "$$test_script")"; \
		"$$test_script" || exit $$?; \
	done

preflight:
	@"$(SCRIPTS_DIR)/preflight.sh"

tf-init:
	@cd "$(TF_DIR)" && terraform init -input=false

tf-apply: preflight tf-apply-step

tf-apply-step: tf-init
	@args=(-auto-approve -input=false); \
	if [[ -n "$$TF_VARS_FILE" ]]; then args+=("-var-file=$$TF_VARS_FILE"); fi; \
	cd "$(TF_DIR)" && terraform apply "$${args[@]}"

tf-destroy: tf-init
	@args=(-auto-approve -input=false); \
	if [[ -n "$$TF_VARS_FILE" ]]; then args+=("-var-file=$$TF_VARS_FILE"); fi; \
	cd "$(TF_DIR)" && terraform destroy "$${args[@]}"

inventory:
	@"$(SCRIPTS_DIR)/generate-inventory.sh"

dns:
	@"$(SCRIPTS_DIR)/wait-dns.sh"

dns-step:
	@"$(SCRIPTS_DIR)/wait-dns.sh"

inventory-step:
	@"$(SCRIPTS_DIR)/generate-inventory.sh"

ansible:
	@cd "$(ANSIBLE_DIR)" && ansible-playbook \
		-i "$(INVENTORY)" \
		playbook.yml \
		--extra-vars "$$(jq -cn \
			--arg gitops_repo_url "$$GITOPS_URL" \
			--arg app_host "$$APP_HOST" \
			--arg kubeconfig_path "$$KUBECONFIG" \
			'{gitops_repo_url:$$gitops_repo_url,app_host:$$app_host,kubeconfig_path:$$kubeconfig_path}')"

ansible-step:
	@cd "$(ANSIBLE_DIR)" && ansible-playbook \
		-i "$(INVENTORY)" \
		playbook.yml \
		--extra-vars "$$(jq -cn \
			--arg gitops_repo_url "$$GITOPS_URL" \
			--arg app_host "$$APP_HOST" \
			--arg kubeconfig_path "$$KUBECONFIG" \
			'{gitops_repo_url:$$gitops_repo_url,app_host:$$app_host,kubeconfig_path:$$kubeconfig_path}')"

apply-backup-secret:
	@"$(SCRIPTS_DIR)/apply-backup-secret.sh"

apply-runtime-secrets:
	@"$(SCRIPTS_DIR)/apply-runtime-secrets.sh"

apply-runtime-secrets-step:
	@"$(SCRIPTS_DIR)/apply-runtime-secrets.sh"

apply-backup-secret-step:
	@"$(SCRIPTS_DIR)/apply-backup-secret.sh"

wait:
	@"$(SCRIPTS_DIR)/wait-ready.sh"

wait-step:
	@"$(SCRIPTS_DIR)/wait-ready.sh"

verify:
	@"$(SCRIPTS_DIR)/verify.sh"

verify-step:
	@"$(SCRIPTS_DIR)/verify.sh"

backup-check:
	@"$(SCRIPTS_DIR)/check-backup.sh"

bootstrap: preflight tf-apply-step dns-step inventory-step ansible-step apply-runtime-secrets-step apply-backup-secret-step wait-step verify-step
	@printf '%s\n' \
		'=== Done. The system passed the automated readiness checklist. ===' \
		"App: https://$(APP_HOST)" \
		"ArgoCD: KUBECONFIG=$(KUBECONFIG) kubectl port-forward -n argocd svc/argocd-server 8080:443" \
		"Grafana: KUBECONFIG=$(KUBECONFIG) kubectl port-forward -n monitoring svc/kps-grafana 3000:80" \
		"Checklist: make verify APP_HOST=$(APP_HOST)" \
		"Backup test: make backup-check"

nuke:
	@"$(SCRIPTS_DIR)/nuke.sh"
