#!/bin/bash
# Complete AI Engine 250GB Resize Script
# Paste this directly into your Proxmox SSH session: ssh root@192.168.6.10 && bash

set -euo pipefail

echo "=========================================="
echo "iac-hlh AI Engine Resize to 250GB"
echo "=========================================="
echo ""

echo "STEP 1: Current LXC status"
pct list || echo "No containers"
echo ""

echo "STEP 2: Stopping LXC 101 (if exists)..."
pct stop 101 2>/dev/null || echo "LXC 101 not running"
sleep 2
echo ""

echo "STEP 3: Deleting LXC 101 (if exists)..."
pct destroy 101 --purge 1 2>/dev/null || echo "LXC 101 already deleted"
sleep 2
echo ""

echo "STEP 4: Verifying ZFS pool space..."
echo "Available space on raidZ1:"
zfs list -h | grep raidz || echo "No raidz pool found"
echo ""

echo "STEP 5: Ensuring git repo is updated..."
if [ ! -d /root/iac-hlh ]; then
    echo "Cloning iac-hlh..."
    cd /root && git clone https://github.com/pricekev/iac-hlh.git 2>/dev/null || echo "Clone failed - using existing"
else
    echo "iac-hlh directory exists, pulling latest..."
    cd /root/iac-hlh && git pull 2>/dev/null || echo "Git pull failed - using local"
fi
echo ""

echo "STEP 6: Checking inventory file..."
cat /root/iac-hlh/inventory/hlh-prod.yaml | head -30
echo ""

echo "STEP 7: Running apply.bash to create LXC 101..."
cd /root/iac-hlh
./apply.bash inventory/hlh-prod.yaml
echo ""

echo "STEP 8: Verifying LXC 101 creation..."
sleep 3
if pct status 101 >/dev/null 2>&1; then
    echo "✅ SUCCESS: LXC 101 created!"
    echo ""
    echo "Configuration:"
    pct config 101 | grep -E "^(hostname|rootfs|cores|memory|swap|net0)"
    echo ""
    echo "Status:"
    pct status 101
else
    echo "❌ ERROR: LXC 101 not found after creation"
    exit 1
fi

echo ""
echo "=========================================="
echo "✅ COMPLETE: AI Engine 250GB creation done"
echo "=========================================="
echo ""
echo "Next steps:"
echo "1. Verify container is running: pct status 101"
echo "2. Check IP assignment: pct exec 101 -- ip addr"
echo "3. Monitor provisioning: pct logs 101"
