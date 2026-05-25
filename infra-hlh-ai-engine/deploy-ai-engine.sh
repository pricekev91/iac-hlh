#!/usr/bin/env bash

set -euo pipefail


# Standalone bootstrap script for AI engine LXC
MODE="apply"

usage() {
    cat <<'EOF'
Usage:
    ./deploy-ai-engine.sh [--plan]

This script provisions a new AI engine LXC container on Proxmox with hardcoded/default values.
EOF
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

log() {
    echo "[apply] $*"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

run_cmd() {
    if [[ "$MODE" == "plan" ]]; then
        printf '[plan]'
        printf ' %q' "$@"
        printf '\n'
        return 0
    fi

    "$@"
}

trim() {
    local value="$1"

    value="${value#${value%%[![:space:]]*}}"
    value="${value%${value##*[![:space:]]}}"
    printf '%s' "$value"
}

strip_quotes() {
    local value="$1"

    if [[ "$value" =~ ^".*"$ ]]; then
        value="${value:1:${#value}-2}"
    elif [[ "$value" =~ ^'.*'$ ]]; then
        value="${value:1:${#value}-2}"
    fi

    printf '%s' "$value"
}

declare -A CONFIG=()

load_yaml_into_config() {
    local file_path="$1"
    local line
    local raw_key
    local raw_value
    local indent
    local depth
    local key
    local value

    local path
    local leading_whitespace
    local parent0=""
    local parent1=""

    [[ -f "$file_path" ]] || fail "YAML file not found: $file_path"

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        if [[ -z "$(trim "$line")" ]]; then
            continue
        fi

        [[ "$line" == *:* ]] || continue

        leading_whitespace="${line%%[![:space:]]*}"
        indent=${#leading_whitespace}
        depth=$(( indent / 2 ))
        raw_key="${line:${indent}}"
        raw_key="${raw_key%%:*}"
        raw_value="${line#*:}"
        key="$(trim "$raw_key")"
        value="$(strip_quotes "$(trim "$raw_value")")"

        case "$depth" in
            0)
                if [[ -z "$value" ]]; then
                    parent0="$key"
                    parent1=""
                    continue
                fi
                CONFIG["$key"]="$value"
                parent0=""
                parent1=""
                ;;
            1)
                [[ -n "$parent0" ]] || fail "Invalid YAML nesting in $file_path near key '$key'"
                path="$parent0.$key"
                if [[ -z "$value" ]]; then
                    parent1="$path"
                    continue
                fi
                CONFIG["$path"]="$value"
                parent1=""
                ;;
            2)
                [[ -n "$parent1" ]] || fail "Invalid YAML nesting in $file_path near key '$key'"
                CONFIG["$parent1.$key"]="$value"
                ;;
            *)
                fail "Unsupported YAML nesting depth in $file_path near key '$key'"
                ;;
        esac
    done <"$file_path"
}

config_get() {
    local key="$1"
    local default_value="${2-}"

    if [[ -n "${CONFIG[$key]+set}" ]]; then
        printf '%s' "${CONFIG[$key]}"
        return 0
    fi

    printf '%s' "$default_value"
}

bool_to_pct() {
    local value="${1,,}"

    case "$value" in
        1|true|yes|on)
            printf '1'
            ;;
        0|false|no|off)
            printf '0'
            ;;
        *)
            fail "Unsupported boolean value: $1"
            ;;
    esac
}

container_exists() {
    local vmid="$1"

    pct status "$vmid" >/dev/null 2>&1
}

container_running() {
    local vmid="$1"
    local status

    status="$(pct status "$vmid" 2>/dev/null || true)"
    [[ "$status" == "status: running" ]]
}

ensure_directory() {
    local path="$1"

    run_cmd mkdir -p "$path"
}

ensure_unprivileged_bind_ownership() {
    local path="$1"
    local unprivileged="$2"

    if [[ "$unprivileged" != "1" ]]; then
        return 0
    fi

    run_cmd chown 100000:100000 "$path"
}

pct_config_value() {
    local vmid="$1"
    local key="$2"

    pct config "$vmid" 2>/dev/null | awk -F': ' -v key="$key" '$1 == key { print $2; exit }'
}

net0_matches_desired() {
    local current="$1"
    local desired="$2"
    local part

    [[ -n "$current" ]] || return 1

    IFS=',' read -r -a desired_parts <<< "$desired"
    for part in "${desired_parts[@]}"; do
        [[ "$current" == *"$part"* ]] || return 1
    done

    return 0
}

