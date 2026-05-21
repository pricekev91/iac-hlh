#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "[ai-vm-cutover] Switch shared AI endpoint to AI VM"
ansible-playbook -i "${ROOT_DIR}/ansible/inventory/hlh-prod.yml" "${ROOT_DIR}/ansible/playbooks/cutover-ai-endpoint.yml" "$@"

echo "[ai-vm-cutover] Complete"
