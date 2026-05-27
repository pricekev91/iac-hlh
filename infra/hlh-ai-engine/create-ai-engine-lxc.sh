#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# CONFIG
# -----------------------------
LXC_ID=101
LXC_NAME="ai-engine"
LXC_HOSTNAME="ai-engine"
LXC_IMAGE="local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
POOL="RaidZ1-6TB"
MODEL_HOST_DIR="/mnt/ai/models"
MODEL_LXC_DIR="/srv/ai/models"
LXC_ROOTFS_SIZE="64"
LXC_MEMORY="49152"
LXC_CORES="12"

# -----------------------------
# STEP 1 — Model storage directory
# -----------------------------
echo "[1/6] Creating model storage directory on ${POOL}..."
mkdir -p "${MODEL_HOST_DIR}"
chown 0:0 "${MODEL_HOST_DIR}"   # Privileged container — UID 0 maps to root
chmod 775 "${MODEL_HOST_DIR}"

# -----------------------------
# STEP 2 — Create privileged LXC
# -----------------------------
echo "[2/6] Creating privileged Ubuntu 24.04 LXC (${LXC_ID}, ${LXC_NAME}) on ${POOL}..."
pct create "${LXC_ID}" "${LXC_IMAGE}" \
    --storage "${POOL}" \
    --rootfs "${LXC_ROOTFS_SIZE}" \
    --hostname "${LXC_HOSTNAME}" \
    --memory "${LXC_MEMORY}" \
    --cores "${LXC_CORES}" \
    --features nesting=1,keyctl=1 \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp \
    --unprivileged 0 \
    --onboot 1 \
    --mp0 "${MODEL_HOST_DIR},mp=${MODEL_LXC_DIR}" \
    --description "llama.cpp AI engine with ROCm, model storage on ${POOL}"

# -----------------------------
# STEP 3 — GPU passthrough (must happen BEFORE start)
# -----------------------------
echo "[3/6] Adding GPU/ROCm device passthrough to LXC config..."
cat >> "/etc/pve/lxc/${LXC_ID}.conf" <<LXCCONF

# GPU passthrough — DRI (render) + KFD (ROCm/HIP compute)
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.cgroup2.devices.allow: c 238:0 rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
lxc.mount.entry: /dev/kfd dev/kfd none bind,optional,create=file
LXCCONF

# -----------------------------
# STEP 4 — Start container
# -----------------------------
echo "[4/6] Starting LXC ${LXC_ID}..."
pct start "${LXC_ID}"
sleep 5

# -----------------------------
# STEP 5 — Bootstrap inside container
# -----------------------------
echo "[5/6] Copying and running bootstrap script inside LXC..."
pct exec "${LXC_ID}" -- mkdir -p /root/ai-engine-bootstrap
pct push "${LXC_ID}" configure-ai-engine-inside-lxc.sh \
    /root/ai-engine-bootstrap/configure-ai-engine-inside-lxc.sh \
    --perms 0755
pct exec "${LXC_ID}" -- bash /root/ai-engine-bootstrap/configure-ai-engine-inside-lxc.sh

# -----------------------------
# STEP 6 — Done
# -----------------------------
echo "[6/6] Deployment complete. LXC ${LXC_ID} (${LXC_NAME}) is running."
echo "Model storage: ${MODEL_HOST_DIR} (host) <-> ${MODEL_LXC_DIR} (container) on ${POOL}"
echo "Access llama-server at http://<container-ip>:8080"
