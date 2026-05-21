#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOFU_ENV_DIR="${ROOT_DIR}/infra/tofu/environments/hlh-prod"

if ! command -v tofu >/dev/null 2>&1; then
  echo "ERROR: tofu command not found" >&2
  exit 1
fi

echo "[hybrid-plan] OpenTofu init"
tofu -chdir="${TOFU_ENV_DIR}" init

echo "[hybrid-plan] OpenTofu plan"
tofu -chdir="${TOFU_ENV_DIR}" plan "$@"

echo "[hybrid-plan] Ansible syntax-check (docker-host)"
ansible-playbook -i "${ROOT_DIR}/ansible/inventory/hlh-prod.yml" \
  "${ROOT_DIR}/ansible/playbooks/docker-host.yml" --syntax-check

echo "[hybrid-plan] Ansible syntax-check (deploy-services)"
ansible-playbook -i "${ROOT_DIR}/ansible/inventory/hlh-prod.yml" \
  "${ROOT_DIR}/ansible/playbooks/deploy-services.yml" --syntax-check

echo "[hybrid-plan] Complete"
