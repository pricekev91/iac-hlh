#!/usr/bin/env bash
# configure-ai-engine-inside-lxc.sh
# Version: 0.6.2
# Description: Bootstrap llama.cpp AI engine on Ubuntu 24.04 LXC with ROCm passthrough
# Target GPU: AMD Radeon 890M (gfx1150) on Proxmox 9.x privileged LXC
# Requirements: Run as root inside privileged LXC with GPU passthrough and /srv/ai/models bind mount
# Changelog:
#   0.1.0 - Initial version
#   0.2.0 - Fixed ROCm repo setup and package names
#   0.3.0 - Added CMake ROCm path flags
#   0.4.0 - Added rocm-hip-runtime-dev, Vulkan support, hipcc verification
#   0.5.0 - Fixed HIP compiler: use HIPCXX env var pointing to clang, not hipcc wrapper
#   0.6.0 - Added glslc, pre-build checks, fixed LD_LIBRARY_PATH unbound variable
#   0.6.2 - Disabled Vulkan (missing SPIRV-Headers blocks build); ROCm only for now

set -euo pipefail

# --- CONFIGURABLE ---
MODEL_DIR="/srv/ai/models"
DEFAULT_MODEL_URL="https://huggingface.co/bartowski/Qwen_Qwen3.6-35B-A3B-GGUF/resolve/main/Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf"
DEFAULT_MODEL_FILE="Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf"
LLAMA_CPP_REPO="https://github.com/ggerganov/llama.cpp.git"
LLAMA_CPP_DIR="/opt/llama.cpp"
SERVICE_NAME="ai-engine"
SYSTEMD_SERVICE="/etc/systemd/system/${SERVICE_NAME}.service"
SWITCH_SCRIPT="/usr/local/bin/switch-model.sh"
GFX_VERSION="11.5.0"   # gfx1150 = HSA version 11.5.0
ROCM_PATH="/opt/rocm"

# --- 1. BASE DEPENDENCIES ---
echo "[1/7] Installing base dependencies..."
apt-get update
apt-get install -y --no-install-recommends \
  build-essential git cmake pkg-config \
  python3 python3-pip curl wget unzip \
  libopenblas-dev libssl-dev ca-certificates gnupg

# --- 1b. ADD ROCM REPO ---
echo "[1/7] Adding ROCm repository..."
wget -qO - https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor > /usr/share/keyrings/rocm-archive-keyring.gpg
echo "deb [arch=amd64 trusted=yes] https://repo.radeon.com/rocm/apt/6.4 noble main" > /etc/apt/sources.list.d/rocm.list
echo 'APT::Key::GPGCommand "/usr/bin/gpg";' > /etc/apt/apt.conf.d/99gpg-override

# Pin AMD repo over Ubuntu's bundled ROCm packages
cat > /etc/apt/preferences.d/rocm-pin <<'PIN'
Package: *
Pin: origin repo.radeon.com
Pin-Priority: 1001
PIN

# Remove Ubuntu's conflicting rocminfo
apt-get remove -y rocminfo 2>/dev/null || true

apt-get update
apt-get install -y --no-install-recommends \
  rocm-hip-runtime \
  rocm-hip-runtime-dev \
  rocm-smi-lib \
  rocminfo \
  rocm-device-libs \
  hipblas-dev \
  rocblas-dev

# --- ROCm Environment Setup ---
echo "[1/7] Setting up ROCm environment..."
cat > /etc/profile.d/rocm.env <<EOF
export PATH=\$PATH:${ROCM_PATH}/bin:${ROCM_PATH}/llvm/bin
export LD_LIBRARY_PATH=${ROCM_PATH}/lib:\${LD_LIBRARY_PATH:-}
export ROCM_PATH=${ROCM_PATH}
export HIP_PATH=${ROCM_PATH}
EOF

set +u
source /etc/profile.d/rocm.env
set -u

# --- Pre-Build Checks ---
echo "[1/7] Verifying HIP tools..."
HIPCXX_PATH="$(hipconfig -l)/clang"
HIP_PATH_VAL="$(hipconfig -R)"
echo "HIP clang path: ${HIPCXX_PATH}"
echo "HIP root path:  ${HIP_PATH_VAL}"
[ -f "${HIPCXX_PATH}" ] || { echo "ERROR: HIP clang not found at ${HIPCXX_PATH}"; exit 1; }

# --- 2. BUILD LLAMA.CPP (ROCm only) ---
echo "[2/7] Cloning and building llama.cpp (ROCm only)..."
if [ ! -d "$LLAMA_CPP_DIR" ]; then
  git clone --depth=1 "$LLAMA_CPP_REPO" "$LLAMA_CPP_DIR"
else
  git -C "$LLAMA_CPP_DIR" pull
fi

cd "$LLAMA_CPP_DIR"

