#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_SCRIPT="${SCRIPT_DIR}/deploy-hlh-docker.tf.sh"

usage() {
	cat <<'EOF'
Usage:
  ./provision-hlh-docker.sh [apply|plan] [--offline]
  ./provision-hlh-docker.sh [--apply|--plan] [--offline]

Examples:
  ./provision-hlh-docker.sh
  ./provision-hlh-docker.sh apply
  ./provision-hlh-docker.sh plan --offline
EOF
}

MODE="apply"
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
	case "$1" in
		apply)
			MODE="apply"
			;;
		plan)
			MODE="plan"
			;;
		--apply)
			MODE="apply"
			;;
		--plan)
			MODE="plan"
			;;
		--offline)
			EXTRA_ARGS+=("--offline")
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

export TF_VAR_pm_api_url="${TF_VAR_pm_api_url:-https://192.168.1.10:8006/api2/json}"

if [[ -z "${TF_VAR_pm_api_token_id:-}" ]]; then
	read -rp "Proxmox API token ID (example: tofu@pve!tofu-hlh-docker): " TF_VAR_pm_api_token_id
	export TF_VAR_pm_api_token_id
fi

if [[ -z "${TF_VAR_pm_api_token_secret:-}" ]]; then
	read -rsp "Proxmox API token secret: " TF_VAR_pm_api_token_secret
	echo
	export TF_VAR_pm_api_token_secret
fi

"${TF_SCRIPT}" "--${MODE}" "${EXTRA_ARGS[@]}"
