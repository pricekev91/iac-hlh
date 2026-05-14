#!/bin/bash
# Complete diagnosis and fix script for iac-hlh AI Engine resize
# Run on Proxmox host: bash /tmp/diagnose_engine.sh

set -e

echo "=========================================="
echo "DIAGNOSTIC REPORT - iac-hlh AI Engine"
echo "=========================================="
echo ""

echo "1. CURRENT LXC CONTAINERS:"
pct list
echo ""

echo "2. ZFS POOL STATUS:"
zfs list -h | grep -E "raidz|local"
echo ""

echo "3. CHECKING LXC 101 SPECIFICALLY:"
if pct status 101 2>/dev/null; then
    echo "✅ LXC 101 exists"
    pct config 101 | grep -E "^(hostname|rootfs|cores|memory)"
else
    echo "❌ LXC 101 does not exist"
fi
echo ""

echo "4. RUNNING APPLY SCRIPT WITH DEBUG:"
cd /root/iac-hlh
echo "Starting ./apply.bash inventory/hlh-prod.yaml"
echo ""
bash -x ./apply.bash inventory/hlh-prod.yaml 2>&1 | head -150
echo ""
echo "=========================================="
echo "END DIAGNOSTIC REPORT"
echo "=========================================="
