#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOFU_ENV_DIR="${ROOT_DIR}/infra/tofu/environments/hlh-prod"

if ! command -v tofu >/dev/null 2>&1; then
  echo "ERROR: tofu command not found" >&2
  exit 1
fi

if ! command -v ansible-playbook >/dev/null 2>&1; then
  echo "ERROR: ansible-playbook command not found" >&2
  exit 1
fi

echo "[hybrid-apply] OpenTofu init"
tofu -chdir="${TOFU_ENV_DIR}" init

echo "[hybrid-apply] OpenTofu apply"
tofu -chdir="${TOFU_ENV_DIR}" apply -auto-approve "$@"

echo "[hybrid-apply] Configure guest with Ansible"
ansible-playbook -i "${ROOT_DIR}/ansible/inventory/hlh-prod.yml" \
  "${ROOT_DIR}/ansible/playbooks/docker-host.yml"

echo "[hybrid-apply] Deploy service stacks with Ansible"
ansible-playbook -i "${ROOT_DIR}/ansible/inventory/hlh-prod.yml" \
  "${ROOT_DIR}/ansible/playbooks/deploy-services.yml"

echo "[hybrid-apply] Complete"
