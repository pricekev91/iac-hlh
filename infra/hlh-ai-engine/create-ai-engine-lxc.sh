bool_to_pct() {
pct_config_value() {
#!/usr/bin/env bash
set -euo pipefail

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
  -hostname $LXC_HOSTNAME \
  -memory $LXC_MEMORY \
  -cores $LXC_CORES \
  -features nesting=1,keyctl=1 \
  -net0 name=eth0,bridge=vmbr0,ip=dhcp \
  -unprivileged 0 \
  -onboot 1 \
  -mp0 $MODEL_HOST_DIR,$MODEL_LXC_DIR,mp=/srv/ai/models \
  -description "llama.cpp AI engine with ROCm, model storage on $POOL"

echo "[3/6] Adding GPU passthrough devices..."
pct set $LXC_ID -mp1 /dev/dri,/dev/dri
pct set $LXC_ID -mp2 /dev/kfd,/dev/kfd

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