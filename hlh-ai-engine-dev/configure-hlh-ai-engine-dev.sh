#!/usr/bin/env bash
# configure-hlh-ai-engine-dev.sh
# Version: 2.0.0
# Description: Bootstrap llama.cpp AI engine on Ubuntu 24.04 LXC with Vulkan backend
# Target: CT 121 — Vulkan benchmark of same model as CT 101 (PROD/ROCm)
# Key difference from CT 101: Vulkan (RADV) instead of ROCm
# All other params match CT 101 exactly for fair comparison
#
# Changelog:
#   2.0.0 - Match CT 101 config: 96K ctx, MTP (draft-mtp, n-max=2),
#           batch 512, flash-attn, port 80, Qwen3.6-35B-A3B-MTP-Q4_K_M
#           Fixed: VK_ICD_FILENAMES (radeon_icd.json, not radeon_icd64.json)
#           Removed invalid --backend vulkan flag
#   1.1.0 - Fixed Vulkan ICD filenames (amd_icd64.json -> amd_icd.json)
#   1.0.0 - Initial Vulkan config for CT 121

set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────────────────────
LXC_ID=121
MODEL_DIR="/srv/ai/models"
LLAMA_CPP_REPO="https://github.com/ggerganov/llama.cpp.git"
LLAMA_CPP_DIR="/opt/llama.cpp"
SERVICE_NAME="ai-engine"
DEFAULT_MODEL_FILE="Qwen3.6-35B-A3B-MTP-Q4_K_M.gguf"
DEFAULT_MODEL_URL="https://huggingface.co/bartowski/Qwen3.6-35B-A3B-MTP-GGUF/resolve/main/Qwen3.6-35B-A3B-MTP-Q4_K_M.gguf"
LLAMA_PORT=80

# ─── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            echo "Usage: ./configure-hlh-ai-engine-dev.sh"
            echo ""
            echo "Bootstraps Vulkan and llama.cpp inside CT 121 on Proxmox."
            echo "Configured to match CT 101 (PROD/ROCm) for benchmark parity."
            echo ""
            echo "Target LXC  : ${LXC_ID}"
            echo "Llama port  : ${LLAMA_PORT}"
            echo "Model       : ${DEFAULT_MODEL_FILE}"
            echo "Backend     : Vulkan (RADV)"
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            exit 1
            ;;
    esac
    shift
done

# ─── Pre-flight ────────────────────────────────────────────────────────────────
command -v pct >/dev/null 2>&1 || { echo "ERROR: pct command not found. Run on Proxmox host." >&2; exit 1; }

pct status "${LXC_ID}" >/dev/null 2>&1 || {
    echo "ERROR: LXC ${LXC_ID} is not running. Deploy it first." >&2
    exit 1
}

echo "Target LXC  : ${LXC_ID}"
echo "Llama port  : ${LLAMA_PORT}"
echo "Model       : ${DEFAULT_MODEL_FILE}"
echo "Backend     : Vulkan (RADV)"
echo ""

# ─── 1. Install deps and Vulkan runtime ────────────────────────────────────────
echo "[1/7] Installing base dependencies and Vulkan runtime..."
pct exec "${LXC_ID}" -- bash -c '
set -euo pipefail

apt-get update
apt-get install -y --no-install-recommends \
  build-essential git cmake pkg-config \
  python3 python3-pip curl wget unzip \
  ca-certificates \
  libvulkan-dev vulkan-tools \
  mesa-vulkan-drivers

# Add root to render and video groups for GPU access
usermod -aG render root
usermod -aG video root

# Vulkan environment — radeon_icd.json is the actual Mesa file (not radeon_icd64.json)
tee /etc/profile.d/vulkan.env <<EOF
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.json
EOF

source /etc/profile.d/vulkan.env

echo "Vulkan ICD files:"
ls -la /usr/share/vulkan/icd.d/
echo ""
vulkaninfo --summary 2>/dev/null || echo "vulkaninfo: driver not ready yet"
'

# ─── 2. Clone llama.cpp ───────────────────────────────────────────────────────
echo "[2/7] Cloning llama.cpp..."
pct exec "${LXC_ID}" -- bash -c '
set -euo pipefail
LLAMA_CPP_REPO="https://github.com/ggerganov/llama.cpp.git"
LLAMA_CPP_DIR="/opt/llama.cpp"

if [ ! -d "$LLAMA_CPP_DIR" ]; then
  git clone --depth=1 "$LLAMA_CPP_REPO" "$LLAMA_CPP_DIR"
