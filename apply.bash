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

ensure_container_base() {
    local vmid="$1"
    local hostname="$2"
    local ostemplate="$3"
    local storage="$4"
    local rootfs_size_gb="$5"
    local bridge="$6"
    local ip_config="$7"
    local gateway="$8"
    local cores="$9"
    local memory_mb="${10}"
    local swap_mb="${11}"
    local unprivileged="${12}"
    local onboot="${13}"
    local tags="${14}"
    local features="${15}"
    local net0
    local rootfs

    rootfs="${storage}:${rootfs_size_gb}"
    net0="name=eth0,bridge=${bridge},ip=${ip_config}"
    if [[ -n "$gateway" && "$ip_config" != "dhcp" ]]; then
        net0+="${gateway:+,gw=${gateway}}"
    fi

    if ! container_exists "$vmid"; then
        log "Creating engine LXC ${vmid} (${hostname})"
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
        return 0
    fi

    log "Reconciling engine LXC ${vmid} (${hostname})"
    run_cmd pct set "$vmid" \
        --hostname "$hostname" \
        --cores "$cores" \
        --memory "$memory_mb" \
        --swap "$swap_mb" \
        --net0 "$net0" \
        --onboot "$onboot" \
        --tags "$tags" \
        --features "$features"
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
    local backend="$2"
    local api_port="$3"
    local manager_port="$4"
    local default_model="$5"
    local pull_default_model="$6"
    local target_script="/root/provision-ai-appliance.bash"
    local provision_script="$SCRIPT_DIR/scripts/provision-ai-appliance.bash"

    [[ -f "$provision_script" ]] || fail "Provisioning script not found: $provision_script"

    if [[ "$MODE" == "plan" ]]; then
        printf '[plan] pct push %q %q %q --perms 0755\n' "$vmid" "$provision_script" "$target_script"
        printf '[plan] pct exec %q -- env AI_APPLIANCE_BACKEND=%q AI_APPLIANCE_API_PORT=%q AI_APPLIANCE_MANAGER_PORT=%q AI_APPLIANCE_DEFAULT_MODEL=%q AI_APPLIANCE_PULL_DEFAULT_MODEL=%q %q\n' \
            "$vmid" "$backend" "$api_port" "$manager_port" "$default_model" "$pull_default_model" "$target_script"
        return 0
    fi

    run_cmd pct push "$vmid" "$provision_script" "$target_script" --perms 0755
    run_cmd pct exec "$vmid" -- env \
        AI_APPLIANCE_BACKEND="$backend" \
        AI_APPLIANCE_API_PORT="$api_port" \
        AI_APPLIANCE_MANAGER_PORT="$manager_port" \
        AI_APPLIANCE_DEFAULT_MODEL="$default_model" \
        AI_APPLIANCE_PULL_DEFAULT_MODEL="$pull_default_model" \
        "$target_script"
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
    local tags
    local features
    local models_source
    local state_source
    local scratch_source
    local enable_gpu
    local card0_path
    local render_path
    local backend
    local api_port
    local manager_port
    local default_model
    local pull_default_model

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
    tags="$(config_get engine.tags 'ai-appliance;shared;engine')"
    features="$(config_get engine.features 'nesting=1,keyctl=1')"
    models_source="$(config_get storage.models_host_path)"
    state_source="$(config_get storage.state_host_path)"
    scratch_source="$(config_get storage.scratch_host_path)"
    enable_gpu="$(config_get engine.enable_gpu true)"
    card0_path="$(config_get engine.gpu.card0 /dev/dri/card0)"
    render_path="$(config_get engine.gpu.render /dev/dri/renderD128)"
    backend="$(config_get engine.backend ollama)"
    api_port="$(config_get engine.api_port 8080)"
    manager_port="$(config_get engine.manager_port 18080)"
    default_model="$(config_get engine.default_model qwen2.5-coder:7b)"
    pull_default_model="$(config_get engine.pull_default_model false)"

    [[ -n "$vmid" ]] || fail "engine.vmid must be set in inventory or platform definition"
    [[ -n "$ostemplate" ]] || fail "proxmox.ostemplate must be set in inventory"
    [[ -n "$storage" ]] || fail "proxmox.rootfs_storage must be set in inventory"
    [[ -n "$models_source" ]] || fail "storage.models_host_path must be set in inventory"
    [[ -n "$state_source" ]] || fail "storage.state_host_path must be set in inventory"
    [[ -n "$scratch_source" ]] || fail "storage.scratch_host_path must be set in inventory"

    log "Reconciling shared AI appliance LXC on HLH"
    ensure_container_base "$vmid" "$hostname" "$ostemplate" "$storage" "$rootfs_size_gb" "$bridge" "$ip_config" "$gateway" "$cores" "$memory_mb" "$swap_mb" "$unprivileged" "$onboot" "$tags" "$features"
    ensure_engine_mounts "$vmid" "$models_source" "$state_source" "$scratch_source"
    ensure_engine_gpu_devices "$vmid" "$enable_gpu" "$card0_path" "$render_path"

    if ! container_running "$vmid"; then
        run_cmd pct start "$vmid"
    fi

    provision_engine_runtime "$vmid" "$backend" "$api_port" "$manager_port" "$default_model" "$pull_default_model"
    log "Engine LXC reconciliation complete: vmid=$vmid hostname=$hostname"
}

main "$@"