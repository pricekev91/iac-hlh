#!/usr/bin/env bash
# Script to delete old LXC 101 and recreate with 250GB rootfs
# Run this on Proxmox host: ssh root@192.168.6.10 && bash < RESIZE_ENGINE.sh

set -euo pipefail

echo "[resize] Stopping LXC 101..."
pct stop 101 || true

echo "[resize] Deleting LXC 101 with purge..."
pct destroy 101 --purge 1

echo "[resize] Verifying ZFS pool space..."
zfs list -h | grep -E "raidz|local" | head -20

echo "[resize] LXC 101 deleted. Ready to run apply.bash"
echo ""
echo "Next: cd /root/iac-hlh && ./apply.bash inventory/hlh-prod.yaml"
