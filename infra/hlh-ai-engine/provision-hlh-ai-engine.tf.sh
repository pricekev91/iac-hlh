#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/opentofu"
MODE="apply"
OFFLINE=0

usage() {
    cat <<'EOF'
Usage:
  ./provision-hlh-ai-engine.tf.sh [--plan|--apply] [--offline]

Options:
  --plan      Run tofu plan only.
  --apply     Run tofu apply (default, with confirmation prompt).
  --offline   Offline-friendly mode (no provider/plugin upgrades and refresh=false).
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

[[ -n "${TF_VAR_pm_api_token_id}" ]] || { echo "ERROR: TF_VAR_pm_api_token_id is required" >&2; exit 1; }
[[ -n "${TF_VAR_pm_api_token_secret}" ]] || { echo "ERROR: TF_VAR_pm_api_token_secret is required" >&2; exit 1; }

cd "${TF_DIR}"

if [[ "$OFFLINE" -eq 1 ]]; then
    tofu init -lockfile=readonly
else
    tofu init
fi

TOFU_ARGS=(
    -var "pm_api_url=${TF_VAR_pm_api_url}"
    -var "pm_api_token_id=${TF_VAR_pm_api_token_id}"
    -var "pm_api_token_secret=${TF_VAR_pm_api_token_secret}"
)

if [[ "$MODE" == "plan" ]]; then
    if [[ "$OFFLINE" -eq 1 ]]; then
        tofu plan -refresh=false "${TOFU_ARGS[@]}"
    else
        tofu plan "${TOFU_ARGS[@]}"
    fi
    exit 0
fi

if [[ "$OFFLINE" -eq 1 ]]; then
    tofu plan -refresh=false "${TOFU_ARGS[@]}"
else
    tofu plan "${TOFU_ARGS[@]}"
fi

echo ""
read -rp "Apply hlh-ai-engine LXC (vmid 101)? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

tofu apply -auto-approve "${TOFU_ARGS[@]}"
