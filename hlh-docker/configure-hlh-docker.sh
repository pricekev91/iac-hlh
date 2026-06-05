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
SSH_PASSWORD=""
LXC_VMID="${LXC_VMID:-102}"

usage() {
    cat <<'EOF'
Usage:
    ./configure-hlh-docker.sh [--host <ip>] [--offline] [--ask-pass|--use-key] [--vmid <id>]

Options:
  --host <ip>  Override target host defined in inventory.
  --offline    Skip online dependency fetches where possible.
    --ask-pass   Use SSH password authentication (default).
    --use-key    Use SSH key authentication with SSH_KEY path.
    --vmid <id>  LXC VMID for password/sshd bootstrap via pct (default: 102).
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
        --vmid)
            [[ $# -ge 2 ]] || { echo "ERROR: --vmid requires a value" >&2; exit 1; }
            LXC_VMID="$2"
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

if [[ "$USE_SSH_PASSWORD" -eq 1 ]]; then
    if [[ -z "$SSH_PASSWORD" ]]; then
        read -rsp "LXC root SSH password: " SSH_PASSWORD
        echo
    fi

    # On Proxmox host, bootstrap root password + SSH policy directly in container.
    if command -v pct >/dev/null 2>&1 && pct status "$LXC_VMID" >/dev/null 2>&1; then
        printf 'root:%s\n' "$SSH_PASSWORD" | pct exec "$LXC_VMID" -- chpasswd || true
        pct exec "$LXC_VMID" -- bash -lc "
            if [ -f /etc/ssh/sshd_config ]; then
                sed -ri 's/^#?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
                sed -ri 's/^#?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
            fi
            systemctl restart ssh || systemctl restart sshd || service ssh restart || true
        " || true
    fi
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

HLH_OFFLINE_BOOL="false"
[[ "$OFFLINE" -eq 1 ]] && HLH_OFFLINE_BOOL="true"
EXTRA_VARS_JSON="{\"hlh_offline\": ${HLH_OFFLINE_BOOL}}"
if [[ -n "$HOST_OVERRIDE" ]]; then
    EXTRA_VARS_JSON="{\"hlh_offline\": ${HLH_OFFLINE_BOOL}, \"ansible_host\": \"${HOST_OVERRIDE}\"}"
fi

export ANSIBLE_HOST_KEY_CHECKING=False
export ANSIBLE_ROLES_PATH="${ANSIBLE_DIR}/roles:${ANSIBLE_ROLES_PATH:-}"

ANSIBLE_ARGS=(
    -i "$INVENTORY"
    "$PLAYBOOK"
    --ssh-common-args "-o UserKnownHostsFile=$HOME/.ssh/known_hosts -o StrictHostKeyChecking=accept-new"
    -e "$EXTRA_VARS_JSON"
)

if [[ "$USE_SSH_PASSWORD" -eq 1 ]]; then
    ANSIBLE_ARGS+=(-e "ansible_password=${SSH_PASSWORD}")
else
    ANSIBLE_ARGS+=(--private-key "$SSH_KEY")
fi

ansible-playbook "${ANSIBLE_ARGS[@]}"
