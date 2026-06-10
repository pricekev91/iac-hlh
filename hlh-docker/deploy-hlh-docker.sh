#!/usr/bin/env bash
# ============================================================================
# HLH-Docker — Pure-Bash Infrastructure-as-Code for Proxmox LXC (vmid 102)
# ============================================================================
#
# Deploys an unprivileged LXC running Docker Engine, Dockhand (GUI), and
# LazyDocker (TUI) on Proxmox VE. All LXC lifecycle, installation, and
# configuration is handled inside this single script.
#
# USAGE:
#   ./deploy-hlh-docker.sh --apply      Deploy LXC + install everything (default)
#   ./deploy-hlh-docker.sh --plan        Show what would be done (dry-run)
#   ./deploy-hlh-docker.sh --config-only Install/configure only (LXC must exist)
#   ./deploy-hlh-docker.sh --nuke        Destroy existing LXC and rebuild from scratch
#   ./deploy-hlh-docker.sh --help        Show this help
#
# ENVIRONMENT VARIABLES (all have sane defaults):
#   HLH_LXC_VMID          Container VMID       (default: 102)
#   HLH_LXC_HOSTNAME      Container hostname   (default: hlh-docker)
#   HLH_LXC_IP            Container IP address (default: 192.168.1.13)
#   HLH_LXC_GW            Gateway address      (default: 192.168.1.1)
#   HLH_LXC_NET           Bridge interface     (default: vmbr0)
#   HLH_LXC_ROOTPWD       Root password         (interactive prompt if unset)
#   HLH_TARGET_NODE       Proxmox node name    (default: prox01)
#   HLH_TEMPLATE          OS template path     (default: local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst)
#   HLH_PROXMOX_ENDPOINT  Proxmox API URL      (default: https://192.168.1.10:8006/)
#   HLH_SSH_KEY           Path to SSH public key for bootstrap (default: ~/.ssh/id_ed25519.pub)
#   HLH_CORES             vCPU count           (default: 4)
#   HLH_MEMORY            Memory in MB         (default: 4096)
#   HLH_DISK              Rootfs size in GB    (default: 32)
#   HLH_DISK_POOL         ZFS storage pool     (default: RaidZ1-6TB)
#   HLH_NESTING           Enable nesting       (default: 1)
#   HLH_KEYCTL            Enable keyctl        (default: 1)
#
# ZFS DATASETS (auto-created if missing):
#   RaidZ1-6TB/hlh-docker/docker-data  → bind-mounted to /var/lib/docker
#   RaidZ1-6TB/hlh-docker/dockhand-data → bind-mounted to /srv/dockhand/data
#
# ============================================================================
set -euo pipefail

# --- Configuration -----------------------------------------------------------

LXC_VMID="${HLH_LXC_VMID:-102}"
LXC_HOSTNAME="${HLH_LXC_HOSTNAME:-hlh-docker}"
LXC_IP="${HLH_LXC_IP:-192.168.1.13}"
LXC_GW="${HLH_LXC_GW:-192.168.1.1}"
LXC_NET="${HLH_LXC_NET:-vmbr0}"
PROXMOX_ENDPOINT="${HLH_PROXMOX_ENDPOINT:-https://192.168.1.10:8006/}"
TARGET_NODE="${HLH_TARGET_NODE:-prox01}"
TEMPLATE="${HLH_TEMPLATE:-local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst}"
SSH_KEY="${HLH_SSH_KEY:-$HOME/.ssh/id_ed25519.pub}"
CORES="${HLH_CORES:-4}"
MEMORY="${HLH_MEMORY:-4096}"
DISK="${HLH_DISK:-32}"
DISK_POOL="${HLH_DISK_POOL:-RaidZ1-6TB}"
NESTING="${HLH_NESTING:-1}"
KEYCTL="${HLH_KEYCTL:-1}"

DOCKER_DATA_DS="${DISK_POOL}/hlh-docker/docker-data"
DOCKHAND_DATA_DS="${DISK_POOL}/hlh-docker/dockhand-data"

# --- Mode flags ---------------------------------------------------------------

