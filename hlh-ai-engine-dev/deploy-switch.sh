#!/usr/bin/env bash
# deploy-switch.sh — Push switch-backend.sh into the running LXC
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LXC_ID=121

echo "  Pushing switch-backend.sh to LXC ${LXC_ID}..."
pct push "${LXC_ID}" "${SCRIPT_DIR}/switch-backend.sh" /usr/local/bin/switch-backend.sh 0
pct exec "${LXC_ID}" -- bash -c "chmod +x /usr/local/bin/switch-backend.sh"
echo "  Done."