ensure_container_base() {
    local role_label="$1"
    local vmid="$2"
    local hostname="$3"
    local ostemplate="$4"
    local storage="$5"
    local rootfs_size_gb="$6"
    local bridge="$7"
    local ip_config="$8"
    local gateway="$9"
    local cores="${10}"
    local memory_mb="${11}"
    local swap_mb="${12}"
    local unprivileged="${13}"
    local onboot="${14}"
    local tags="${15}"
    local features="${16}"
    local startup="${17}"
    local net0
    local rootfs
    local current_net0

    rootfs="${storage}:${rootfs_size_gb}"
    net0="name=eth0,bridge=${bridge},ip=${ip_config}"
    if [[ -n "$gateway" && "$ip_config" != "dhcp" ]]; then
        net0+="${gateway:+,gw=${gateway}}"
    fi

    if ! container_exists "$vmid"; then
        log "Creating ${role_label} LXC ${vmid} (${hostname})"
        run_cmd pct create "$vmid" "$ostemplate" \
            --hostname "$hostname" \
            --ostype debian \
            --rootfs "$rootfs" \
            --cores "$cores" \
            --memory "$memory_mb" \
            --swap "$swap_mb" \
            --net0 "$net0" \
            --unprivileged "$unprivileged" \
            --onboot "$onboot" \
            --tags "$tags" \
            --features "$features"
        if [[ -n "$startup" ]]; then
            run_cmd pct set "$vmid" --startup "$startup"
        fi
        return 0
    fi

    log "Reconciling ${role_label} LXC ${vmid} (${hostname})"
    run_cmd pct set "$vmid" \
        --hostname "$hostname" \
        --cores "$cores" \
        --memory "$memory_mb" \
        --swap "$swap_mb" \
        --onboot "$onboot" \
        --tags "$tags" \
        --features "$features"

    current_net0="$(pct_config_value "$vmid" net0)"
    if ! net0_matches_desired "$current_net0" "$net0"; then
        run_cmd pct set "$vmid" --net0 "$net0"
    fi

    if [[ -n "$startup" ]]; then
        run_cmd pct set "$vmid" --startup "$startup"
    fi
}

ensure_engine_mounts() {
    local vmid="$1"
    local models_source="$2"
    local state_source="$3"
    local scratch_source="$4"

    ensure_directory "$models_source"
    ensure_directory "$state_source"
    ensure_directory "$scratch_source"

    run_cmd pct set "$vmid" --mp0 "${models_source},mp=/srv/ai/models"
    run_cmd pct set "$vmid" --mp1 "${state_source},mp=/srv/ai/state"
    run_cmd pct set "$vmid" --mp2 "${scratch_source},mp=/srv/ai/scratch"
}

ensure_engine_gpu_devices() {
    local vmid="$1"
    local enable_gpu="$2"
    local card0_path="$3"
    local render_path="$4"

    if [[ "$(bool_to_pct "$enable_gpu")" != "1" ]]; then
        log "GPU passthrough disabled for engine LXC ${vmid}"
        return 0
    fi

    [[ -e "$card0_path" ]] || fail "GPU passthrough requested but host device is missing: ${card0_path}. Ensure the Proxmox host has /dev/dri from amdgpu binding."
    [[ -e "$render_path" ]] || fail "GPU passthrough requested but host device is missing: ${render_path}. Ensure the Proxmox host has /dev/dri from amdgpu binding."

    run_cmd pct set "$vmid" --dev0 "path=${card0_path}"
    run_cmd pct set "$vmid" --dev1 "path=${render_path}"
}

