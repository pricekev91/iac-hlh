bool_to_pct() {
pct_config_value() {
#!/usr/bin/env bash
# deploy-ai-engine.sh
# One-and-done script for Medusa Halo replacement (Home Lab, Proxmox 9.x, ROCm, AMD Ryzen AI 9 HX 370 + Radeon 890M)
#
# This script will:
#   1. Create privileged Ubuntu 24.04 LXC (ID 101, name ai-engine) on RaidZ1-6TB
#   2. Set up /srv/ai/models as a bind mount to /mnt/ai/models on RaidZ1-6TB
#   3. Enable GPU passthrough (/dev/kfd, /dev/dri)
#   4. Bootstrap llama.cpp and systemd service inside the container
#   5. Provide a model switcher and verification
#
# Usage: Run as root on Prox01 (the Proxmox host)

set -euo pipefail

# --- CONFIGURABLE ---
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

# --- 1. PRECHECKS ---
echo "[1/7] Checking environment..."
if ! command -v pct &>/dev/null; then
  echo "This script must be run on a Proxmox host with 'pct' available."
  exit 1
fi
if ! zfs list "$POOL" &>/dev/null; then
  echo "ZFS pool $POOL not found. Please create it first."
  exit 1
fi
if pct status $LXC_ID &>/dev/null; then
  echo "LXC $LXC_ID already exists. Aborting."
  exit 1
fi

# --- 2. CREATE MODEL STORAGE DIR ---
echo "[2/7] Ensuring model storage directory on $POOL..."
mkdir -p "$MODEL_HOST_DIR"
chown 100000:100000 "$MODEL_HOST_DIR"
chmod 775 "$MODEL_HOST_DIR"

# --- 3. CREATE LXC CONTAINER ---
echo "[3/7] Creating privileged Ubuntu 24.04 LXC ($LXC_ID, $LXC_NAME) on $POOL..."
pct create $LXC_ID $LXC_IMAGE \
  -rootfs $POOL:$LXC_ROOTFS_SIZE \
  -hostname $LXC_HOSTNAME \
  -memory $LXC_MEMORY \
  -cores $LXC_CORES \
  -features nesting=1,keyctl=1 \
  -net0 name=eth0,bridge=vmbr0,ip=dhcp \
  -unprivileged 0 \
  -onboot 1 \
  -mp0 $MODEL_HOST_DIR,$MODEL_LXC_DIR,mp=/srv/ai/models \
  -description "llama.cpp AI engine with ROCm/Vulkan, GPU passthrough, model storage on $POOL"

# --- 4. GPU PASSTHROUGH ---
echo "[4/7] Adding GPU passthrough devices..."
pct set $LXC_ID -device hostpci0,pcie=1,rombar=0
pct set $LXC_ID -mp1 /dev/dri,/dev/dri
pct set $LXC_ID -mp2 /dev/kfd,/dev/kfd

# --- 5. START CONTAINER ---
echo "[5/7] Starting LXC $LXC_ID..."
pct start $LXC_ID
sleep 5

# --- 6. COPY AND RUN BOOTSTRAP INSIDE LXC ---
echo "[6/7] Copying and running bootstrap script inside LXC..."
SCRIPT_DIR="/root/ai-engine-bootstrap"
pct exec $LXC_ID -- mkdir -p "$SCRIPT_DIR"
cp "$(dirname "$0")/ai-engine-bootstrap.sh" /var/lib/lxc/$LXC_ID/rootfs$SCRIPT_DIR/
pct exec $LXC_ID -- bash "$SCRIPT_DIR/ai-engine-bootstrap.sh"

# --- 7. FINAL STATUS ---
echo "[7/7] Deployment complete. LXC $LXC_ID ($LXC_NAME) is running."
echo "Model storage: $MODEL_HOST_DIR (host) <-> $MODEL_LXC_DIR (container) on $POOL"
echo "Access llama-server at http://<container-ip>:8080"
    local card0_path="/dev/dri/card0"
    local render_path="/dev/dri/renderD128"
    local webui_port="8080"
    local localai_port="3000"
    local default_model="qwen2.5-coder:7b"
    local default_model_url=""
    local pull_default_model="false"
    local llama_context_size="8192"
    local llama_gpu_layers="99"
    local llama_threads="12"
    local llama_batch_size="512"
    local llama_parallel="1"
    local llama_flash_attn="false"
    local llama_no_mmap="false"
    local llama_mlock="false"
    local llama_cache_type=""
    local llama_model_path="/srv/ai/models/default.gguf"

    if [[ "${1-}" == "--plan" ]]; then
        MODE="plan"
    fi

    require_command awk
    require_command pct

    log "Reconciling AI engine LXC (bootstrap mode)"
    ensure_container_base "engine" "$vmid" "$hostname" "$ostemplate" "$storage" "$rootfs_size_gb" "$bridge" "$ip_config" "$gateway" "$cores" "$memory_mb" "$swap_mb" "$unprivileged" "$onboot" "$tags" "$features" "$startup"
    ensure_engine_mounts "$vmid" "$models_source" "$state_source" "$scratch_source"
    ensure_engine_gpu_devices "$vmid" "$enable_gpu" "$card0_path" "$render_path"

    if ! container_running "$vmid"; then
        run_cmd pct start "$vmid"
    fi

    provision_engine_runtime "$vmid" "$webui_port" "$localai_port" "$default_model" "$default_model_url" "$pull_default_model" "$llama_context_size" "$llama_gpu_layers" "$llama_threads" "$llama_batch_size" "$llama_parallel" "$llama_flash_attn" "$llama_no_mmap" "$llama_mlock" "$llama_cache_type" "$llama_model_path"
    log "Engine LXC bootstrap complete: vmid=$vmid hostname=$hostname webui_port=$webui_port localai_port=$localai_port"
}

main "$@"