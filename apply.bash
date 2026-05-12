#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="apply"

usage() {
    cat <<'EOF'
Usage:
  ./apply.bash inventory/<host>.yaml
  ./apply.bash --plan inventory/<host>.yaml

Modes:
  --plan   Validate inventory and print the Proxmox reconciliation plan without executing pct changes.
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

    if [[ -e "$card0_path" ]]; then
        run_cmd pct set "$vmid" --dev0 "path=${card0_path}"
    else
        log "Skipping missing GPU device: $card0_path"
    fi

    if [[ -e "$render_path" ]]; then
        run_cmd pct set "$vmid" --dev1 "path=${render_path}"
    else
        log "Skipping missing GPU device: $render_path"
    fi
}

provision_engine_runtime() {
    local vmid="$1"
    local webui_port="$2"
    local localai_port="$3"
    local llama_server_port="$4"
    local default_model="$5"
    local pull_default_model="$6"
    local llama_context_size="$7"
    local llama_gpu_layers="$8"
    local llama_threads="$9"
    local target_script="/root/provision-ai-appliance.bash"
    local provision_script="$SCRIPT_DIR/scripts/provision-ai-appliance.bash"

    [[ -f "$provision_script" ]] || fail "Provisioning script not found: $provision_script"

    if [[ "$MODE" == "plan" ]]; then
        printf '[plan] pct push %q %q %q --perms 0755\n' "$vmid" "$provision_script" "$target_script"
        printf '[plan] pct exec %q -- env AI_ENGINE_WEBUI_PORT=%q AI_ENGINE_LOCALAI_PORT=%q AI_ENGINE_LLAMA_SERVER_PORT=%q AI_ENGINE_DEFAULT_MODEL=%q AI_ENGINE_PULL_DEFAULT_MODEL=%q AI_ENGINE_LLAMA_CONTEXT_SIZE=%q AI_ENGINE_LLAMA_GPU_LAYERS=%q AI_ENGINE_LLAMA_THREADS=%q %q\n' \
            "$vmid" "$webui_port" "$localai_port" "$llama_server_port" "$default_model" "$pull_default_model" "$llama_context_size" "$llama_gpu_layers" "$llama_threads" "$target_script"
        return 0
    fi

    run_cmd pct push "$vmid" "$provision_script" "$target_script" --perms 0755
    run_cmd pct exec "$vmid" -- env \
        AI_ENGINE_WEBUI_PORT="$webui_port" \
        AI_ENGINE_LOCALAI_PORT="$localai_port" \
        AI_ENGINE_LLAMA_SERVER_PORT="$llama_server_port" \
        AI_ENGINE_DEFAULT_MODEL="$default_model" \
        AI_ENGINE_PULL_DEFAULT_MODEL="$pull_default_model" \
        AI_ENGINE_LLAMA_CONTEXT_SIZE="$llama_context_size" \
        AI_ENGINE_LLAMA_GPU_LAYERS="$llama_gpu_layers" \
        AI_ENGINE_LLAMA_THREADS="$llama_threads" \
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
    local inventory_path
    local platform_path="$SCRIPT_DIR/platforms/engine.yaml"
    local vmid
    local hostname
    local ostemplate
    local storage
    local rootfs_size_gb
    local bridge
    local ip_config
    local gateway
    local cores
    local memory_mb
    local swap_mb
    local unprivileged
    local onboot
    local startup
    local tags
    local features
    local models_source
    local state_source
    local scratch_source
    local enable_gpu
    local card0_path
    local render_path
    local webui_port
    local localai_port
    local llama_server_port
    local default_model
    local pull_default_model
    local llama_context_size
    local llama_gpu_layers
    local llama_threads

    if [[ $# -lt 1 || $# -gt 2 ]]; then
        usage
        exit 1
    fi

    if [[ "${1-}" == "--plan" ]]; then
        MODE="plan"
        shift
    fi

    inventory_path="${1-}"
    [[ -n "$inventory_path" ]] || fail "Inventory path is required"

    require_command awk
    require_command pct

    load_yaml_into_config "$platform_path"
    load_yaml_into_config "$inventory_path"

    vmid="$(config_get engine.vmid)"
    hostname="$(config_get engine.hostname engine)"
    ostemplate="$(config_get proxmox.ostemplate)"
    storage="$(config_get proxmox.rootfs_storage)"
    rootfs_size_gb="$(config_get engine.rootfs_size_gb 64)"
    bridge="$(config_get proxmox.bridge vmbr0)"
    ip_config="$(config_get engine.ipv4 dhcp)"
    gateway="$(config_get proxmox.gateway)"
    cores="$(config_get engine.cores 8)"
    memory_mb="$(config_get engine.memory_mb 32768)"
    swap_mb="$(config_get engine.swap_mb 4096)"
    unprivileged="$(bool_to_pct "$(config_get engine.unprivileged false)")"
    onboot="$(bool_to_pct "$(config_get engine.onboot true)")"
    startup="$(config_get engine.startup 'order=20,up=15')"
    tags="$(config_get engine.tags 'ai-appliance;shared;engine')"
    features="$(config_get engine.features 'nesting=1,keyctl=1')"
    models_source="$(config_get storage.models_host_path)"
    state_source="$(config_get storage.state_host_path)"
    scratch_source="$(config_get storage.scratch_host_path)"
    enable_gpu="$(config_get engine.enable_gpu true)"
    card0_path="$(config_get engine.gpu.card0 /dev/dri/card0)"
    render_path="$(config_get engine.gpu.render /dev/dri/renderD128)"
    webui_port="$(config_get engine.webui_port 8080)"
    localai_port="$(config_get engine.localai_port 8081)"
    llama_server_port="$(config_get engine.llama_server_port 8082)"
    default_model="$(config_get engine.default_model qwen2.5-coder:7b)"
    pull_default_model="$(config_get engine.pull_default_model false)"
    llama_context_size="$(config_get engine.llama_context_size 8192)"
    llama_gpu_layers="$(config_get engine.llama_gpu_layers 99)"
    llama_threads="$(config_get engine.llama_threads 12)"

    [[ -n "$vmid" ]] || fail "engine.vmid must be set in inventory or platform definition"
    [[ -n "$ostemplate" ]] || fail "proxmox.ostemplate must be set in inventory"
    [[ -n "$storage" ]] || fail "proxmox.rootfs_storage must be set in inventory"
    [[ -n "$models_source" ]] || fail "storage.models_host_path must be set in inventory"
    [[ -n "$state_source" ]] || fail "storage.state_host_path must be set in inventory"
    [[ -n "$scratch_source" ]] || fail "storage.scratch_host_path must be set in inventory"

    if [[ -n "$(config_get presentation.vmid)" || -n "$(config_get trashpanda_app.vmid)" ]]; then
        fail "Legacy inventory keys detected (presentation.* or trashpanda_app.*). Remove those sections to use the single-engine stack."
    fi

    ensure_engine_recreated_for_llama_stack "$vmid" "llama-stack" "$inventory_path"

    log "Reconciling shared AI engine LXC on HLH"
    ensure_container_base "engine" "$vmid" "$hostname" "$ostemplate" "$storage" "$rootfs_size_gb" "$bridge" "$ip_config" "$gateway" "$cores" "$memory_mb" "$swap_mb" "$unprivileged" "$onboot" "$tags" "$features" "$startup"
    ensure_engine_mounts "$vmid" "$models_source" "$state_source" "$scratch_source"
    ensure_engine_gpu_devices "$vmid" "$enable_gpu" "$card0_path" "$render_path"

    if ! container_running "$vmid"; then
        run_cmd pct start "$vmid"
    fi

    provision_engine_runtime "$vmid" "$webui_port" "$localai_port" "$llama_server_port" "$default_model" "$pull_default_model" "$llama_context_size" "$llama_gpu_layers" "$llama_threads"
    log "Engine LXC reconciliation complete: vmid=$vmid hostname=$hostname webui_port=$webui_port localai_port=$localai_port llama_server_port=$llama_server_port"
}

main "$@"