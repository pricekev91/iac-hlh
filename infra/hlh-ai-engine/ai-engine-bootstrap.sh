#!/usr/bin/env bash
# ai-engine-bootstrap.sh
# Bootstrap script for high-performance llama.cpp AI engine on Proxmox 9.x LXC (Ubuntu 24.04)
# Requirements: Run as root inside privileged LXC with GPU passthrough and /srv/ai/models bind mount

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

# --- 1. DEPENDENCIES ---
echo "[1/7] Installing dependencies..."
apt-get update
apt-get install -y --no-install-recommends \
  build-essential git cmake pkg-config \
  python3 python3-pip curl wget unzip \
  libopenblas-dev libssl-dev \
  rocm-hip-libraries-dev rocm-hip-runtime hipblas hiprand \
  vulkan-tools vulkan-validationlayers-dev libvulkan-dev

# --- 2. BUILD LATEST LLAMA.CPP ---
echo "[2/7] Cloning and building llama.cpp (main branch, HIP/ROCm + Vulkan)..."
if [ ! -d "$LLAMA_CPP_DIR" ]; then
  git clone --depth=1 "$LLAMA_CPP_REPO" "$LLAMA_CPP_DIR"
else
  git -C "$LLAMA_CPP_DIR" pull
fi
cd "$LLAMA_CPP_DIR"
# Clean previous builds
make clean || true
# Build with HIP/ROCm and Vulkan
HSA_OVERRIDE_GFX_VERSION=11.0.0 make LLAMA_HIP=1 LLAMA_VULKAN=1 -j$(nproc)

# --- 3. MODEL STORAGE & DOWNLOAD ---
echo "[3/7] Ensuring model directory and downloading default model if needed..."
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
cat > "$SYSTEMD_SERVICE" <<EOF
[Unit]
Description=llama.cpp AI Engine (llama-server)
After=network.target

[Service]
Type=simple
WorkingDirectory=$LLAMA_CPP_DIR
Environment=HSA_OVERRIDE_GFX_VERSION=11.0.0
# To test: HSA_OVERRIDE_GFX_VERSION=11.0.2
ExecStart=$LLAMA_CPP_DIR/server \
  --model $MODEL_DIR/[1m$DEFAULT_MODEL_FILE[0m \
  --host 0.0.0.0 --port 8080 \
  --ctx-size 32768 --ngl 99 --flash-attn \
  --batch-size 64
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
EOF

# --- 5. MODEL SWITCH SCRIPT ---
echo "[5/7] Creating interactive model switcher: $SWITCH_SCRIPT..."
cat > "$SWITCH_SCRIPT" <<'EOS'
#!/usr/bin/env bash
MODEL_DIR="/srv/ai/models"
SERVICE="ai-engine"
SYSTEMD_SERVICE="/etc/systemd/system/${SERVICE}.service"

set -euo pipefail

# List models
echo "\nAvailable GGUF models in $MODEL_DIR:"
mapfile -t MODELS < <(find "$MODEL_DIR" -maxdepth 1 -type f -name '*.gguf' | sort)
if [ "${#MODELS[@]}" -eq 0 ]; then
  echo "No .gguf models found in $MODEL_DIR."
  exit 1
fi

# Find current model in systemd service
CUR_MODEL=$(grep -- '--model ' "$SYSTEMD_SERVICE" | awk '{for(i=1;i<=NF;i++) if ($i=="--model") print $(i+1)}')
echo "Current model: $CUR_MODEL"

# Display menu
for i in "${!MODELS[@]}"; do
  printf "%2d) %s\n" $((i+1)) "${MODELS[$i]}"
done
read -rp "\nSelect model number to activate: " CHOICE
if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > ${#MODELS[@]} )); then
  echo "Invalid selection."
  exit 1
fi
NEW_MODEL="${MODELS[$((CHOICE-1))]}"
if [ "$NEW_MODEL" = "$CUR_MODEL" ]; then
  echo "Model already active."
  exit 0
fi
# Confirm
read -rp "Switch to $NEW_MODEL and restart $SERVICE? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi
# Update systemd service
sudo sed -i "s|--model [^ ]*|--model $NEW_MODEL|" "$SYSTEMD_SERVICE"
sudo systemctl daemon-reload
sudo systemctl restart "$SERVICE"
echo "Switched to $NEW_MODEL and restarted $SERVICE."
EOS
chmod +x "$SWITCH_SCRIPT"

# --- 6. ENABLE & START SERVICE ---
echo "[6/7] Enabling and starting $SERVICE_NAME..."
systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"

# --- 7. VERIFICATION ---
echo "[7/7] Verifying setup..."
echo "\n[rocm-smi output]"
rocm-smi || echo "rocm-smi not found or failed"
echo "\n[llama-server --help]"
cd "$LLAMA_CPP_DIR"
./server --help | head -20

echo "\n[Service status]"
systemctl status "$SERVICE_NAME" --no-pager

echo "\n[Bootstrap complete. Access llama-server at http://<container-ip>:8080]"
