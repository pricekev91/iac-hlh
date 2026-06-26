#!/usr/bin/env bash
# configure-hlh-ai-engine-dev.sh
# Bootstraps ROCm + Vulkan deps + two separate llama.cpp builds (HIP + Vulkan)
# + systemd service + interactive backend/model switcher inside a running privileged LXC.
#
# Usage:
#   ./configure-hlh-ai-engine-dev.sh
#
# This script must be run on the Proxmox host (pct command required).
# The target LXC must already exist and be running (deploy first).
#
# Steps:
#   1. Install base dependencies + ROCm 7.2.3 + Vulkan runtime
#   2. Build llama.cpp with HIP (gfx1150) -> build_hip
#   3. Build llama.cpp with Vulkan -> build_vulkan
#   4. Create symlinks: /opt/llama.cpp/bin/hip -> build_hip/bin/llama-server
#   5. Create symlinks: /opt/llama.cpp/bin/vulkan -> build_vulkan/bin/llama-server
#   6. Set up model directory, download default model if empty
#   7. Create systemd service for llama-server
#   8. Deploy switch script
#   9. Enable and start the service
#   10. Verify everything is running

set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────────────────────
LXC_ID=121
MODEL_DIR="/srv/ai/models"
LLAMA_CPP_REPO="https://github.com/ggerganov/llama.cpp.git"
LLAMA_CPP_DIR="/opt/llama.cpp"
SERVICE_NAME="ai-engine"
SWITCH_SCRIPT="/usr/local/bin/switch-backend.sh"
GFX_VERSION="11.5.0"       # gfx1150 native
ROCM_VERSION="7.2.3"
ROCM_PATH="/opt/rocm"
DEFAULT_MODEL_URL="https://huggingface.co/bartowski/Qwen2.5-Coder-32B-Instruct-GGUF/resolve/main/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
DEFAULT_MODEL_FILE="Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
LLAMA_PORT=80              # dev port
DEFAULT_BACKEND="hip"      # hip or vulkan

# ─── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            echo "Usage:"
            echo "  ./configure-hlh-ai-engine.sh"
            echo ""
            echo "Bootstraps ROCm, Vulkan, and two llama.cpp builds (HIP + Vulkan)"
            echo "inside a running privileged LXC on Proxmox. Must be run on the Proxmox host."
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

# ─── 1. Install base deps and ROCm ────────────────────────────────────────────
echo "[1/10] Installing base dependencies and ROCm ${ROCM_VERSION}..."
pct exec "${LXC_ID}" -- bash -c '
set -euo pipefail

ROCM_VERSION="7.2.3"
ROCM_PATH="/opt/rocm"
GFX_VERSION="11.5.0"

apt-get update
apt-get install -y --no-install-recommends \
  build-essential git cmake pkg-config \
  python3 python3-pip curl wget unzip \
  libopenblas-dev libssl-dev ca-certificates gnupg \
  vulkan-utils glslc

# Remove ALL Ubuntu ROCm packages that conflict with AMD repo versions
apt-get remove -y --purge "rocminfo*" "rocm-cmake*" "hipcc*" "rocm-libs*" "rocm*" 2>/dev/null || true
apt-get autoremove -y

# Pin the AMD ROCm repo above Ubuntu default
mkdir -p /etc/apt/preferences.d
tee /etc/apt/preferences.d/rocm <<EOF
Package: *
Pin: origin "repo.radeon.com"
Pin-Priority: 1001
EOF

# ROCm repository
mkdir -p /usr/share/keyrings
wget -qO - https://repo.radeon.com/rocm/rocm.gpg.key | \
  gpg --dearmor -o /usr/share/keyrings/rocm-archive-keyring.gpg

tee /etc/apt/sources.list.d/rocm.list <<EOF
deb [arch=amd64 signed-by=/usr/share/keyrings/rocm-archive-keyring.gpg] https://repo.radeon.com/rocm/apt/${ROCM_VERSION} noble main
deb [arch=amd64 signed-by=/usr/share/keyrings/rocm-archive-keyring.gpg] https://repo.radeon.com/graphics/${ROCM_VERSION}/ubuntu noble main
EOF

