#!/usr/bin/env bash
set -euo pipefail

# Deploy hlh-docker LXC (vmid 102) on prox01
# See ADR-001.md for architecture decisions

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/opentofu"
ANSIBLE_DIR="${SCRIPT_DIR}/ansible"

if [[ ! -f "${TF_DIR}/main.tf" ]]; then
    echo "ERROR: OpenTofu config not found at ${TF_DIR}" >&2
    exit 1
fi

cd "$TF_DIR"

# Set environment variables (override with .tfvars or env)
export TF_VAR_pm_api_url="${TF_VAR_pm_api_url:-https://192.168.1.10:8006/api2/json}"
export TF_VAR_target_node="${TF_VAR_target_node:-prox01}"
export TF_VAR_ostemplate="${TF_VAR_ostemplate:-local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst}"
export TF_VAR_cores="${TF_VAR_cores:-4}"
export TF_VAR_memory="${TF_VAR_memory:-4096}"
export TF_VAR_network_tag="${TF_VAR_network_tag:-0}"
export TF_VAR_lxc_root_password="${TF_VAR_lxc_root_password:-}"
export TF_VAR_pm_root_password="${TF_VAR_pm_root_password:-}"

# Validate required vars
if [[ -z "${TF_VAR_lxc_root_password:-}" ]]; then
    echo "ERROR: TF_VAR_lxc_root_password is required (unprivileged LXC needs root password)" >&2
    exit 1
fi

if [[ -z "${TF_VAR_pm_root_password:-}" ]]; then
    echo "ERROR: TF_VAR_pm_root_password is required (Proxmox root@pam password)" >&2
    exit 1
fi

# Run OpenTofu
echo "=== Initializing OpenTofu ==="
tofu init

echo ""
echo "=== Plan ==="
tofu plan \
    -var "pm_api_url=${TF_VAR_pm_api_url}" \
    -var "ostemplate=${TF_VAR_ostemplate}" \
    -var "network_tag=${TF_VAR_network_tag}" \
    -var "lxc_root_password=${TF_VAR_lxc_root_password}" \
    -var "pm_root_password=${TF_VAR_pm_root_password}"

echo ""
read -rp "Apply hlh-docker LXC (vmid 102)? [y/N] " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
    echo "=== Applying ==="
    tofu apply \
        -auto-approve \
        -var "pm_api_url=${TF_VAR_pm_api_url}" \
        -var "ostemplate=${TF_VAR_ostemplate}" \
        -var "network_tag=${TF_VAR_network_tag}" \
        -var "lxc_root_password=${TF_VAR_lxc_root_password}" \
        -var "pm_root_password=${TF_VAR_pm_root_password}"

    echo ""
    echo "=== hlh-docker LXC deployed ==="
    echo "Waiting for container to start..."

    # Wait for LXC to be running
    for i in $(seq 1 30); do
        STATUS=$(ssh -o StrictHostKeyChecking=no root@192.168.1.10 "pct status 102" 2>/dev/null | awk '{print $2}')
        if [[ "$STATUS" == "running" ]]; then
            echo "Container is running."
            break
        fi
        echo "  Waiting... ($i/30)"
        sleep 5
    done

    # Get the container IP
    CONTAINER_IP=$(ssh -o StrictHostKeyChecking=no root@192.168.1.10 "pct exec 102 -- ip -4 addr show scope global | grep -oP 'inet \K[0-9.]+' | head -1" 2>/dev/null || echo "192.168.1.13")
    echo "Container IP: ${CONTAINER_IP}"

    # Run Ansible playbook to install Docker, Dockhand, LazyDocker
    if [[ -d "${ANSIBLE_DIR}" ]]; then
        echo ""
        echo "=== Running Ansible playbook ==="
        cd "$ANSIBLE_DIR"
        INVENTORY="${ANSIBLE_DIR}/inventories/hlh-docker.yml"
        ANSIBLE_HOST=${CONTAINER_IP} \
            "${ANSIBLE_DIR}/playbooks/hlh-docker.yml" \
            -i "${INVENTORY}" \
            --private-key ~/.ssh/id_ed25519
    fi

    echo ""
    echo "=== Deployment complete ==="
    echo "  Dockhand GUI: http://${CONTAINER_IP}:3000"
    echo "  LazyDocker:   lazydocker (SSH into container)"
else
    echo "Aborted."
fi