provision_engine_runtime() {
    local vmid="$1"
    local webui_port="$2"
    local localai_port="$3"
    local default_model="$4"
    local default_model_url="$5"
    local pull_default_model="$6"
    local llama_context_size="$7"
    local llama_gpu_layers="$8"
    local llama_threads="$9"
    local llama_batch_size="${10}"
    local llama_parallel="${11}"
    local llama_flash_attn="${12}"
    local llama_no_mmap="${13}"
    local llama_mlock="${14}"
    local llama_cache_type="${15}"
    local llama_model_path="${16}"
    local target_script="/root/provision-ai-appliance.bash"
    local provision_script="$SCRIPT_DIR/scripts/provision-ai-appliance.bash"

    [[ -f "$provision_script" ]] || fail "Provisioning script not found: $provision_script"

    if [[ "$MODE" == "plan" ]]; then
        printf '[plan] pct push %q %q %q --perms 0755\n' "$vmid" "$provision_script" "$target_script"
        printf '[plan] pct exec %q -- env AI_ENGINE_WEBUI_PORT=%q AI_ENGINE_LOCALAI_PORT=%q AI_ENGINE_DEFAULT_MODEL=%q AI_ENGINE_DEFAULT_MODEL_URL=%q AI_ENGINE_DEFAULT_MODEL_PATH=%q AI_ENGINE_PULL_DEFAULT_MODEL=%q AI_ENGINE_LLAMA_CONTEXT_SIZE=%q AI_ENGINE_LLAMA_GPU_LAYERS=%q AI_ENGINE_LLAMA_THREADS=%q AI_ENGINE_LLAMA_BATCH_SIZE=%q AI_ENGINE_LLAMA_PARALLEL=%q AI_ENGINE_LLAMA_FLASH_ATTN=%q AI_ENGINE_LLAMA_NO_MMAP=%q AI_ENGINE_LLAMA_MLOCK=%q AI_ENGINE_LLAMA_CACHE_TYPE=%q %q\n' \
            "$vmid" "$webui_port" "$localai_port" "$default_model" "$default_model_url" "$llama_model_path" "$pull_default_model" "$llama_context_size" "$llama_gpu_layers" "$llama_threads" "$llama_batch_size" "$llama_parallel" "$llama_flash_attn" "$llama_no_mmap" "$llama_mlock" "$llama_cache_type" "$target_script"
        return 0
    fi

    run_cmd pct push "$vmid" "$provision_script" "$target_script" --perms 0755
    run_cmd pct exec "$vmid" -- env \
        AI_ENGINE_WEBUI_PORT="$webui_port" \
        AI_ENGINE_LOCALAI_PORT="$localai_port" \
        AI_ENGINE_DEFAULT_MODEL="$default_model" \
        AI_ENGINE_DEFAULT_MODEL_URL="$default_model_url" \
        AI_ENGINE_DEFAULT_MODEL_PATH="$llama_model_path" \
        AI_ENGINE_PULL_DEFAULT_MODEL="$pull_default_model" \
        AI_ENGINE_LLAMA_CONTEXT_SIZE="$llama_context_size" \
        AI_ENGINE_LLAMA_GPU_LAYERS="$llama_gpu_layers" \
        AI_ENGINE_LLAMA_THREADS="$llama_threads" \
        AI_ENGINE_LLAMA_BATCH_SIZE="$llama_batch_size" \
        AI_ENGINE_LLAMA_PARALLEL="$llama_parallel" \
        AI_ENGINE_LLAMA_FLASH_ATTN="$llama_flash_attn" \
        AI_ENGINE_LLAMA_NO_MMAP="$llama_no_mmap" \
        AI_ENGINE_LLAMA_MLOCK="$llama_mlock" \
        AI_ENGINE_LLAMA_CACHE_TYPE="$llama_cache_type" \
        "$target_script"
}

ensure_engine_recreated_for_llama_stack() {
    local vmid="$1"
    local required_tag="$2"
    local inventory_path="$3"
    local current_tags

    if ! container_exists "$vmid"; then
        return 0
    fi

    current_tags="$(pct_config_value "$vmid" tags)"
    if [[ "$current_tags" == *"${required_tag}"* ]]; then
        return 0
    fi

    fail "Engine LXC ${vmid} is from the legacy stack and must be recreated once before continuing. Run: pct stop ${vmid} || true ; pct destroy ${vmid} --purge 1 ; ./apply.bash ${inventory_path}"
}

main() {
    # Hardcoded/default values (edit as needed)
    local vmid="101"
    local hostname="hlh-ai-engine"
    local ostemplate="local:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst"
    local storage="RaidZ1-6TB"
    local rootfs_size_gb="250"
    local bridge="vmbr0"
    local ip_config="dhcp"
    local gateway=""
    local cores="12"
    local memory_mb="49152"
    local swap_mb="4096"
    local unprivileged="0"
    local onboot="1"
    local startup="order=20,up=15"
    local tags="ai-appliance;shared;engine"
    local features="nesting=1,keyctl=1"
    local models_source="/home/pricekev/ai/models"
    local state_source="/home/pricekev/ai/state"
    local scratch_source="/home/pricekev/ai/scratch"
    local enable_gpu="1"
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