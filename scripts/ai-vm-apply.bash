#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOFU_ENV_DIR="${ROOT_DIR}/infra/tofu/environments/hlh-prod"

echo "[ai-vm-apply] OpenTofu init"
tofu -chdir="${TOFU_ENV_DIR}" init

echo "[ai-vm-apply] Create or update AI VM"
tofu -chdir="${TOFU_ENV_DIR}" apply -auto-approve -target=module.ai_vm "$@"

echo "[ai-vm-apply] Attach AMD GPU to AI VM"
ansible-playbook -i "${ROOT_DIR}/ansible/inventory/hlh-prod.yml" "${ROOT_DIR}/ansible/playbooks/proxmox-gpu-passthrough.yml"

echo "[ai-vm-apply] Configure ROCm and AI engines"
ansible-playbook -i "${ROOT_DIR}/ansible/inventory/hlh-prod.yml" "${ROOT_DIR}/ansible/playbooks/configure-ai-vm.yml"

echo "[ai-vm-apply] Run benchmark and health validation"
ansible-playbook -i "${ROOT_DIR}/ansible/inventory/hlh-prod.yml" "${ROOT_DIR}/ansible/playbooks/benchmark-ai-vm.yml"

echo "[ai-vm-apply] Complete"
