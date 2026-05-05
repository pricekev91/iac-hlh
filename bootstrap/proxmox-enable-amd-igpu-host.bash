#!/usr/bin/env bash

set -euo pipefail

log() {
  echo "[proxmox-enable-amd-igpu-host] $*"
}

fail() {
  echo "[proxmox-enable-amd-igpu-host] ERROR: $*" >&2
  exit 1
}

backup_and_remove() {
  local path="$1"

  if [[ -f "$path" ]]; then
    cp "$path" "${path}.iac-hlh.bak"
    rm -f "$path"
    log "Removed $path and saved backup to ${path}.iac-hlh.bak"
  fi
}

main() {
  [[ ${EUID} -eq 0 ]] || fail "Run this script as root on the Proxmox host"

  if ! lspci -nnk | grep -q '1002:150e'; then
    fail "AMD Strix iGPU (1002:150e) not detected on this host"
  fi

  backup_and_remove /etc/modprobe.d/blacklist-amdgpu.conf
  backup_and_remove /etc/modules-load.d/vfio-pci.conf

  cat >/etc/modules-load.d/amdgpu.conf <<'EOF'
amdgpu
EOF

  cat >/etc/modprobe.d/iac-hlh-amdgpu.conf <<'EOF'
# Managed by iac-hlh to keep the HLH iGPU bound to amdgpu for LXC passthrough.
blacklist radeon
EOF

  update-initramfs -u -k all

  if command -v proxmox-boot-tool >/dev/null 2>&1; then
    proxmox-boot-tool refresh
  fi

  log "Host config updated. Reboot is required before /dev/dri will be available to LXCs."
}

main "$@"