apt-get update

apt-get install -y --no-install-recommends \
  rocm-hip-runtime rocm-hip-runtime-dev \
  rocm-smi-lib rocminfo rocm-device-libs \
  hipblas-dev rocblas-dev

# Add root to render/video groups
usermod -aG render root
usermod -aG video root

# ROCm environment
tee /etc/profile.d/rocm.env <<EOF
export PATH=$PATH:/opt/rocm/bin:/opt/rocm/llvm/bin
export LD_LIBRARY_PATH=/opt/rocm/lib:${LD_LIBRARY_PATH:-}
export ROCM_PATH=/opt/rocm
export HIP_PATH=/opt/rocm
export HSA_OVERRIDE_GFX_VERSION=${GFX_VERSION}
EOF

source /etc/profile.d/rocm.env

# Verify HIP tools
HIPCXX_PATH="$(hipconfig -l)/clang"
HIP_PATH_VAL="$(hipconfig -R)"
echo "HIP clang path: ${HIPCXX_PATH}"
echo "HIP root path:  ${HIP_PATH_VAL}"
[ -f "${HIPCXX_PATH}" ] || { echo "ERROR: HIP clang not found at ${HIPCXX_PATH}"; exit 1; }
'

# ─── 2. Clone llama.cpp ───────────────────────────────────────────────────────
echo "[2/10] Cloning llama.cpp..."
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

# ─── 3. Build HIP version ─────────────────────────────────────────────────────
echo "[3/10] Building llama.cpp (HIP/ROCm gfx1150)..."
pct exec "${LXC_ID}" -- bash -c '
set -euo pipefail
source /etc/profile.d/rocm.env

LLAMA_CPP_DIR="/opt/llama.cpp"
cd "$LLAMA_CPP_DIR"
rm -rf build_hip

HIPCXX="${HIPCXX_PATH:-$(hipconfig -l)/clang}" HIP_PATH="${HIP_PATH_VAL:-/opt/rocm}" \
cmake -S . -B build_hip \
  -DGGML_HIP=ON \
  -DGGML_VULKAN=OFF \
  -DAMDGPU_TARGETS=gfx1150 \
  -DCMAKE_BUILD_TYPE=Release

echo "HIP build: Building... (10-25 min on 12 cores)"
cmake --build build_hip --config Release -j$(nproc)

echo ""
echo "HIP build: Verifying..."
./build_hip/bin/llama-server --version || echo "HIP build failed"
'

# ─── 4. Build Vulkan version ──────────────────────────────────────────────────
echo "[4/10] Building llama.cpp (Vulkan)..."
pct exec "${LXC_ID}" -- bash -c '
set -euo pipefail
source /etc/profile.d/rocm.env

cd /opt/llama.cpp
rm -rf build_vulkan

cmake -S . -B build_vulkan \
  -DGGML_HIP=OFF \
  -DGGML_VULKAN=ON \
  -DCMAKE_BUILD_TYPE=Release

echo "Vulkan build: Building... (5-15 min on 12 cores)"
cmake --build build_vulkan --config Release -j$(nproc)

echo ""
echo "Vulkan build: Verifying..."
./build_vulkan/bin/llama-server --version || echo "Vulkan build failed"
'

# ─── 5. Create bin directory with symlinks ─────────────────────────────────────
echo "[5/10] Creating bin directory with backend symlinks..."
pct exec "${LXC_ID}" -- bash -c '
mkdir -p /opt/llama.cpp/bin
ln -sf /opt/llama.cpp/build_hip/bin/llama-server /opt/llama.cpp/bin/hip
ln -sf /opt/llama.cpp/build_vulkan/bin/llama-server /opt/llama.cpp/bin/vulkan

echo "hip      -> $(readlink -f /opt/llama.cpp/bin/hip)"
echo "vulkan   -> $(readlink -f /opt/llama.cpp/bin/vulkan)"
'

# ─── 6. Set up models ─────────────────────────────────────────────────────────
echo "[6/10] Setting up model directory..."
pct exec "${LXC_ID}" -- bash -c '
set -euo pipefail

