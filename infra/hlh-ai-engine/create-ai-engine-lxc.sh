#!/usr/bin/env bash
#set -euo pipefail

LXC_ID=101
LXC_NAME="ai-engine"
LXC_HOSTNAME="ai-engine"
LXC_IMAGE="local:vztmpl/ubuntu-24.04-standard_24.04-1_amd64.tar.zst"
POOL="RaidZ1-6TB"
MODEL_HOST_DIR="/mnt/ai/models"
MODEL_LXC_DIR="/srv/ai/models"
LXC_ROOTFS_SIZE="64G"
LXC_MEMORY="32768"
LXC_CORES="12"

echo "[1/6] Creating model storage directory on $POOL..."
mkdir -p "$MODEL_HOST_DIR"
chown 100000:100000 "$MODEL_HOST_DIR"
chmod 775 "$MODEL_HOST_DIR"
echo "[2/6] Creating privileged Ubuntu 24.04 LXC ($LXC_ID, $LXC_NAME) on $POOL..."
pct create $LXC_ID $LXC_IMAGE \
    -rootfs $POOL:$LXC_ROOTFS_SIZE \
    #!/usr/bin/env bash
    set -euo pipefail

    # --- CONFIG ---
    LXC_ID=101
    LXC_NAME="ai-engine"
    LXC_HOSTNAME="ai-engine"
    LXC_IMAGE="local:vztmpl/ubuntu-24.04-standard_24.04-1_amd64.tar.zst"
    POOL="RaidZ1-6TB"
    MODEL_HOST_DIR="/mnt/ai/models"
    MODEL_LXC_DIR="/srv/ai/models"
    LXC_ROOTFS_SIZE="64G"
    LXC_MEMORY="32768"
    LXC_CORES="12"

    echo "[1/6] Creating model storage directory on $POOL..."
    mkdir -p "$MODEL_HOST_DIR"
    chown 100000:100000 "$MODEL_HOST_DIR"
    chmod 775 "$MODEL_HOST_DIR"

    echo "[2/6] Creating privileged Ubuntu 24.04 LXC ($LXC_ID, $LXC_NAME) on $POOL..."
    pct create $LXC_ID $LXC_IMAGE \
        --storage ${POOL} \
        -hostname $LXC_HOSTNAME \
        -memory $LXC_MEMORY \
        -cores $LXC_CORES \
        -features nesting=1,keyctl=1 \
        -net0 name=eth0,bridge=vmbr0,ip=dhcp \
        -unprivileged 0 \
        -onboot 1 \
        -mp0 ${MODEL_HOST_DIR},mp=${MODEL_LXC_DIR} \
        -description "llama.cpp AI engine with ROCm, model storage on $POOL"

    echo "[3/6] Adding GPU passthrough devices..."
    pct set $LXC_ID -mp1 /dev/dri,mp=/dev/dri
    pct set $LXC_ID -mp2 /dev/kfd,mp=/dev/kfd

    echo "[4/6] Starting LXC $LXC_ID..."
    pct start $LXC_ID
    sleep 5

    echo "[5/6] Copying and running bootstrap script inside LXC..."
    pct exec $LXC_ID -- mkdir -p /root/ai-engine-bootstrap
    pct push $LXC_ID configure-ai-engine-inside-lxc.sh /root/ai-engine-bootstrap/configure-ai-engine-inside-lxc.sh --perms 0755
    pct exec $LXC_ID -- bash /root/ai-engine-bootstrap/configure-ai-engine-inside-lxc.sh

    echo "[6/6] Deployment complete. LXC $LXC_ID ($LXC_NAME) is running."
    echo "Model storage: $MODEL_HOST_DIR (host) <-> $MODEL_LXC_DIR (container) on $POOL"
    echo "Access llama-server at http://<container-ip>:8080"