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

container_ipv4() {
    local vmid="$1"

    if [[ "$MODE" == "plan" ]]; then
        return 0
    fi

    pct exec "$vmid" -- sh -c "hostname -I 2>/dev/null | awk '{print \$1}'" 2>/dev/null | tr -d '\r' | awk 'NF { print $1; exit }'
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
        --net0 "$net0" \
        --onboot "$onboot" \
        --tags "$tags" \
        --features "$features"

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
    local backend="$2"
    local api_port="$3"
    local manager_port="$4"
    local default_model="$5"
    local pull_default_model="$6"
    local verbose_model_alias="$7"
    local verbose_system_prompt="$8"
    local verbose_num_predict="$9"
    local target_script="/root/provision-ai-appliance.bash"
    local provision_script="$SCRIPT_DIR/scripts/provision-ai-appliance.bash"

    [[ -f "$provision_script" ]] || fail "Provisioning script not found: $provision_script"

    if [[ "$MODE" == "plan" ]]; then
        printf '[plan] pct push %q %q %q --perms 0755\n' "$vmid" "$provision_script" "$target_script"
        printf '[plan] pct exec %q -- env AI_APPLIANCE_BACKEND=%q AI_APPLIANCE_API_PORT=%q AI_APPLIANCE_MANAGER_PORT=%q AI_APPLIANCE_DEFAULT_MODEL=%q AI_APPLIANCE_PULL_DEFAULT_MODEL=%q AI_APPLIANCE_VERBOSE_MODEL_ALIAS=%q AI_APPLIANCE_VERBOSE_SYSTEM_PROMPT=%q AI_APPLIANCE_VERBOSE_NUM_PREDICT=%q %q\n' \
            "$vmid" "$backend" "$api_port" "$manager_port" "$default_model" "$pull_default_model" "$verbose_model_alias" "$verbose_system_prompt" "$verbose_num_predict" "$target_script"
        return 0
    fi

    run_cmd pct push "$vmid" "$provision_script" "$target_script" --perms 0755
    run_cmd pct exec "$vmid" -- env \
        AI_APPLIANCE_BACKEND="$backend" \
        AI_APPLIANCE_API_PORT="$api_port" \
        AI_APPLIANCE_MANAGER_PORT="$manager_port" \
        AI_APPLIANCE_DEFAULT_MODEL="$default_model" \
        AI_APPLIANCE_PULL_DEFAULT_MODEL="$pull_default_model" \
        AI_APPLIANCE_VERBOSE_MODEL_ALIAS="$verbose_model_alias" \
        AI_APPLIANCE_VERBOSE_SYSTEM_PROMPT="$verbose_system_prompt" \
        AI_APPLIANCE_VERBOSE_NUM_PREDICT="$verbose_num_predict" \
        "$target_script"
}