MODE="apply"   # apply | plan | config-only
NUKE=0         # 1 = nuke-and-rebuild

# --- Colour helpers (safe when stdout is not a terminal) ----------------------

COLOUR_RESET=""
COLOUR_GREEN=""
COLOUR_RED=""
COLOUR_YELLOW=""
COLOUR_BOLD=""

if [[ -t 1 ]]; then
    COLOUR_GREEN=$(printf '\033[32m')
    COLOUR_RED=$(printf '\033[31m')
    COLOUR_YELLOW=$(printf '\033[33m')
    COLOUR_BOLD=$(printf '\033[1m')
    COLOUR_RESET=$(printf '\033[0m')
fi

info()    { printf "${COLOUR_BOLD}[INFO]${COLOUR_RESET}  %s\n" "$*"; }
ok()      { printf "${COLOUR_GREEN}[ OK ]${COLOUR_RESET}  %s\n" "$*"; }
warn()    { printf "${COLOUR_YELLOW}[WARN]${COLOUR_RESET}  %s\n" "$*"; }
fail()    { printf "${COLOUR_RED}[FAIL]${COLOUR_RESET}  %s\n" "$*" >&2; }
section() { printf "\n${COLOUR_BOLD}=== %s ===${COLOUR_RESET}\n" "$*"; }

# --- Usage --------------------------------------------------------------------

usage() {
    cat <<'USAGE'
Usage:
  ./deploy-hlh-docker.sh [options]

Options:
  --apply          Deploy LXC + install all software (default)
  --plan           Show what would be done without making changes (dry-run)
  --config-only    Install/configure software only; LXC must already exist
  --nuke           Destroy existing LXC (if running, prompt first) and rebuild
  -h, --help       Show this help

All settings are configurable via environment variables. Run the script with
--help to see the full list, or just set them inline:

  HLH_LXC_IP=192.168.1.14 ./deploy-hlh-docker.sh --apply

USAGE
}

# --- Argument parsing ---------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply)       MODE="apply" ;;
        --plan)        MODE="plan" ;;
        --config-only) MODE="config-only" ;;
        --nuke)        NUKE=1; MODE="apply" ;;
        -h|--help)     usage; exit 0 ;;
        *)             fail "Unknown option: $1"; usage; exit 1 ;;
    esac
    shift
done

# --- Validation helpers -------------------------------------------------------

# Check whether a pct command succeeds (suppress output)
pct_ok() { pct "$@" >/dev/null 2>&1; }

# Check if the LXC exists
lxc_exists() { pct_ok status "$LXC_VMID"; }

# Check if the LXC is running
lxc_running() {
    [[ "$(pct status "$LXC_VMID" 2>/dev/null)" == *"running"* ]]
}

# --- Pre-flight checks --------------------------------------------------------

section "Pre-flight checks"

# 1. We must be on the Proxmox host (or at least have pct available)
if ! command -v pct >/dev/null 2>&1; then
    fail "pct command not found. Run this script on the Proxmox host." >&2
    exit 1
fi
ok "pct command found"

# 2. Verify Proxmox API is reachable
# Use curl -sI (head request) without -f so we don't fail on 401/403 (auth-required).
# Just verify TCP/TLS connectivity succeeds.
if ! curl -sk --connect-timeout 5 -o /dev/null "${PROXMOX_ENDPOINT}/api2/json/nodes" 2>/dev/null; then
    fail "Cannot reach Proxmox API at ${PROXMOX_ENDPOINT}" >&2
    exit 1
fi
ok "Proxmox API reachable"

# 3. Verify target node is valid
if ! pct_ok status "$TARGET_NODE"; then
    # It's a node, not a container — status returns exit 1 for nodes, which is fine
    :
fi
if ! echo "$TARGET_NODE" | grep -qE '^[a-zA-Z0-9_-]+$'; then
    fail "Invalid target node name: $TARGET_NODE" >&2
    exit 1
fi
ok "Target node: $TARGET_NODE"

# 4. Verify ZFS pool exists
if ! zpool list "$DISK_POOL" >/dev/null 2>&1; then
    fail "ZFS pool '${DISK_POOL}' not found on $TARGET_NODE" >&2
    exit 1
