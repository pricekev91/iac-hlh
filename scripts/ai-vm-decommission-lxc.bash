#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ "${1:-}" != "--confirm" ]]; then
  echo "Usage: ./scripts/ai-vm-decommission-lxc.bash --confirm"
  exit 1
fi

echo "[ai-vm-decommission] Destroy legacy AI LXC"
ansible-playbook -i "${ROOT_DIR}/ansible/inventory/hlh-prod.yml" "${ROOT_DIR}/ansible/playbooks/decommission-ai-lxc.yml" -e decommission_confirm=true

echo "[ai-vm-decommission] Complete"
