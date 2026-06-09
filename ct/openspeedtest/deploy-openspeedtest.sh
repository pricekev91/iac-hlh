#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAYBOOK="${SCRIPT_DIR}/ansible-playbook.yml"
INVENTORY="${SCRIPT_DIR}/ansible-inventory.yml"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
HOST_OVERRIDE=""
USE_SSH_PASSWORD=0
SSH_PASSWORD=""

usage() {
    cat <<'EOF'
Usage:
    ./deploy-openspeedtest.sh [--host <ip>] [--ask-pass|--use-key] [-h|--help]

Options:
  --host <ip>    Override target host (default: from inventory).
  --ask-pass     Use SSH password authentication.
  --use-key      Use SSH key authentication with SSH_KEY path (default).
  -h, --help     Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)
            [[ $# -ge 2 ]] || { echo "ERROR: --host requires a value" >&2; exit 1; }
            HOST_OVERRIDE="$2"
            shift
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

[[ -n "$TARGET_HOST" ]] || { echo "ERROR: Could not determine target host." >&2; exit 1; }

cd "$SCRIPT_DIR"

# Ensure ansible is available (check venv first, then system)
ANSIBLE_CMD=""
VENV_ANSIBLE="/home/pricekev/git/iac-hlh/.tools/ansible-venv/bin/ansible-playbook"
if [[ -x "$VENV_ANSIBLE" ]]; then
    ANSIBLE_CMD="$VENV_ANSIBLE"
    echo "=== using ansible venv: $VENV_ANSIBLE ==="
elif command -v ansible-playbook >/dev/null 2>&1; then
    ANSIBLE_CMD="$(command -v ansible-playbook)"
    echo "=== using system ansible: $ANSIBLE_CMD ==="
else
    echo "=== ansible not found, installing ==="
    if command -v pacman >/dev/null 2>&1; then
        sudo pacman -Sy --noconfirm ansible
        ANSIBLE_CMD="$(command -v ansible-playbook)"
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y ansible
        ANSIBLE_CMD="$(command -v ansible-playbook)"
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get install -y ansible
        ANSIBLE_CMD="$(command -v ansible-playbook)"
    else
        echo "ERROR: unsupported package manager — install ansible manually" >&2
        exit 1
    fi
fi

# Install community.docker collection
VENV_GALAXY="/home/pricekev/git/iac-hlh/.tools/ansible-venv/bin/ansible-galaxy"
if "$VENV_GALAXY" collection list community.docker 2>/dev/null | grep -q community.docker; then
    echo "=== community.docker collection already installed ==="
else
    echo "=== installing community.docker collection ==="
    "$VENV_GALAXY" collection install community.docker
fi

if [[ "$USE_SSH_PASSWORD" -eq 0 ]]; then
    [[ -f "$SSH_KEY" ]] || { echo "ERROR: SSH key not found at $SSH_KEY" >&2; exit 1; }
fi

if [[ "$USE_SSH_PASSWORD" -eq 1 ]] && ! command -v sshpass >/dev/null 2>&1; then
    echo "=== sshpass not found, installing ==="
    if command -v pacman >/dev/null 2>&1; then
        sudo pacman -Sy --noconfirm sshpass
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y sshpass
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get install -y sshpass
    else
        echo "ERROR: install sshpass manually (AUR: yay -S sshpass)" >&2
        exit 1
    fi
fi

# Refresh known_hosts
mkdir -p "$HOME/.ssh"
touch "$HOME/.ssh/known_hosts"
ssh-keygen -R "$TARGET_HOST" >/dev/null 2>&1 || true
ssh-keyscan -H "$TARGET_HOST" >> "$HOME/.ssh/known_hosts" 2>/dev/null || true

if [[ "$USE_SSH_PASSWORD" -eq 1 ]]; then
    if [[ -z "$SSH_PASSWORD" ]]; then
        read -rsp "Root SSH password for ${TARGET_HOST}: " SSH_PASSWORD
        echo
    fi

    # Bootstrap root password + SSH policy via Proxmox LXC
    if command -v pct >/dev/null 2>&1 && pct status 102 >/dev/null 2>&1; then
        printf 'root:%s\n' "$SSH_PASSWORD" | pct exec 102 -- chpasswd || true
        pct exec 102 -- bash -lc "
            if [ -f /etc/ssh/sshd_config ]; then
                sed -ri 's/^#?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
                sed -ri 's/^#?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
            fi
            systemctl restart ssh || systemctl restart sshd || true
        " || true
    fi
fi

# Verify key auth works; fall back to password if not
if [[ "$USE_SSH_PASSWORD" -eq 0 ]]; then
    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 -o UserKnownHostsFile="$HOME/.ssh/known_hosts" -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" "${TARGET_USER}@${TARGET_HOST}" true >/dev/null 2>&1; then
        echo "=== SSH key auth failed; switching to password prompt ==="
        USE_SSH_PASSWORD=1
    fi
fi
if [[ "$USE_SSH_PASSWORD" -eq 1 ]] && ! command -v sshpass >/dev/null 2>&1; then
    echo "=== sshpass not found, installing ==="
    if command -v pacman >/dev/null 2>&1; then
        sudo pacman -Sy --noconfirm sshpass
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y sshpass
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get install -y sshpass
    else
        echo "ERROR: install sshpass manually (AUR: yay -S sshpass)" >&2
        exit 1
    fi
fi

EXTRA_VARS_JSON="{\"ansible_host\": \"${HOST_OVERRIDE:-$TARGET_HOST}\"}"
export ANSIBLE_HOST_KEY_CHECKING=False

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

echo "=== Deploying OpenSpeedTest to ${TARGET_HOST} ==="
$ANSIBLE_CMD "${ANSIBLE_ARGS[@]}"
echo "=== Deployment complete ==="
