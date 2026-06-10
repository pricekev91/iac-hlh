#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="${SCRIPT_DIR}/ansible"
INVENTORY="${ANSIBLE_DIR}/inventories/hlh-docker.yml"
PLAYBOOK="${ANSIBLE_DIR}/playbooks/hlh-docker.yml"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
HOST_OVERRIDE=""
OFFLINE=0
VMID_PASSWORD=""
LXC_VMID="${LXC_VMID:-102}"

usage() {
    cat <<'EOF'
Usage:
    ./configure-hlh-docker.sh [--host <ip>] [--offline] [--vmid-password <pwd>] [--vmid <id>]

Options:
  --host <ip>         Override target host defined in inventory.
  --offline           Skip online dependency fetches where possible.
  --vmid-password <p> Password for initial LXC bootstrap (one-time use, not stored).
  --vmid <id>         LXC VMID for password/sshd bootstrap via pct (default: 102).
  -h, --help          Show this help.

Authentication defaults to SSH key-based. Password is only used for the
initial LXC bootstrap (set root password + deploy SSH key), then key auth is used
for all Ansible operations. No passwords are passed on the Ansible command line.
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
        --vmid-password)
            [[ $# -ge 2 ]] || { echo "ERROR: --vmid-password requires a value" >&2; exit 1; }
            VMID_PASSWORD="$2"
            shift
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

# LXC rebuilds often change SSH host keys. Refresh known_hosts automatically.
mkdir -p "$HOME/.ssh"
touch "$HOME/.ssh/known_hosts"
ssh-keygen -R "$TARGET_HOST" >/dev/null 2>&1 || true
if [[ "$OFFLINE" -eq 0 ]]; then
    ssh-keyscan -H "$TARGET_HOST" >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
fi

# --- Bootstrap phase: key auth first, password fallback only if needed ---
KEY_PUB="${SSH_KEY}.pub"

# Helper: test SSH key connectivity
test_key_auth() {
    ssh -o BatchMode=yes -o ConnectTimeout=5 \
        -o UserKnownHostsFile="$HOME/.ssh/known_hosts" \
        -o StrictHostKeyChecking=accept-new \
        -i "$SSH_KEY" "${TARGET_USER}@${TARGET_HOST}" true >/dev/null 2>&1
}

# Try key auth first
if ! test_key_auth; then
    echo "=== SSH key auth failed; bootstrapping with password ==="
    SSH_PASSWORD=""
    if [[ -n "$VMID_PASSWORD" ]]; then
        SSH_PASSWORD="$VMID_PASSWORD"
        echo "Using bootstrap password from argument."
    else
        read -rsp "LXC root SSH password (for initial bootstrap only): " SSH_PASSWORD
        echo
        if [[ -z "$SSH_PASSWORD" ]]; then
            echo "ERROR: Key auth failed and no bootstrap password provided. Aborting." >&2
            exit 1
        fi
    fi

    # Bootstrap via pct exec: set root password, deploy SSH key, enable SSH
    if command -v pct >/dev/null 2>&1 && pct status "$LXC_VMID" >/dev/null 2>&1; then
        echo "=== Bootstrapping LXC ${LXC_VMID} ==="

        # Set root password inside the LXC
        printf 'root:%s\n' "$SSH_PASSWORD" | pct exec "$LXC_VMID" -- chpasswd

        # Deploy SSH key and configure SSH
        if [[ -f "$KEY_PUB" ]]; then
            # Create .ssh directory first (pct push cannot create parent dirs)
            pct exec "$LXC_VMID" -- bash -lc "
                set -euo pipefail
                mkdir -p /root/.ssh
                chmod 700 /root/.ssh
            "
            # Deploy SSH key into LXC via pct push (rootfs storage)
            pct push "$LXC_VMID" "$KEY_PUB" "rootfs:/root/.ssh/authorized_keys"
            pct exec "$LXC_VMID" -- bash -lc "
                set -euo pipefail
                if [ -f /etc/ssh/sshd_config ]; then
                    sed -ri 's/^#?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
                    sed -ri 's/^#?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
                fi
                chmod 600 /root/.ssh/authorized_keys
                chown -R root:root /root/.ssh
                systemctl restart ssh || systemctl restart sshd || service ssh restart || true
            "
        else
            echo "WARNING: ${KEY_PUB} not found; SSH key cannot be deployed." >&2
            # Just set password and enable SSH
            pct exec "$LXC_VMID" -- bash -lc "
                if [ -f /etc/ssh/sshd_config ]; then
                    sed -ri 's/^#?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
                    sed -ri 's/^#?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
                fi
                systemctl restart ssh || systemctl restart sshd || service ssh restart || true
            "
        fi
    fi
fi

# Re-verify key auth works now
if ! test_key_auth; then
    echo "ERROR: SSH key auth still not working after bootstrap. Check the LXC manually." >&2
    exit 1
fi
echo "SSH key auth verified. Running Ansible with key-based auth."

# Prepare Ansible — key-based auth only, NO password on command line
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
    --private-key "$SSH_KEY"
)

echo "=== Running Ansible playbook ==="
ansible-playbook "${ANSIBLE_ARGS[@]}"