HIPCXX="${HIPCXX_PATH}" HIP_PATH="${HIP_PATH_VAL}" \
cmake -S . -B build \
  -DGGML_HIP=ON \
  -DGGML_VULKAN=OFF \
  -DAMDGPU_TARGETS=gfx1150 \
  -DCMAKE_BUILD_TYPE=Release

echo "[2/7] Building... (this can take 10-25 minutes with 12 cores)"
cmake --build build --config Release -j$(nproc)

# --- 3. MODEL STORAGE & DOWNLOAD ---
echo "[3/7] Setting up model directory..."
mkdir -p "$MODEL_DIR"
cd "$MODEL_DIR"
if [ ! -f "$DEFAULT_MODEL_FILE" ]; then
  echo "Downloading default model: $DEFAULT_MODEL_FILE"
  wget -O "$DEFAULT_MODEL_FILE" "$DEFAULT_MODEL_URL"
else
  echo "Default model already present: $DEFAULT_MODEL_FILE"
fi

# --- 4. SYSTEMD SERVICE ---
echo "[4/7] Creating systemd service for llama-server..."
cat > "$SYSTEMD_SERVICE" <<UNIT
[Unit]
Description=llama.cpp AI Engine (llama-server) - native web UI on port 8080
After=network.target

[Service]
Type=simple
WorkingDirectory=${LLAMA_CPP_DIR}/build/bin
Environment=HSA_OVERRIDE_GFX_VERSION=${GFX_VERSION}
Environment=PATH=${ROCM_PATH}/bin:${ROCM_PATH}/llvm/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=LD_LIBRARY_PATH=${ROCM_PATH}/lib
Environment=ROCM_PATH=${ROCM_PATH}
Environment=HIP_PATH=${ROCM_PATH}
ExecStart=${LLAMA_CPP_DIR}/build/bin/llama-server \
  --model ${MODEL_DIR}/${DEFAULT_MODEL_FILE} \
  --host 0.0.0.0 --port 8080 \
  --ctx-size 32768 --ngl 99 --flash-attn \
  --batch-size 64
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
UNIT

# --- 5. MODEL SWITCH SCRIPT ---
echo "[5/7] Creating interactive model switcher: $SWITCH_SCRIPT..."
cat > "$SWITCH_SCRIPT" <<'EOS'
#!/usr/bin/env bash
MODEL_DIR="/srv/ai/models"
SERVICE="ai-engine"
SYSTEMD_SERVICE="/etc/systemd/system/${SERVICE}.service"

set -euo pipefail

echo ""
echo "Available GGUF models in $MODEL_DIR:"
mapfile -t MODELS < <(find "$MODEL_DIR" -maxdepth 1 -type f -name '*.gguf' | sort)
if [ "${#MODELS[@]}" -eq 0 ]; then
  echo "No .gguf models found in $MODEL_DIR."
  exit 1
fi

CUR_MODEL=$(grep -- '--model ' "$SYSTEMD_SERVICE" | awk '{for(i=1;i<=NF;i++) if ($i=="--model") print $(i+1)}')
echo "Current model: $CUR_MODEL"

for i in "${!MODELS[@]}"; do
  printf "%2d) %s\n" $((i+1)) "${MODELS[$i]}"
done
read -rp "Select model number to activate: " CHOICE
if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > ${#MODELS[@]} )); then
  echo "Invalid selection."
  exit 1
fi
NEW_MODEL="${MODELS[$((CHOICE-1))]}"
if [ "$NEW_MODEL" = "$CUR_MODEL" ]; then
  echo "Model already active."
  exit 0
fi
read -rp "Switch to $NEW_MODEL and restart $SERVICE? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi
sed -i "s|--model [^ ]*|--model $NEW_MODEL|" "$SYSTEMD_SERVICE"
systemctl daemon-reload
systemctl restart "$SERVICE"
echo "Switched to $NEW_MODEL and restarted $SERVICE."
EOS
chmod +x "$SWITCH_SCRIPT"

# --- 6. ENABLE & START SERVICE ---
echo "[6/7] Enabling and starting $SERVICE_NAME..."
systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"

# --- 7. VERIFICATION ---
echo "[7/7] Verifying setup..."
echo ""
echo "[rocm-smi output]"
rocm-smi || echo "rocm-smi not found or failed"
echo ""
echo "[llama-server version]"
${LLAMA_CPP_DIR}/build/bin/llama-server --version || true
echo ""
echo "[Service status]"
systemctl status "$SERVICE_NAME" --no-pager
echo ""
echo "[Bootstrap complete - v0.6.2]"
echo "  Native llama.cpp web UI : http://<container-ip>:8080"
echo "  Switch models with      : switch-model.sh"
echo "  Force ROCm              : add '--device ROCm0' to ExecStart in ${SYSTEMD_SERVICE}"
echo "  NOTE: Vulkan disabled in this build - enable in v0.7 once ROCm is verified"
