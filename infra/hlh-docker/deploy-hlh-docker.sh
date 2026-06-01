#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/opentofu"
CONFIG_SCRIPT="${SCRIPT_DIR}/configure-hlh-docker.sh"
MODE="apply"
OFFLINE=0
RUN_TF=1
RUN_CONFIG=1
HOST_OVERRIDE=""

usage() {
    cat <<'EOF'
Usage:
  ./deploy-hlh-docker.sh [options]

Options:
  --plan           Run plan-only for OpenTofu; skip Ansible configuration.
  --apply          Apply OpenTofu and run Ansible configuration (default).
  --offline        Use offline-friendly behavior (no upgrade/init changes).
  --tf-only        Run only OpenTofu stage.
  --config-only    Run only Ansible stage.
  --host <ip>      Override target host for Ansible stage.
  -h, --help       Show this help.

Required for OpenTofu stage:
  TF_VAR_pm_api_url
  TF_VAR_pm_api_token_id
  TF_VAR_pm_api_token_secret

Optional:
  TF_VAR_lxc_root_password (if omitted, LXC root password is not set)
EOF
}

run_opentofu_stage() {
    [[ -f "${TF_DIR}/main.tf" ]] || { echo "ERROR: OpenTofu config not found at ${TF_DIR}" >&2; exit 1; }

    export TF_VAR_pm_api_url="${TF_VAR_pm_api_url:-https://192.168.1.10:8006/api2/json}"
    export TF_VAR_pm_api_token_id="${TF_VAR_pm_api_token_id:-}"
    export TF_VAR_pm_api_token_secret="${TF_VAR_pm_api_token_secret:-}"
    export TF_VAR_target_node="${TF_VAR_target_node:-prox01}"
    export TF_VAR_ostemplate="${TF_VAR_ostemplate:-local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst}"
    export TF_VAR_cores="${TF_VAR_cores:-4}"
    export TF_VAR_memory="${TF_VAR_memory:-4096}"
    export TF_VAR_network_tag="${TF_VAR_network_tag:-0}"
    export TF_VAR_lxc_root_password="${TF_VAR_lxc_root_password:-}"

    [[ -n "${TF_VAR_pm_api_token_id}" ]] || { echo "ERROR: TF_VAR_pm_api_token_id is required" >&2; exit 1; }
    [[ -n "${TF_VAR_pm_api_token_secret}" ]] || { echo "ERROR: TF_VAR_pm_api_token_secret is required" >&2; exit 1; }

    cd "${TF_DIR}"

    echo "=== Initializing OpenTofu ==="
    if [[ "$OFFLINE" -eq 1 ]]; then
        tofu init -get=false
    else
        tofu init
    fi

    TOFU_ARGS=(
        -var "pm_api_url=${TF_VAR_pm_api_url}"
        -var "pm_api_token_id=${TF_VAR_pm_api_token_id}"
        -var "pm_api_token_secret=${TF_VAR_pm_api_token_secret}"
        -var "target_node=${TF_VAR_target_node}"
        -var "ostemplate=${TF_VAR_ostemplate}"
        -var "cores=${TF_VAR_cores}"
        -var "memory=${TF_VAR_memory}"
        -var "network_tag=${TF_VAR_network_tag}"
    )

    if [[ -n "${TF_VAR_lxc_root_password}" ]]; then
        TOFU_ARGS+=( -var "lxc_root_password=${TF_VAR_lxc_root_password}" )
    fi

    if [[ "$MODE" == "plan" ]]; then
        echo "=== Plan ==="
        if [[ "$OFFLINE" -eq 1 ]]; then
            tofu plan -refresh=false "${TOFU_ARGS[@]}"
        else
            tofu plan "${TOFU_ARGS[@]}"
        fi
        return 0
    fi

    echo "=== Plan (pre-apply) ==="
    if [[ "$OFFLINE" -eq 1 ]]; then
        tofu plan -refresh=false "${TOFU_ARGS[@]}"
    else
        tofu plan "${TOFU_ARGS[@]}"
    fi

    echo ""
    read -rp "Apply hlh-docker LXC (vmid 102)? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi

    echo "=== Applying ==="
    tofu apply -auto-approve "${TOFU_ARGS[@]}"

    echo "Infrastructure stage complete."
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --plan)
            MODE="plan"
            RUN_CONFIG=0
            ;;
        --apply)
            MODE="apply"
            ;;
        --offline)
            OFFLINE=1
            ;;
        --tf-only)
            RUN_CONFIG=0
            ;;
        --config-only)
            RUN_TF=0
            ;;
        --host)
            [[ $# -ge 2 ]] || { echo "ERROR: --host requires a value" >&2; exit 1; }
            HOST_OVERRIDE="$2"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
    shift
done

if [[ "$MODE" == "plan" && "$RUN_TF" -eq 0 && "$RUN_CONFIG" -eq 0 ]]; then
    echo "ERROR: --plan requires OpenTofu stage to run." >&2
    exit 1
fi

if [[ "$RUN_TF" -eq 1 ]]; then
    run_opentofu_stage
fi

if [[ "$RUN_CONFIG" -eq 1 ]]; then
    CONFIG_ARGS=()
    [[ "$OFFLINE" -eq 1 ]] && CONFIG_ARGS+=("--offline")
    [[ -n "$HOST_OVERRIDE" ]] && CONFIG_ARGS+=("--host" "$HOST_OVERRIDE")
    "${CONFIG_SCRIPT}" "${CONFIG_ARGS[@]}"
fi

if [[ "$MODE" == "plan" ]]; then
    echo "Plan complete. No infrastructure changes were applied."
else
    echo "Deployment workflow complete."
fi