fi
ok "ZFS pool '${DISK_POOL}' exists"

# 5. Verify OS template is available
TEMPLATE_PATH="${TEMPLATE#local:vztmpl/}"   # strip "local:vztmpl/" prefix
TEMPLATE_CACHE="/var/lib/vz/template/cache/${TEMPLATE_PATH}"
if [[ ! -f "$TEMPLATE_CACHE" ]]; then
    fail "OS template not found: $TEMPLATE_CACHE" >&2
    exit 1
fi
ok "OS template found: ${TEMPLATE_PATH}"

# 6. If config-only mode, LXC must already exist and be running
if [[ "$MODE" == "config-only" ]]; then
    if ! lxc_exists; then
        fail "LXC ${LXC_VMID} does not exist. Use --apply to create it first." >&2
        exit 1
    fi
    if ! lxc_running; then
        fail "LXC ${LXC_VMID} is not running. Start it first or use --apply." >&2
        exit 1
    fi
    ok "LXC ${LXC_VMID} exists and is running (config-only mode)"
fi

# 7. Check if LXC already exists (non-nuke)
if [[ "$MODE" != "config-only" && "$NUKE" -eq 0 && lxc_exists ]]; then
    if lxc_running; then
        echo ""
        read -rp "LXC ${LXC_VMID} is already running. Quit? (y/n) " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            info "Quitting. Use --nuke to destroy and rebuild."
            exit 0
        fi
    fi
fi

# --- Plan mode ----------------------------------------------------------------

if [[ "$MODE" == "plan" ]]; then
    section "Plan (what would be done)"

    if ! lxc_exists; then
        info "Would create LXC ${LXC_VMID} (${LXC_HOSTNAME})"
        info "  Hostname:   ${LXC_HOSTNAME}"
        info "  IP:         ${LXC_IP}/24 (gateway ${LXC_GW})"
        info "  Template:   ${TEMPLATE_PATH}"
        info "  Cores:      ${CORES}"
        info "  Memory:     ${MEMORY} MB"
        info "  Disk:       ${DISK} GB (${DISK_POOL})"
        info "  Features:   nesting=${NESTING}, keyctl=${KEYCTL}"
        info "  Unprivileged: yes"
    else
        info "LXC ${LXC_VMID} already exists."
        info "Config would be updated if settings differ."
    fi

    info "Would create ZFS datasets if missing:"
    info "  ${DOCKER_DATA_DS}"
    info "  ${DOCKHAND_DATA_DS}"

    info "Would install inside LXC:"
    info "  Docker Engine (docker-ce, docker-ce-cli, containerd.io, docker-buildx-plugin, docker-compose-plugin)"
    info "  Dockhand (Docker container: fnsys/dockhand:latest)"
    info "  LazyDocker (binary from GitHub releases)"

    info "Plan complete. No changes were made."
    exit 0
fi

# --- Nuke mode: destroy existing LXC ------------------------------------------

if [[ "$NUKE" -eq 1 && lxc_exists ]]; then
    if lxc_running; then
        section "Nuke: stopping LXC ${LXC_VMID}"
        pct stop "$LXC_VMID"
        ok "LXC stopped"
    fi
    section "Nuke: destroying LXC ${LXC_VMID}"
    pct destroy "$LXC_VMID"
    ok "LXC destroyed"
fi

# --- ZFS dataset creation -----------------------------------------------------

section "ZFS datasets"

create_zfs_ds() {
    local ds="$1"
    if zfs list -H -o name "$ds" >/dev/null 2>&1; then
        ok "Dataset already exists: ${ds}"
    else
        info "Creating ZFS dataset: ${ds}"
        if zfs create "$ds"; then
            ok "Dataset created: ${ds}"
        else
            fail "Failed to create ZFS dataset: ${ds}" >&2
            exit 1
        fi
    fi
}

create_zfs_ds "$DOCKER_DATA_DS"
create_zfs_ds "$DOCKHAND_DATA_DS"

# --- LXC creation / configuration ---------------------------------------------

