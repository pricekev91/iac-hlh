#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/opentofu"
SECRETS_FILE=""

usage() {
	cat <<'EOF'
Usage:
  ./provision-hlh-ai-engine.sh [apply|plan] [--offline]
  ./provision-hlh-ai-engine.sh [--apply|--plan] [--offline]

Examples:
  ./provision-hlh-ai-engine.sh
  ./provision-hlh-ai-engine.sh apply
  ./provision-hlh-ai-engine.sh plan --offline

Optional local secrets file:
	${SCRIPT_DIR}/.hlh-secrets
	${TF_DIR}/.hlh-secrets

Supported variables:
	TF_VAR_pm_api_url
	TF_VAR_pm_api_token_id
	TF_VAR_pm_api_token_secret
EOF
}

MODE="apply"
OFFLINE=0

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

for candidate in "${TF_DIR}/.hlh-secrets" "${SCRIPT_DIR}/.hlh-secrets"; do
	if [[ -f "$candidate" ]]; then
		SECRETS_FILE="$candidate"
		break
	fi
done

if [[ -n "$SECRETS_FILE" ]]; then
	set -a
	# shellcheck disable=SC1090
	source "$SECRETS_FILE"
	set +a
fi

export TF_VAR_pm_api_url="${TF_VAR_pm_api_url:-https://192.168.1.10:8006/api2/json}"

if [[ -z "${TF_VAR_pm_api_token_id:-}" ]]; then
	read -rp "Proxmox API token ID (example: tofu@pve!tofu-hlh-ai-engine): " TF_VAR_pm_api_token_id
	export TF_VAR_pm_api_token_id
fi

if [[ -z "${TF_VAR_pm_api_token_secret:-}" ]]; then
	read -rsp "Proxmox API token secret: " TF_VAR_pm_api_token_secret
	echo
	export TF_VAR_pm_api_token_secret
fi

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
