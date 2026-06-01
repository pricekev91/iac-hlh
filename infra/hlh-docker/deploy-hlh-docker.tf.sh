#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/opentofu"
MODE="apply"
OFFLINE=0

usage() {
    cat <<'EOF'
Usage:
  ./deploy-hlh-docker.tf.sh [--plan|--apply] [--offline]

Options:
  --plan      Run tofu plan only.
  --apply     Run tofu apply (default, with confirmation prompt).
  --offline   Offline-friendly execution (no init upgrade and refresh=false).
  -h, --help  Show this help.

Required environment variables:
  TF_VAR_pm_api_url
  TF_VAR_pm_api_token_id
  TF_VAR_pm_api_token_secret
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --plan)
            MODE="plan"
            ;;
        --apply)
            MODE="apply"
            ;;
        --offline)
            OFFLINE=1
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
    tofu init -lockfile=readonly
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
    exit 0
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