section "LXC ${LXC_VMID} (${LXC_HOSTNAME})"

if ! lxc_exists; then
    # --- New LXC creation ---
    info "Creating LXC ${LXC_VMID} from template..."

    pct create "$LXC_VMID" "$TEMPLATE" \
        --hostname "${LXC_HOSTNAME}" \
        --unprivileged 1 \
        --cores "${CORES}" \
        --memory "${MEMORY}" \
        --swap 0 \
        --rootfs "${DISK_POOL}:${DISK}" \
        --net0 "name=eth0,bridge=${LXC_NET},ip=${LXC_IP}/24,gw=${LXC_GW}" \
        --features "nesting=${NESTING},keyctl=${KEYCTL}"

    ok "LXC created"
else
    # --- Existing LXC: update config if needed ---
    info "LXC ${LXC_VMID} exists. Updating configuration..."

    # Core settings that may need updating
    pct set "$LXC_VMID" \
        --cores "${CORES}" \
        --memory "${MEMORY}" \
        --features "nesting=${NESTING},keyctl=${KEYCTL}"

    # Network: always re-apply to guarantee correct IP
    pct set "$LXC_VMID" \
        --net "name=eth0,bridge=${LXC_NET},ip=${LXC_IP}/24,gw=${LXC_GW}"

    ok "LXC configuration updated"
fi

# --- Root password + SSH key bootstrap ----------------------------------------

section "Authentication bootstrap"

# Get root password (prompt if not set)
ROOT_PWD="${HLH_LXC_ROOTPWD:-}"
if [[ -z "$ROOT_PWD" ]]; then
    info "No root password provided. You can set it later with: pct enter $LXC_VMID && passwd root"
else
    pct set "$LXC_VMID" --rootpw "$ROOT_PWD"
    ok "Root password set"
fi

# Deploy SSH public key into LXC for key-based auth
if [[ -f "$SSH_KEY" ]]; then
    info "Deploying SSH public key to LXC..."

    if lxc_running; then
        pct exec "$LXC_VMID" -- bash -lc '
            set -euo pipefail
            mkdir -p /root/.ssh
            chmod 700 /root/.ssh
        '
        pct push "$LXC_VMID" "$SSH_KEY" "rootfs:/root/.ssh/authorized_keys"
        pct exec "$LXC_VMID" -- bash -lc '
            set -euo pipefail
            chmod 600 /root/.ssh/authorized_keys
            chown -R root:root /root/.ssh
            if [ -f /etc/ssh/sshd_config ]; then
                sed -ri "\/^[^#]*PermitRootLogin/s/.*/PermitRootLogin prohibit-password/" /etc/ssh/sshd_config
            fi
            systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
        '
    else
        pct exec "$LXC_VMID" -- bash -lc '
            set -euo pipefail
            mkdir -p /root/.ssh
            chmod 700 /root/.ssh
            echo "'"$(cat "$SSH_KEY")"'" > /root/.ssh/authorized_keys
            chmod 600 /root/.ssh/authorized_keys
            chown -R root:root /root/.ssh
            if [ -f /etc/ssh/sshd_config ]; then
                sed -ri "\/^[^#]*PermitRootLogin/s/.*/PermitRootLogin prohibit-password/" /etc/ssh/sshd_config
            fi
            systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
        '
    fi
    ok "SSH public key deployed"
else
    warn "SSH key not found at ${SSH_KEY}; skipping SSH key deployment"
    warn "Password-based login is configured. Ensure you remember the password."
fi

# --- Start LXC ----------------------------------------------------------------

if ! lxc_running; then
    info "Starting LXC ${LXC_VMID}..."
    pct start "$LXC_VMID"
    ok "LXC started"
else
    info "LXC ${LXC_VMID} already running"
fi

# --- Bind mount ZFS datasets --------------------------------------------------

section "Bind mounts"

# Mount Dockhand data
if pct get "$LXC_VMID" 2>/dev/null | grep -q "mp1:"; then
    info "Mount point mp1 already configured"
