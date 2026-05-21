#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOFU_ENV_DIR="${ROOT_DIR}/infra/tofu/environments/hlh-prod"

echo "[ai-vm-plan] OpenTofu init"
tofu -chdir="${TOFU_ENV_DIR}" init

echo "[ai-vm-plan] OpenTofu plan for AI VM"
tofu -chdir="${TOFU_ENV_DIR}" plan -target=module.ai_vm "$@"

echo "[ai-vm-plan] Ansible syntax-check"
ansible-playbook -i "${ROOT_DIR}/ansible/inventory/hlh-prod.yml" "${ROOT_DIR}/ansible/playbooks/proxmox-gpu-passthrough.yml" --syntax-check
ansible-playbook -i "${ROOT_DIR}/ansible/inventory/hlh-prod.yml" "${ROOT_DIR}/ansible/playbooks/configure-ai-vm.yml" --syntax-check
ansible-playbook -i "${ROOT_DIR}/ansible/inventory/hlh-prod.yml" "${ROOT_DIR}/ansible/playbooks/benchmark-ai-vm.yml" --syntax-check
ansible-playbook -i "${ROOT_DIR}/ansible/inventory/hlh-prod.yml" "${ROOT_DIR}/ansible/playbooks/cutover-ai-endpoint.yml" --syntax-check
ansible-playbook -i "${ROOT_DIR}/ansible/inventory/hlh-prod.yml" "${ROOT_DIR}/ansible/playbooks/decommission-ai-lxc.yml" --syntax-check

echo "[ai-vm-plan] Complete"