else
  git -C "$LLAMA_CPP_DIR" pull
fi
'

# ─── 3. Build Vulkan version ──────────────────────────────────────────────────
echo "[3/7] Building llama.cpp (Vulkan)..."
pct exec "${LXC_ID}" -- bash -c '
set -euo pipefail

source /etc/profile.d/vulkan.env

cd /opt/llama.cpp
rm -rf build_vulkan

cmake -S . -B build_vulkan \
  -DGGML_HIP=OFF \
  -DGGML_VULKAN=ON \
  -DGGML_VULKAN_HOST=ON \
  -DCMAKE_BUILD_TYPE=Release

echo "Vulkan build: Building... (5-15 min on 12 cores)"
cmake --build build_vulkan --config Release -j$(nproc)

echo ""
echo "Vulkan build: Verifying..."
./build_vulkan/bin/llama-server --version 2>&1 || echo "Vulkan build failed"
'

# ─── 4. Create bin directory with symlink ──────────────────────────────────────
echo "[4/7] Creating bin directory with backend symlink..."
pct exec "${LXC_ID}" -- bash -c '
mkdir -p /opt/llama.cpp/bin
ln -sf /opt/llama.cpp/build_vulkan/bin/llama-server /opt/llama.cpp/bin/vulkan
echo "vulkan   -> $(readlink -f /opt/llama.cpp/bin/vulkan)"
'

# ─── 5. Verify model exists ──────────────────────────────────────────────────
echo "[5/7] Checking model ${DEFAULT_MODEL_FILE}..."
pct exec "${LXC_ID}" -- bash -c "
if [ -f '${MODEL_DIR}/${DEFAULT_MODEL_FILE}' ]; then
  echo '  [✓] Model present:'
  ls -lh '${MODEL_DIR}/${DEFAULT_MODEL_FILE}'
else
  echo '  [!] Model not found — downloading...'
  mkdir -p ${MODEL_DIR}
  cd ${MODEL_DIR}
  wget --progress=bar:force:noscroll \
       -O ${DEFAULT_MODEL_FILE} \
       ${DEFAULT_MODEL_URL}
  echo '  [✓] Download complete.'
fi
"

# ─── 6. Create systemd service (matches CT 101 config) ────────────────────────
echo "[6/7] Creating systemd service (matches CT 101 PROD config)..."
pct exec "${LXC_ID}" -- bash -c '
cat > /etc/systemd/system/ai-engine.service <<EOF
[Unit]
Description=llama.cpp AI Engine (llama-server) - Vulkan on port 80
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/llama.cpp/build_vulkan
Environment=VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.json
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu
ExecStart=/opt/llama.cpp/build_vulkan/bin/llama-server \\
  --model /srv/ai/models/Qwen3.6-35B-A3B-MTP-Q4_K_M.gguf \\
  --host 0.0.0.0 --port 80 \\
  --ctx-size 98304 \\
  -ngl 48 \\
  --batch-size 512 \\
  --flash-attn on \\
  --parallel 1 \\
  --cache-type-k q4_0 \\
  --cache-type-v q4_0 \\
  --spec-type draft-mtp \\
  --spec-draft-n-max 2
Restart=on-failure
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF

echo "Service file created:"
cat /etc/systemd/system/ai-engine.service
'

# ─── 7. Enable and start ──────────────────────────────────────────────────────
echo "[7/7] Enabling and starting service..."
pct exec "${LXC_ID}" -- systemctl daemon-reload
pct exec "${LXC_ID}" -- systemctl enable --now ai-engine
sleep 5
pct exec "${LXC_ID}" -- systemctl status ai-engine --no-pager

echo ""
echo "============================================"
echo "  Dev AI engine deployed (Vulkan)!"
echo "============================================"
echo ""
echo "  Container  : CT ${LXC_ID} (LXC ${LXC_ID})"
echo "  Model      : ${DEFAULT_MODEL_FILE}"
echo "  Backend    : Vulkan (RADV, Mesa)"
echo "  ctx-size   : 98304 (96K) — matches CT 101"
echo "  KV cache   : q4_0 K/V"
echo "  MTP        : draft-mtp, n-max=2"
echo "  Port       : ${LLAMA_PORT}"
echo ""
echo "  Dev (Vulkan) : http://192.168.1.12:80"
echo "  Prod (ROCm)  : http://192.168.1.21:80"
echo ""
echo "  Watch logs: pct exec ${LXC_ID} -- journalctl -u ai-engine -f"
