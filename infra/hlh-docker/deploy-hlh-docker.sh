#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_SCRIPT="${SCRIPT_DIR}/deploy-hlh-docker.tf.sh"
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

if [[ "$MODE" == "plan" && "$RUN_TF" -eq 0 ]]; then
    echo "ERROR: --plan requires OpenTofu stage to run." >&2
    exit 1
fi

if [[ "$RUN_TF" -eq 1 ]]; then
    TF_ARGS=("--${MODE}")
    [[ "$OFFLINE" -eq 1 ]] && TF_ARGS+=("--offline")
    "${TF_SCRIPT}" "${TF_ARGS[@]}"
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
