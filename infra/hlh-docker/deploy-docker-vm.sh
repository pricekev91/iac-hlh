#!/usr/bin/env bash
set -euo pipefail

# This script applies the OpenTofu config to create the Docker VM (hlh-ai-engine)
# Requirements: opentofu, Proxmox API token, and correct variables set

cd "$(dirname "$0")/opentofu"

export TF_VAR_pm_api_url="https://<proxmox-host>:8006/api2/json"
export TF_VAR_pm_api_token_id="<your-token-id>"
export TF_VAR_pm_api_token_secret="<your-token-secret>"
export TF_VAR_target_node="hlh"
export TF_VAR_hostname="hlh-ai-engine"
export TF_VAR_ostemplate="local:vztmpl/ubuntu-22.04-standard_latest.tar.zst"
export TF_VAR_vmid=101
export TF_VAR_cores=4
export TF_VAR_memory=4096
export TF_VAR_bridge="vmbr0"

opentofu init
opentofu apply -auto-approve

echo "Docker VM (hlh-ai-engine) deployment complete."
