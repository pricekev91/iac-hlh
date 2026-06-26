#!/usr/bin/env bash
# Updated configure script for Vulkan support on AMD HX 370 with 890M iGPU

set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────────────────────
LXC_ID=121
MODEL_DIR="/srv/ai/models"
LLAMA_CPP_REPO="https://github.com/ggerganov/llama.cpp.git"
LLAMA_CPP_DIR="/opt/llama.cpp"
SERVICE_NAME="ai-engine"
DEFAULT_MODEL_URL="https://huggingface.co/bartowski/Qwen2.5-Coder-32B-Instruct-GGUF/resolve/main/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
DEFAULT_MODEL_FILE="Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
LLAMA_PORT=80
DEFAULT_BACKEND="vulkan"

# ─── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            echo "Usage:"
            echo "  ./configure-hlh-ai-engine-dev.sh"
            echo ""
            echo "Bootstraps Vulkan and llama.cpp (Vulkan build) inside a running privileged LXC on Proxmox."
            echo ""
            echo "Target LXC : ${LXC_ID}"
            echo "Llama port : ${LLAMA_PORT}"
            echo "Default backend: ${DEFAULT_BACKEND}"
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

echo "Target LXC : ${LXC_ID}"
echo "Llama port : ${LLAMA_PORT}"
echo "Default backend: ${DEFAULT_BACKEND}"
echo ""

# ─── 1. Install base deps and Vulkan ───────────────────────────────────────────
echo "[1/8] Installing base dependencies and Vulkan runtime..."
pct exec "${LXC_ID}" -- bash -c '
set -euo pipefail

apt-get update
apt-get install -y --no-install-recommends \
  build-essential git cmake pkg-config \
  python3 python3-pip curl wget unzip \
  ca-certificates \
  libvulkan-dev spirv-headers vulkan-tools glslc glslang-tools spirv-tools

# Add root to render group for GPU access
usermod -aG render root
usermod -aG video root

# Vulkan environment
tee /etc/profile.d/vulkan.env <<EOF
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/amd_icd64.json:/usr/share/vulkan/icd.d/radeon_icd64.json
EOF

source /etc/profile.d/vulkan.env

# Verify Vulkan tools
echo "Vulkan environment:"
vulkaninfo --summary 2>/dev/null || echo "vulkaninfo not fully available (driver may load later)"
glslc --version 2>/dev/null || echo "glslc not available"
'

# ─── 2. Clone llama.cpp ───────────────────────────────────────────────────────
echo "[2/8] Cloning llama.cpp..."
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
echo "[3/8] Building llama.cpp (Vulkan)..."
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
./build_vulkan/bin/llama-server --version || echo "Vulkan build failed"
'

# ─── 4. Create bin directory with symlink ──────────────────────────────────────
echo "[4/8] Creating bin directory with backend symlink..."
pct exec "${LXC_ID}" -- bash -c '
mkdir -p /opt/llama.cpp/bin
ln -sf /opt/llama.cpp/build_vulkan/bin/llama-server /opt/llama.cpp/bin/vulkan

echo "vulkan   -> $(readlink -f /opt/llama.cpp/bin/vulkan)"
'

# ─── 5. Set up models ─────────────────────────────────────────────────
echo "[5/8] Setting up model directory..."
pct exec "${LXC_ID}" -- bash -c '
set -euo pipefail

MODEL_DIR="/srv/ai/models"
DEFAULT_MODEL_URL="https://huggingface.co/bartowski/Qwen2.5-Coder-32B-Instruct-GGUF/resolve/main/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
DEFAULT_MODEL_FILE="Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"

mkdir -p "$MODEL_DIR"

# Select model - prioritize specific model files
ACTIVE_MODEL_FILE=""
if [ -f "${MODEL_DIR}/${DEFAULT_MODEL_FILE}" ]; then
  ACTIVE_MODEL_FILE="$DEFAULT_MODEL_FILE"
elif [ -f "${MODEL_DIR}/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf" ]; then
  ACTIVE_MODEL_FILE="Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
