#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="${SCRIPT_DIR}/ansible"
INVENTORY="${ANSIBLE_DIR}/inventories/hlh-docker.yml"
PLAYBOOK="${ANSIBLE_DIR}/playbooks/hlh-docker.yml"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
HOST_OVERRIDE=""
OFFLINE=0
USE_SSH_PASSWORD=1

usage() {
    cat <<'EOF'
Usage:
    ./configure-hlh-docker.sh [--host <ip>] [--offline] [--ask-pass|--use-key]

Options:
  --host <ip>  Override target host defined in inventory.
  --offline    Skip online dependency fetches where possible.
    --ask-pass   Use SSH password authentication (default).
    --use-key    Use SSH key authentication with SSH_KEY path.
  -h, --help   Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)
            [[ $# -ge 2 ]] || { echo "ERROR: --host requires a value" >&2; exit 1; }
            HOST_OVERRIDE="$2"
            shift
            ;;
        --offline)
            OFFLINE=1
            ;;
        --ask-pass|--password)
            USE_SSH_PASSWORD=1
            ;;
        --use-key)
            USE_SSH_PASSWORD=0
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

[[ -f "$PLAYBOOK" ]] || { echo "ERROR: Playbook not found: $PLAYBOOK" >&2; exit 1; }
[[ -f "$INVENTORY" ]] || { echo "ERROR: Inventory not found: $INVENTORY" >&2; exit 1; }

TARGET_HOST="$HOST_OVERRIDE"
if [[ -z "$TARGET_HOST" ]]; then
    TARGET_HOST="$(awk '/ansible_host:/ { print $2; exit }' "$INVENTORY")"
fi

TARGET_USER="$(awk '/ansible_user:/ { print $2; exit }' "$INVENTORY")"
TARGET_USER="${TARGET_USER:-root}"

[[ -n "$TARGET_HOST" ]] || { echo "ERROR: Could not determine target host from inventory or --host." >&2; exit 1; }

cd "$ANSIBLE_DIR"

# Ensure ansible is available.
if ! command -v ansible-playbook >/dev/null 2>&1; then
    echo "=== ansible not found, installing via apt ==="
    apt-get install -y ansible
fi

# Install collection requirements only when online.
if [[ "$OFFLINE" -eq 0 && -f requirements.yml ]]; then
    ansible-galaxy collection install -r requirements.yml
fi

if [[ "$USE_SSH_PASSWORD" -eq 0 ]]; then
    [[ -f "$SSH_KEY" ]] || { echo "ERROR: SSH key not found at $SSH_KEY (or run with --ask-pass)." >&2; exit 1; }
fi

if [[ "$USE_SSH_PASSWORD" -eq 1 ]] && ! command -v sshpass >/dev/null 2>&1; then
    echo "=== sshpass not found, installing via apt ==="
    apt-get install -y sshpass
fi

# LXC rebuilds often change SSH host keys. Refresh known_hosts automatically.
mkdir -p "$HOME/.ssh"
touch "$HOME/.ssh/known_hosts"
ssh-keygen -R "$TARGET_HOST" >/dev/null 2>&1 || true
if [[ "$OFFLINE" -eq 0 ]]; then
    ssh-keyscan -H "$TARGET_HOST" >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
fi

# If key auth is selected, verify it actually works. If not, fall back to password prompt.
if [[ "$USE_SSH_PASSWORD" -eq 0 ]]; then
    SSH_TEST_OPTS=(
        -o BatchMode=yes
        -o ConnectTimeout=5
        -o UserKnownHostsFile="$HOME/.ssh/known_hosts"
        -o StrictHostKeyChecking=accept-new
    )
    if ! ssh "${SSH_TEST_OPTS[@]}" -i "$SSH_KEY" "${TARGET_USER}@${TARGET_HOST}" true >/dev/null 2>&1; then
        echo "=== SSH key auth failed for ${TARGET_USER}@${TARGET_HOST}; switching to password prompt mode ==="
        USE_SSH_PASSWORD=1
    fi
fi

if [[ "$USE_SSH_PASSWORD" -eq 1 ]] && ! command -v sshpass >/dev/null 2>&1; then
    echo "=== sshpass not found, installing via apt ==="
    apt-get install -y sshpass
fi

EXTRA_VARS=("hlh_offline=$([[ "$OFFLINE" -eq 1 ]] && echo true || echo false)")
[[ -n "$HOST_OVERRIDE" ]] && EXTRA_VARS+=("ansible_host=${HOST_OVERRIDE}")

export ANSIBLE_HOST_KEY_CHECKING=False

ANSIBLE_ARGS=(
    -i "$INVENTORY"
    "$PLAYBOOK"
    --ssh-common-args "-o UserKnownHostsFile=$HOME/.ssh/known_hosts -o StrictHostKeyChecking=accept-new"
    -e "${EXTRA_VARS[*]}"
)

if [[ "$USE_SSH_PASSWORD" -eq 1 ]]; then
    ANSIBLE_ARGS+=(--ask-pass)
else
    ANSIBLE_ARGS+=(--private-key "$SSH_KEY")
fi

ansible-playbook "${ANSIBLE_ARGS[@]}"