MODEL_DIR="/srv/ai/models"
DEFAULT_MODEL_URL="https://huggingface.co/bartowski/Qwen2.5-Coder-32B-Instruct-GGUF/resolve/main/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
DEFAULT_MODEL_FILE="Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"

mkdir -p "$MODEL_DIR"

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
DEFAULT_BACKEND=hip
EOF
'

# ─── 7. Create systemd service ────────────────────────────────────────────────
echo "[7/10] Creating systemd service..."
pct exec "${LXC_ID}" -- bash -c '
set -euo pipefail

ACTIVE_MODEL=$(grep -oP "ACTIVE_MODEL=\K.*" /etc/ai-engine.env 2>/dev/null || echo "Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf")
DEFAULT_BACKEND=$(grep -oP "DEFAULT_BACKEND=\K.*" /etc/ai-engine.env 2>/dev/null || echo "hip")

tee /etc/systemd/system/ai-engine.service <<EOF
[Unit]
Description=llama.cpp AI Engine - llama-server
After=network.target

[Service]
Type=simple
WorkingDirectory=/srv/ai/models
Environment=HSA_OVERRIDE_GFX_VERSION=11.5.0
Environment=PATH=/opt/rocm/bin:/opt/rocm/llvm/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=LD_LIBRARY_PATH=/opt/rocm/lib
Environment=ROCM_PATH=/opt/rocm
Environment=HIP_PATH=/opt/rocm
ExecStart=/opt/llama.cpp/bin/${DEFAULT_BACKEND} \
  --model /srv/ai/models/${ACTIVE_MODEL} \
  --host 0.0.0.0 --port 80 \
  --ctx-size 65536 \
  -ngl 48 \
  --batch-size 128 \
  --parallel 1 \
  --cache-type-k q4_0 \
  --cache-type-v q4_0
Restart=on-failure
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF
'

# ─── 8. Deploy switch script ──────────────────────────────────────────────────
echo "[8/10] Deploying switch-backend.sh..."
pct push "${LXC_ID}" switch-backend.sh /usr/local/bin/switch-backend.sh 0
pct exec "${LXC_ID}" -- bash -c "chmod +x /usr/local/bin/switch-backend.sh"
echo "  Switch script installed at: /usr/local/bin/switch-backend.sh"

# ─── 9. Enable and start ──────────────────────────────────────────────────────
echo "[9/10] Enabling and starting service..."
pct exec "${LXC_ID}" -- systemctl daemon-reload
pct exec "${LXC_ID}" -- systemctl enable --now ai-engine

# ─── 10. Verify ────────────────────────────────────────────────────────────────
echo "[10/10] Verifying setup..."
echo ""
pct exec "${LXC_ID}" -- bash -c '
echo "[rocm-smi]"
rocm-smi 2>/dev/null || echo "rocm-smi not available"
echo ""

echo "[backend symlinks]"
ls -la /opt/llama.cpp/bin/

echo ""
echo "[hip binary check]"
/opt/llama.cpp/bin/hip --version 2>/dev/null || echo "HIP binary not built"

echo ""
echo "[vulkan binary check]"
/opt/llama.cpp/bin/vulkan --version 2>/dev/null || echo "Vulkan binary not built"

echo ""
echo "[service status]"
systemctl status ai-engine --no-pager 2>/dev/null || echo "Service not active"

echo ""
echo "[switch script]"
ls -la /usr/local/bin/switch-backend.sh
'

echo ""
echo "============================================"
echo "  Dev AI engine deployed and configured!"
echo "============================================"
echo ""
echo "  Container  : LXC ${LXC_ID}"
echo "  Model dir  : ${MODEL_DIR} (shared with prod)"
echo "  llama-server: http://192.168.1.21:80"
echo "  Switch backend: switch-backend.sh (run inside container)"
echo "  Backend bin  : /opt/llama.cpp/bin/hip"
echo "  Backend bin  : /opt/llama.cpp/bin/vulkan"
echo "  GPU        : gfx1150 (AMD Radeon 890M)"
echo "  ROCm       : ${ROCM_VERSION}"
echo ""
echo "  Compare with prod: http://192.168.1.12:80"