else
    info "Adding bind mount: ${DOCKHAND_DATA_DS} → /srv/dockhand/data"
    pct set "$LXC_VMID" --mount "bind=${DOCKHAND_DATA_DS},mp=/srv/dockhand/data,vol=${DOCKHAND_DATA_DS},content=dir"
    ok "Bind mount added: Dockhand data"
fi

# Mount Docker data
if pct get "$LXC_VMID" 2>/dev/null | grep -q "mp2:"; then
    info "Mount point mp2 already configured"
else
    info "Adding bind mount: ${DOCKER_DATA_DS} → /var/lib/docker"
    pct set "$LXC_VMID" --mount "bind=${DOCKER_DATA_DS},mp=/var/lib/docker,vol=${DOCKER_DATA_DS},content=dir"
    ok "Bind mount added: Docker data"
fi

# Recreate directories inside LXC (in case they were removed)
pct exec "$LXC_VMID" -- bash -lc '
    set -euo pipefail
    mkdir -p /srv/dockhand/data
    mkdir -p /srv/dockhand/run
'

# --- Configuration-only mode (skip LXC install) --------------------------------

if [[ "$MODE" == "config-only" ]]; then
    section "Configuration-only mode"
    info "LXC ${LXC_VMID} is running. Proceeding with software installation..."
fi

# --- Software installation inside LXC -----------------------------------------

section "Software installation"

# Helper: run a command inside the LXC, printing output
lxc_cmd() {
    pct exec "$LXC_VMID" -- bash -lc "$1"
}

# --- Docker Engine ---

info "Installing Docker Engine..."

DOCKER_INSTALLED=$(pct exec "$LXC_VMID" -- bash -lc 'command -v docker' 2>/dev/null || true)

if [[ -z "$DOCKER_INSTALLED" ]]; then
    lxc_cmd '
        set -euo pipefail

        # Prerequisites
        apt-get update
        apt-get install -y \
            apt-transport-https \
            ca-certificates \
            curl \
            gnupg \
            lsb-release

        # Docker GPG key
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg

        # Docker repository
        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
            https://download.docker.com/linux/ubuntu \
            $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
            > /etc/apt/sources.list.d/docker.list

        # Install Docker
        apt-get update
        apt-get install -y \
            docker-ce \
            docker-ce-cli \
            containerd.io \
            docker-buildx-plugin \
            docker-compose-plugin
    '
    ok "Docker Engine installed"
else
    ok "Docker already installed: ${DOCKER_INSTALLED}"
fi

# --- Docker service inside LXC ---
# Docker inside an unprivileged LXC needs to talk to the host Docker daemon.
# We configure the LXC to accept connections via the socket bind mount.
# The host-side dockerd is already running. We just need the client tools.

info "Configuring Docker inside LXC..."
lxc_cmd '
    set -euo pipefail

    # Ensure docker group exists
    getent group docker >/dev/null 2>&1 || groupadd docker

    # Add root to docker group (allows docker commands without sudo)
    usermod -aG docker root 2>/dev/null || true
'

ok "Docker configuration complete"

# --- Dockhand ---

info "Installing Dockhand..."

DOCKHAND_RUNNING=$(pct exec "$LXC_VMID" -- bash -lc 'docker inspect -f "{{.State.Running}}" dockhand 2>/dev/null || echo "false"' 2>/dev/null || true)

if [[ "$DOCKHAND_RUNNING" == "true" ]]; then
    ok "Dockhand is already running"
else
    lxc_cmd '
        set -euo pipefail

        # Pull Dockhand image
        docker pull fnsys/dockhand:latest

        # Stop and remove existing container (if any)
        docker rm -f dockhand 2>/dev/null || true

        # Deploy Dockhand container
        docker run -d \
            --name dockhand \
            --restart unless-stopped \
            -v /srv/dockhand/data:/data \
            -v /var/run/docker.sock:/var/run/docker.sock \
            -v /srv/dockhand/run:/run \
            -p 80:3000 \
            fnsys/dockhand:latest

        echo "Dockhand container started"
    '
    ok "Dockhand deployed"
fi

# --- LazyDocker ---

info "Installing LazyDocker..."

