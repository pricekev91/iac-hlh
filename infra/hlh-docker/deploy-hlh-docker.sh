#!/usr/bin/env bash
set -euo pipefail

# Deploy hlh-docker LXC (vmid 102) on prox01
# See ADR-001.md for architecture decisions

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/opentofu"

if [[ ! -f "${TF_DIR}/main.tf" ]]; then
    echo "ERROR: OpenTofu config not found at ${TF_DIR}" >&2
    exit 1
fi

cd "$TF_DIR"

# Set environment variables (override with .tfvars or env)
export TF_VAR_pm_api_url="${TF_VAR_pm_api_url:-https://192.168.1.10:8006/api2/json}"
export TF_VAR_pm_api_token_id="${TF_VAR_pm_api_token_id:-}"
export TF_VAR_pm_api_token_secret="${TF_VAR_pm_api_token_secret:-}"
export TF_VAR_target_node="${TF_VAR_target_node:-prox01}"
export TF_VAR_ostemplate="${TF_VAR_ostemplate:-local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst}"
export TF_VAR_cores="${TF_VAR_cores:-4}"
export TF_VAR_memory="${TF_VAR_memory:-4096}"
export TF_VAR_network_tag="${TF_VAR_network_tag:-0}"
export TF_VAR_lxc_root_password="${TF_VAR_lxc_root_password:-}"

# Validate required vars
if [[ -z "${TF_VAR_pm_api_token_id:-}" ]]; then
    echo "ERROR: TF_VAR_pm_api_token_id is required" >&2
    exit 1
fi

if [[ -z "${TF_VAR_pm_api_token_secret:-}" ]]; then
    echo "ERROR: TF_VAR_pm_api_token_secret is required" >&2
    exit 1
fi

if [[ -z "${TF_VAR_lxc_root_password:-}" ]]; then
    echo "ERROR: TF_VAR_lxc_root_password is required (unprivileged LXC needs root password)" >&2
    exit 1
fi

# Run OpenTofu
echo "=== Initializing OpenTofu ==="
tofu init

echo ""
echo "=== Plan ==="
tofu plan \
    -var "pm_api_url=${TF_VAR_pm_api_url}" \
    -var "pm_api_token_id=${TF_VAR_pm_api_token_id}" \
    -var "pm_api_token_secret=${TF_VAR_pm_api_token_secret}" \
    -var "ostemplate=${TF_VAR_ostemplate}" \
    -var "network_tag=${TF_VAR_network_tag}" \
    -var "lxc_root_password=${TF_VAR_lxc_root_password}"

echo ""
read -rp "Apply hlh-docker LXC (vmid 102)? [y/N] " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
    echo "=== Applying ==="
    tofu apply \
        -auto-approve \
        -var "pm_api_url=${TF_VAR_pm_api_url}" \
        -var "pm_api_token_id=${TF_VAR_pm_api_token_id}" \
        -var "pm_api_token_secret=${TF_VAR_pm_api_token_secret}" \
        -var "ostemplate=${TF_VAR_ostemplate}" \
        -var "network_tag=${TF_VAR_network_tag}" \
        -var "lxc_root_password=${TF_VAR_lxc_root_password}"

    echo ""
    echo "=== hlh-docker LXC deployed ==="
    echo "Next steps:"
    echo "  1. Get IP from DHCP: pvesh get /nodes/${TF_VAR_target_node:-prox01}/qemu/102/status/current"
    echo "  2. Update Ansible inventory with new IP"
    echo "  3. Run: ansible-playbook ansible/playbooks/hlh-docker.yml"
else
    echo "Aborted."
fi