provision_presentation_runtime() {
    local vmid="$1"
    local ui_port="$2"
    local engine_base_url="$3"
    local webui_auth="$4"
    local default_models="$5"
    local default_model_params="$6"
    local target_script="/root/provision-openwebui.bash"
    local provision_script="$SCRIPT_DIR/scripts/provision-openwebui.bash"

    [[ -f "$provision_script" ]] || fail "Provisioning script not found: $provision_script"

    if [[ "$MODE" == "plan" ]]; then
        printf '[plan] pct push %q %q %q --perms 0755\n' "$vmid" "$provision_script" "$target_script"
        printf '[plan] pct exec %q -- env AI_PRESENTATION_HOST=%q AI_PRESENTATION_PORT=%q AI_PRESENTATION_OLLAMA_BASE_URL=%q AI_PRESENTATION_WEBUI_AUTH=%q AI_PRESENTATION_DEFAULT_MODELS=%q AI_PRESENTATION_DEFAULT_MODEL_PARAMS=%q %q\n' \
            "$vmid" "0.0.0.0" "$ui_port" "$engine_base_url" "$webui_auth" "$default_models" "$default_model_params" "$target_script"
        return 0
    fi

    run_cmd pct push "$vmid" "$provision_script" "$target_script" --perms 0755
    run_cmd pct exec "$vmid" -- env \
        AI_PRESENTATION_HOST="0.0.0.0" \
        AI_PRESENTATION_PORT="$ui_port" \
        AI_PRESENTATION_OLLAMA_BASE_URL="$engine_base_url" \
        AI_PRESENTATION_WEBUI_AUTH="$webui_auth" \
        AI_PRESENTATION_DEFAULT_MODELS="$default_models" \
        AI_PRESENTATION_DEFAULT_MODEL_PARAMS="$default_model_params" \
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
    local startup
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
    local verbose_model_alias
    local verbose_system_prompt
    local verbose_num_predict
    local presentation_platform_path="$SCRIPT_DIR/platforms/presentation.yaml"
    local presentation_vmid
    local presentation_hostname
    local presentation_ip_config
    local presentation_rootfs_size_gb
    local presentation_cores
    local presentation_memory_mb
    local presentation_swap_mb
    local presentation_unprivileged
    local presentation_onboot
    local presentation_startup
    local presentation_tags
    local presentation_features
    local presentation_ui_port
    local presentation_webui_auth
    local presentation_engine_base_url
    local presentation_default_models
    local presentation_default_model_params
    local engine_ipv4

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
    if [[ -f "$presentation_platform_path" ]]; then
        load_yaml_into_config "$presentation_platform_path"
    fi
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
    backend="$(config_get engine.backend ollama)"
    api_port="$(config_get engine.api_port 8080)"
    manager_port="$(config_get engine.manager_port 18080)"
    default_model="$(config_get engine.default_model qwen2.5-coder:7b)"
    pull_default_model="$(config_get engine.pull_default_model false)"
    verbose_model_alias="$(config_get engine.verbose_model_alias)"
    verbose_system_prompt="$(config_get engine.verbose_system_prompt 'Provide thorough, information-dense answers. State assumptions, explain tradeoffs, and include concrete next steps when helpful.')"
    verbose_num_predict="$(config_get engine.verbose_num_predict 4096)"
    presentation_vmid="$(config_get presentation.vmid)"
    presentation_hostname="$(config_get presentation.hostname presentation)"
    presentation_ip_config="$(config_get presentation.ipv4 dhcp)"
    presentation_rootfs_size_gb="$(config_get presentation.rootfs_size_gb 32)"
    presentation_cores="$(config_get presentation.cores 4)"
    presentation_memory_mb="$(config_get presentation.memory_mb 8192)"
    presentation_swap_mb="$(config_get presentation.swap_mb 2048)"
    presentation_unprivileged="$(bool_to_pct "$(config_get presentation.unprivileged true)")"
    presentation_onboot="$(bool_to_pct "$(config_get presentation.onboot true)")"
    presentation_startup="$(config_get presentation.startup 'order=30,up=15')"
    presentation_tags="$(config_get presentation.tags 'ai-presentation;shared;openwebui')"
    presentation_features="$(config_get presentation.features 'nesting=1,keyctl=1')"
    presentation_ui_port="$(config_get presentation.ui_port 3000)"
    presentation_webui_auth="$(config_get presentation.webui_auth false)"
    presentation_engine_base_url="$(config_get presentation.engine_base_url)"
    presentation_default_models="$(config_get presentation.default_models "$default_model")"
    presentation_default_model_params="$(config_get presentation.default_model_params '{"stream_response":true}')"

    [[ -n "$vmid" ]] || fail "engine.vmid must be set in inventory or platform definition"
    [[ -n "$ostemplate" ]] || fail "proxmox.ostemplate must be set in inventory"
    [[ -n "$storage" ]] || fail "proxmox.rootfs_storage must be set in inventory"
    [[ -n "$models_source" ]] || fail "storage.models_host_path must be set in inventory"
    [[ -n "$state_source" ]] || fail "storage.state_host_path must be set in inventory"
    [[ -n "$scratch_source" ]] || fail "storage.scratch_host_path must be set in inventory"

    log "Reconciling shared AI appliance LXC on HLH"
    ensure_container_base "engine" "$vmid" "$hostname" "$ostemplate" "$storage" "$rootfs_size_gb" "$bridge" "$ip_config" "$gateway" "$cores" "$memory_mb" "$swap_mb" "$unprivileged" "$onboot" "$tags" "$features" "$startup"
    ensure_engine_mounts "$vmid" "$models_source" "$state_source" "$scratch_source"
    ensure_engine_gpu_devices "$vmid" "$enable_gpu" "$card0_path" "$render_path"

    if ! container_running "$vmid"; then
        run_cmd pct start "$vmid"
    fi

    provision_engine_runtime "$vmid" "$backend" "$api_port" "$manager_port" "$default_model" "$pull_default_model" "$verbose_model_alias" "$verbose_system_prompt" "$verbose_num_predict"
    log "Engine LXC reconciliation complete: vmid=$vmid hostname=$hostname"

    if [[ "$backend" == "ollama" ]]; then
        [[ -n "$presentation_vmid" ]] || fail "presentation.vmid must be set in inventory when engine.backend=ollama"

        if [[ -z "$presentation_engine_base_url" ]]; then
            if [[ "$MODE" == "plan" ]]; then
                presentation_engine_base_url="http://<engine-ip>:${api_port}"
            else
                engine_ipv4="$(container_ipv4 "$vmid")"
                [[ -n "$engine_ipv4" ]] || fail "Unable to determine engine container IPv4 address for presentation wiring"
                presentation_engine_base_url="http://${engine_ipv4}:${api_port}"
            fi
        fi

        log "Reconciling presentation LXC on HLH"
        ensure_container_base "presentation" "$presentation_vmid" "$presentation_hostname" "$ostemplate" "$storage" "$presentation_rootfs_size_gb" "$bridge" "$presentation_ip_config" "$gateway" "$presentation_cores" "$presentation_memory_mb" "$presentation_swap_mb" "$presentation_unprivileged" "$presentation_onboot" "$presentation_tags" "$presentation_features" "$presentation_startup"

        if ! container_running "$presentation_vmid"; then
            run_cmd pct start "$presentation_vmid"
        fi

        provision_presentation_runtime "$presentation_vmid" "$presentation_ui_port" "$presentation_engine_base_url" "$presentation_webui_auth" "$presentation_default_models" "$presentation_default_model_params"
        log "Presentation LXC reconciliation complete: vmid=$presentation_vmid hostname=$presentation_hostname base_url=$presentation_engine_base_url"
    fi
}

main "$@"