LAZYDOCKER_INSTALLED=$(pct exec "$LXC_VMID" -- bash -lc 'command -v lazydocker' 2>/dev/null || true)

if [[ -z "$LAZYDOCKER_INSTALLED" ]]; then
    lxc_cmd '
        set -euo pipefail

        LAZYDOCKER_VERSION="0.25.2"
        curl -fsSL "https://github.com/jesseduffield/lazydocker/releases/download/v${LAZYDOCKER_VERSION}/lazydocker_${LAZYDOCKER_VERSION}_Linux_x86_64.tar.gz" \
            | tar xz -C /tmp
        mv /tmp/lazydocker /usr/local/bin/lazydocker
        chmod 755 /usr/local/bin/lazydocker
        rm -f /tmp/lazydocker
    '
    ok "LazyDocker installed"
else
    ok "LazyDocker already installed: ${LAZYDOCKER_INSTALLED}"
fi

# --- Post-install verification -----------------------------------------------

section "Verification"

# 1. LXC status
info "LXC status:"
pct status "$LXC_VMID"

# 2. Network
info "Container IP:"
pct exec "$LXC_VMID" -- bash -lc 'ip -4 addr show eth0 | grep "inet "'

# 3. Docker
info "Docker version:"
pct exec "$LXC_VMID" -- bash -lc 'docker --version 2>/dev/null || echo "Docker not found"'

# 4. Docker socket check
info "Docker socket:"
pct exec "$LXC_VMID" -- bash -lc 'ls -la /var/run/docker.sock 2>/dev/null || echo "Socket not mounted"'

# 5. Dockhand
info "Dockhand container:"
pct exec "$LXC_VMID" -- bash -lc 'docker ps --filter name=dockhand --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"' 2>/dev/null || echo "Dockhand not running"

# 6. Dockhand data mount
info "Dockhand data mount:"
pct exec "$LXC_VMID" -- bash -lc 'mount | grep dockhand || echo "Not mounted"'

# 7. Docker data mount
info "Docker data mount:"
pct exec "$LXC_VMID" -- bash -lc 'mount | grep docker || echo "Not mounted"'

# 8. LazyDocker
info "LazyDocker version:"
pct exec "$LXC_VMID" -- bash -lc 'lazydocker --version 2>/dev/null || echo "Not installed"'

# 9. ZFS datasets
info "ZFS datasets:"
zfs list "${DISK_POOL}/hlh-docker"

# --- Final summary ------------------------------------------------------------

section "Deployment summary"

printf "  %-20s %s\n" "LXC VMID:" "${LXC_VMID}"
printf "  %-20s %s\n" "Hostname:" "${LXC_HOSTNAME}"
printf "  %-20s %s\n" "IP Address:" "${LXC_IP}"
printf "  %-20s %s\n" "Gateway:" "${LXC_GW}"
printf "  %-20s %s\n" "Node:" "${TARGET_NODE}"
printf "  %-20s %s\n" "Template:" "${TEMPLATE_PATH}"
printf "  %-20s %s\n" "Cores:" "${CORES}"
printf "  %-20s %s\n" "Memory:" "${MEMORY} MB"
printf "  %-20s %s\n" "Disk:" "${DISK} GB (${DISK_POOL})"
printf "  %-20s %s\n" "Features:" "nesting=${NESTING}, keyctl=${KEYCTL}"
printf "  %-20s %s\n" "Unprivileged:" "yes"
printf "  %-20s %s\n" "Dockhand GUI:" "http://${LXC_IP}:80"
printf "  %-20s %s\n" "Dockhand data:" "/srv/dockhand/data"
printf "  %-20s %s\n" "Docker socket:" "/var/run/docker.sock"
printf "  %-20s %s\n" "ZFS datasets:" "${DOCKER_DATA_DS}, ${DOCKHAND_DATA_DS}"

section "Deploy complete"
ok "LXC ${LXC_VMID} (${LXC_HOSTNAME}) is live at ${LXC_IP}"
info "Dockhand GUI available at http://${LXC_IP}:80"
info "LazyDocker: lazydocker (inside LXC)"
