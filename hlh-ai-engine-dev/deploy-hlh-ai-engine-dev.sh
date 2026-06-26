#!/usr/bin/env bash
# deploy-hlh-ai-engine.sh
# Creates a privileged Ubuntu LXC on Proxmox with GPU passthrough for llama.cpp ROCm inference.
#
# Usage:
#   ./deploy-hlh-ai-engine.sh
#
# This script must be run on the Proxmox host (pct command required).
#
# Steps:
#   1. Create model storage directory on the ZFS pool
#   2. Create privileged Ubuntu LXC container
#   3. Add GPU/ROCm passthrough devices
#   4. Start the container
#   5. Chain to configure — installs ROCm, builds llama.cpp, starts service

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Configuration ──────────────────────────────────────────────────────────────
# Change these defaults to match your environment.
LXC_ID=121
LXC_NAME="hlh-ai-engine-dev"
LXC_HOSTNAME="hlh-ai-engine-dev"
LXC_IMAGE="local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
POOL="RaidZ1-6TB"
MODEL_DIR="/srv/ai/models"
LXC_ROOTFS_SIZE="64"
LXC_MEMORY="56320"
LXC_CORES="12"
LXC_IP="192.168.1.21/24"
LXC_GATEWAY="192.168.1.1"

# ─── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            cat <<'EOF'
Usage:
  ./deploy-hlh-ai-engine.sh

Creates a privileged Ubuntu LXC container on Proxmox with GPU passthrough
for llama.cpp ROCm inference.

Must be run on the Proxmox host.
EOF
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            exit 1
            ;;
    esac
    shift
done

# ─── Pre-flight checks ─────────────────────────────────────────────────────────
command -v pct >/dev/null 2>&1 || { echo "ERROR: pct command not found. Run on Proxmox host." >&2; exit 1; }

echo "[1/5] Creating model storage directory on ${POOL}..."
mkdir -p "${MODEL_DIR}"
chown 0:0 "${MODEL_DIR}"
chmod 775 "${MODEL_DIR}"

# ─── Create container ──────────────────────────────────────────────────────────
if pct status "${LXC_ID}" >/dev/null 2>&1; then
    echo "ERROR: LXC ${LXC_ID} (${LXC_NAME}) already exists."
    echo "Delete it first with: pct destroy ${LXC_ID}"
    echo "Or change LXC_ID in this script." >&2
    exit 1
fi

echo "[2/5] Creating privileged Ubuntu LXC (${LXC_ID}, ${LXC_NAME}) on ${POOL}..."
pct create "${LXC_ID}" "${LXC_IMAGE}" \
    --storage "${POOL}" \
    --rootfs "${LXC_ROOTFS_SIZE}" \
    --hostname "${LXC_HOSTNAME}" \
    --memory "${LXC_MEMORY}" \
    --cores "${LXC_CORES}" \
    --features nesting=1,keyctl=1 \
    --net0 name=eth0,bridge=vmbr0,ip="${LXC_IP}",gw="${LXC_GATEWAY}" \
    --unprivileged 0 \
    --onboot 1 \
    --mp0 "${MODEL_DIR},mp=/srv/ai/models" \
    --description "llama.cpp AI engine (dev) with ROCm, model storage on ${POOL}"

echo "[3/5] Adding GPU/ROCm passthrough devices..."
cat >> "/etc/pve/lxc/${LXC_ID}.conf" <<'LXCCONF'

# GPU passthrough - DRI (render) + KFD (ROCm/HIP compute)
# KFD major on this host: 511
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.cgroup2.devices.allow: c 511:0 rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
lxc.mount.entry: /dev/kfd dev/kfd none bind,optional,create=file
LXCCONF

echo "[4/5] Starting LXC ${LXC_ID} (${LXC_NAME})..."
pct start "${LXC_ID}"
sleep 5

echo "[5/6] Container ready — deploying switch script..."
bash "${SCRIPT_DIR}/deploy-switch.sh"

echo "[6/6] Container ready — running configure..."
bash "${SCRIPT_DIR}/configure-hlh-ai-engine-dev.sh"