elif [ -f "${MODEL_DIR}/Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf" ]; then
  ACTIVE_MODEL_FILE="Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf"
elif [ -f "${MODEL_DIR}/Qwen_Qwen3-Coder-Next-Q4_K_M.gguf" ]; then
  ACTIVE_MODEL_FILE="Qwen_Qwen3-Coder-Next-Q4_K_M.gguf"
else
  EXISTING=$(find "$MODEL_DIR" -maxdepth 1 -type f -name "*.gguf" | head -1)
  if [ -n "$EXISTING" ]; then
    ACTIVE_MODEL_FILE="$(basename "$EXISTING")"
    echo "Using existing model: $ACTIVE_MODEL_FILE"
  else
    ACTIVE_MODEL_FILE="$DEFAULT_MODEL_FILE"
    echo "Downloading default model: $ACTIVE_MODEL_FILE"
    wget -O "${MODEL_DIR}/${ACTIVE_MODEL_FILE}" "$DEFAULT_MODEL_URL"
  fi
fi

cat > /etc/ai-engine.env <<EOF
ACTIVE_MODEL=${ACTIVE_MODEL_FILE}
DEFAULT_BACKEND=vulkan
EOF
'

# ─── 6. Create systemd service ────────────────────────────────────────────────
echo "[6/8] Creating systemd service..."
pct exec "${LXC_ID}" -- bash -c '
set -euo pipefail

ACTIVE_MODEL=$(grep -oP "ACTIVE_MODEL=\K.*" /etc/ai-engine.env 2>/dev/null || echo "Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf")
DEFAULT_BACKEND=$(grep -oP "DEFAULT_BACKEND=\K.*" /etc/ai-engine.env 2>/dev/null || echo "vulkan")

# For AMD GPU with 890M, use appropriate ngl parameter and backend
tee /etc/systemd/system/ai-engine.service <<EOF
[Unit]
Description=llama.cpp AI Engine - llama-server
After=network.target

[Service]
Type=simple
WorkingDirectory=/srv/ai/models
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/amd_icd64.json:/usr/share/vulkan/icd.d/radeon_icd64.json
ExecStart=/opt/llama.cpp/bin/${DEFAULT_BACKEND} \
  --model /srv/ai/models/${ACTIVE_MODEL} \
  --host 0.0.0.0 --port 80 \
  --ctx-size 65536 \
  -ngl 48 \
  --batch-size 128 \
  --parallel 1 \
  --cache-type-k q4_0 \
  --cache-type-v q4_0 \
  --backend vulkan
Restart=on-failure
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF
'

# ─── 7. Enable and start ──────────────────────────────────────────────────────
echo "[7/8] Enabling and starting service..."
pct exec "${LXC_ID}" -- systemctl daemon-reload
pct exec "${LXC_ID}" -- systemctl enable --now ai-engine

# ─── 8. Verify ─────────────────────────────────────────────────────────────────
echo "[8/8] Verifying setup..."
echo ""
pct exec "${LXC_ID}" -- bash -c '
echo "[backend symlinks]"
ls -la /opt/llama.cpp/bin/

echo ""
echo "[vulkan binary check]"
/opt/llama.cpp/bin/vulkan --version 2>/dev/null || echo "Vulkan binary not built"

echo ""
echo "[service status]"
systemctl status ai-engine --no-pager 2>/dev/null || echo "Service not active"

echo ""
echo "[switch script]"
ls -la /usr/local/bin/switch-backend.sh 2>/dev/null || echo "Switch script not installed (run deploy script)"
'

echo ""
echo "============================================"
echo "  Dev AI engine deployed (Vulkan only)!"
echo "============================================"
echo ""
echo "  Container  : LXC ${LXC_ID}"
echo "  Model dir  : ${MODEL_DIR} (shared with prod)"
echo "  llama-server: http://192.168.1.21:80"
echo "  Backend bin  : /opt/llama.cpp/bin/vulkan"
echo "  GPU        : gfx1150 (AMD Radeon 890M)"
echo ""
echo "  Compare with prod (ROCm): http://192.168.1.12:80"