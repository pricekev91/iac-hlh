#!/usr/bin/env bash
# configure-hlh-ai-engine.sh
# Bootstraps ROCm + llama.cpp + systemd service inside a running privileged LXC.
#
# Usage:
#   ./configure-hlh-ai-engine.sh
#
# This script must be run on the Proxmox host (pct command required).
# The target LXC must already exist and be running (deploy first).
#
# Steps (all executed via pct exec inside the container):
#   1. Install base dependencies + ROCm 7.2.3
#   2. Build llama.cpp with ROCm (gfx1150)
#   3. Set up model directory, download default model if empty
#   4. Create systemd service for llama-server
#   5. Create interactive model switcher script
#   6. Enable and start the service
#   7. Verify everything is running

set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────────────────────
LXC_ID=121
MODEL_DIR="/srv/ai/models"
LLAMA_CPP_REPO="https://github.com/ggerganov/llama.cpp.git"
LLAMA_CPP_DIR="/opt/llama.cpp"
SERVICE_NAME="ai-engine"
SWITCH_SCRIPT="/usr/local/bin/switch-model.sh"
GFX_VERSION="11.5.0"       # gfx1150 native
ROCM_VERSION="7.2.3"
ROCM_PATH="/opt/rocm"
DEFAULT_MODEL_URL="https://huggingface.co/bartowski/Qwen2.5-Coder-32B-Instruct-GGUF/resolve/main/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
DEFAULT_MODEL_FILE="Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
LLAMA_PORT=8081            # dev port — prod uses 80

# ─── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            echo "Usage:"
            echo "  ./configure-hlh-ai-engine.sh"
            echo ""
            echo "Bootstraps ROCm, llama.cpp, and the inference service inside a running"
            echo "privileged LXC on Proxmox. Must be run on the Proxmox host."
            echo ""
            echo "Target LXC : ${LXC_ID}"
            echo "Llama port : ${LLAMA_PORT}"
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
echo ""

# ─── Bootstrap ─────────────────────────────────────────────────────────────────
echo "[1/7] Installing base dependencies and ROCm ${ROCM_VERSION}..."
pct exec "${LXC_ID}" -- bash <<'BOOTSTRAP'
set -euo pipefail

ROCM_VERSION="7.2.3"
ROCM_PATH="/opt/rocm"
GFX_VERSION="11.5.0"

# Base dependencies
echo "[1/7] Installing base dependencies..."
apt-get update
apt-get install -y --no-install-recommends \
  build-essential git cmake pkg-config \
  python3 python3-pip curl wget unzip \
  libopenblas-dev libssl-dev ca-certificates gnupg

# ROCm repository
echo "[1/7] Adding ROCm ${ROCM_VERSION} repository..."
mkdir -p /etc/apt/keyrings
wget -qO - https://repo.radeon.com/rocm/rocm.gpg.key | \
  gpg --dearmor | tee /etc/apt/keyrings/rocm.gpg > /dev/null

tee /etc/apt/sources.list.d/rocm.list <<'ROCMEOF'
deb [arch=amd64 trusted=yes] https://repo.radeon.com/rocm/apt/7.2.3 noble main
deb [arch=amd64 trusted=yes] https://repo.radeon.com/graphics/7.2.3/ubuntu noble main
ROCMEOF

echo 'APT::Key::GPGCommand "/usr/bin/gpg";' > /etc/apt/apt.conf.d/99gpg-override

apt-get remove -y rocminfo 2>/dev/null || true
apt-get update

apt-get install -y --no-install-recommends \
  rocm-hip-runtime rocm-hip-runtime-dev \
  rocm-smi-lib rocminfo rocm-device-libs \
  hipblas-dev rocblas-dev

# Add root to render/video groups
usermod -aG render root
usermod -aG video root

# ROCm environment
tee /etc/profile.d/rocm.env <<'ROCMEOF'
export PATH=$PATH:/opt/rocm/bin:/opt/rocm/llvm/bin
export LD_LIBRARY_PATH=/opt/rocm/lib:${LD_LIBRARY_PATH:-}
export ROCM_PATH=/opt/rocm
export HIP_PATH=/opt/rocm
ROCMEOF

source /etc/profile.d/rocm.env

# Verify HIP tools
HIPCXX_PATH="$(hipconfig -l)/clang"
HIP_PATH_VAL="$(hipconfig -R)"
echo "HIP clang path: ${HIPCXX_PATH}"
echo "HIP root path:  ${HIP_PATH_VAL}"
[ -f "${HIPCXX_PATH}" ] || { echo "ERROR: HIP clang not found at ${HIPCXX_PATH}"; exit 1; }
BOOTSTRAP

echo "[2/7] Building llama.cpp (ROCm gfx1150)..."
pct exec "${LXC_ID}" -- bash <<'BOOTSTRAP'
set -euo pipefail
source /etc/profile.d/rocm.env

LLAMA_CPP_REPO="https://github.com/ggerganov/llama.cpp.git"
LLAMA_CPP_DIR="/opt/llama.cpp"

if [ ! -d "$LLAMA_CPP_DIR" ]; then
  git clone --depth=1 "$LLAMA_CPP_REPO" "$LLAMA_CPP_DIR"
else
  git -C "$LLAMA_CPP_DIR" pull
fi

cd "$LLAMA_CPP_DIR"

HIPCXX="${HIPCXX_PATH:-$(hipconfig -l)/clang}" HIP_PATH="${HIP_PATH_VAL:-/opt/rocm}" \
cmake -S . -B build \
  -DGGML_HIP=ON \
  -DGGML_VULKAN=OFF \
  -DAMDGPU_TARGETS=gfx1150 \
  -DCMAKE_BUILD_TYPE=Release

echo "Building... (this can take 10-25 minutes with 12 cores)"
cmake --build build --config Release -j$(nproc)
BOOTSTRAP

echo "[3/7] Setting up model directory and downloading default model..."
pct exec "${LXC_ID}" -- bash <<'BOOTSTRAP'
set -euo pipefail

MODEL_DIR="/srv/ai/models"
DEFAULT_MODEL_URL="https://huggingface.co/bartowski/Qwen2.5-Coder-32B-Instruct-GGUF/resolve/main/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
DEFAULT_MODEL_FILE="Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
ACTIVE_MODEL_FILE=""

mkdir -p "$MODEL_DIR"

if [ -f "${MODEL_DIR}/${DEFAULT_MODEL_FILE}" ]; then
  ACTIVE_MODEL_FILE="$DEFAULT_MODEL_FILE"
  echo "Default model already present: $ACTIVE_MODEL_FILE"
else
  PREFERRED_MODELS=(
    "Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
    "Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf"
    "Qwen_Qwen3-Coder-Next-Q4_K_M.gguf"
  )
  for MODEL_CANDIDATE in "${PREFERRED_MODELS[@]}"; do
    if [ -f "${MODEL_DIR}/${MODEL_CANDIDATE}" ]; then
      ACTIVE_MODEL_FILE="$MODEL_CANDIDATE"
      echo "Using preferred existing model: $ACTIVE_MODEL_FILE"
      break
    fi
  done

  if [ -z "${ACTIVE_MODEL_FILE}" ]; then
    mapfile -t EXISTING_MODELS < <(find "$MODEL_DIR" -maxdepth 1 -type f -name '*.gguf' -printf '%f\n' | sort)
    if [ "${#EXISTING_MODELS[@]}" -gt 0 ]; then
      ACTIVE_MODEL_FILE="${EXISTING_MODELS[0]}"
      echo "Using existing model from mounted storage: $ACTIVE_MODEL_FILE"
    else
      ACTIVE_MODEL_FILE="$DEFAULT_MODEL_FILE"
      echo "No models found; downloading default: $ACTIVE_MODEL_FILE"
      wget -O "${MODEL_DIR}/${ACTIVE_MODEL_FILE}" "$DEFAULT_MODEL_URL"
    fi
  fi
fi

echo "ACTIVE_MODEL=${ACTIVE_MODEL_FILE}" >> /etc/ai-engine.env
BOOTSTRAP

echo "[4/7] Creating systemd service for llama-server (port ${LLAMA_PORT})..."
pct exec "${LXC_ID}" -- bash <<'BOOTSTRAP'
set -euo pipefail

ACTIVE_MODEL=$(grep -oP 'ACTIVE_MODEL=\K.*' /etc/ai-engine.env 2>/dev/null || echo "Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf")

cat > /etc/systemd/system/ai-engine.service << UNIT
[Unit]
Description=llama.cpp AI Engine - llama-server
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/llama.cpp/build/bin
Environment=HSA_OVERRIDE_GFX_VERSION=11.5.0
Environment=PATH=/opt/rocm/bin:/opt/rocm/llvm/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=LD_LIBRARY_PATH=/opt/rocm/lib
Environment=ROCM_PATH=/opt/rocm
Environment=HIP_PATH=/opt/rocm
ExecStart=/opt/llama.cpp/build/bin/llama-server \
  --model /srv/ai/models/${ACTIVE_MODEL} \
  --host 0.0.0.0 --port 8081 \
  --ctx-size 4096 \
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
UNIT
BOOTSTRAP

echo "[5/7] Creating interactive model switcher (${SWITCH_SCRIPT})..."
pct exec "${LXC_ID}" -- bash <<'BOOTSTRAP'
set -euo pipefail

MODEL_DIR="/srv/ai/models"
SERVICE="ai-engine"
SYSTEMD_SERVICE="/etc/systemd/system/${SERVICE}.service"
SWITCH_SCRIPT="/usr/local/bin/switch-model.sh"
MTP_DRAFT_N_MAX="${MTP_DRAFT_N_MAX:-3}"

is_mtp_model() {
  [[ "$(basename "$1")" =~ [Mm][Tt][Pp] ]]
}

rewrite_execstart() {
  local model="$1" ctx="$2" kv="$3" mtp="$4"
  local tmp_file
  tmp_file="$(mktemp)"
  cp "$SYSTEMD_SERVICE" "${SYSTEMD_SERVICE}.backup.$(date +%s)"

  awk -v model="$model" -v ctx="$ctx" -v kv="$kv" -v mtp="$mtp" -v mtpn="$MTP_DRAFT_N_MAX" '
    BEGIN { in_block=0; done=0 }
    /^ExecStart=.*llama-server/ {
      done=1
      print "ExecStart=/opt/llama.cpp/build/bin/llama-server \\"
      print "  --model " model " \\"
      print "  --host 0.0.0.0 --port 8081 \\"
      print "  --ctx-size " ctx " \\"
      print "  -ngl 48 \\"
      print "  --batch-size 128 \\"
      print "  --parallel 1 \\"
      print "  --cache-type-k " kv " \\"
      if (mtp == "1") {
        print "  --cache-type-v " kv " \\"
        print "  --spec-type draft-mtp \\"
        print "  --spec-draft-n-max " mtpn " \\"
        print "  --parallel 1"
      } else {
        print "  --cache-type-v " kv
      }
      in_block=1
      next
    }
    in_block {
      if (/^Restart=/) { in_block=0; print }
      next
    }
    { print }
    END { if (!done) exit 42 }
  ' "$SYSTEMD_SERVICE" > "$tmp_file" || {
    rm -f "$tmp_file"
    echo "ERROR: Failed to rewrite ExecStart in $SYSTEMD_SERVICE" >&2
    exit 1
  }

  mv "$tmp_file" "$SYSTEMD_SERVICE"
  echo "INFO: Successfully updated service configuration"
}

echo "  Model directory : $MODEL_DIR"
echo ""

mapfile -t MODELS < <(find "$MODEL_DIR" -maxdepth 1 -type f -name '*.gguf' | sort)
if [ "${#MODELS[@]}" -eq 0 ]; then
  echo "No .gguf models found in $MODEL_DIR."
  exit 1
fi

echo "Available models:"
for i in "${!MODELS[@]}"; do
  if is_mtp_model "${MODELS[$i]}"; then
    printf "  %2d) %s  [MTP]\n" $((i+1)) "${MODELS[$i]}"
  else
    printf "  %2d) %s\n" $((i+1)) "${MODELS[$i]}"
  fi
done

read -rp "Select model number to activate: " CHOICE
if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > ${#MODELS[@]} )); then
  echo "Invalid selection."
  exit 1
fi
NEW_MODEL="${MODELS[$((CHOICE-1))]}"

echo ""
echo "Context size options:"
echo "   1) 98304  (96K)  — maximum long-context"
echo "   2) 73728  (72K)  — extended long-context"
echo "   3) 65536  (64K)  — full long-context"
echo "   4) 32768  (32K)  — half, saves ~50% KV VRAM"
echo "   5) 16384  (16K)  — quarter, minimal KV usage"
echo "   6)  8192   (8K)  — minimal, maximum VRAM headroom"
echo "   7) Custom         — enter manually"

read -rp "Select context size [default: 65536]: " CTX_CHOICE
case "${CTX_CHOICE:-3}" in
  1) NEW_CTX=98304  ;;
  2) NEW_CTX=73728  ;;
  3) NEW_CTX=65536  ;;
  4) NEW_CTX=32768  ;;
  5) NEW_CTX=16384  ;;
  6) NEW_CTX=8192   ;;
  7)
    read -rp "Enter custom ctx-size: " NEW_CTX
    if ! [[ "$NEW_CTX" =~ ^[0-9]+$ ]]; then echo "Invalid ctx-size."; exit 1; fi
    ;;
  *) NEW_CTX=65536 ;;
esac

echo ""
echo "KV cache quantization (applies to both K and V cache):"
echo "   1) q8_0  — highest quality, ~2x VRAM vs q4"
echo "   2) q6_0  — very good quality, ~1.5x VRAM vs q4"
echo "   3) q4_0  — recommended, lowest VRAM, minimal quality loss"

read -rp "Select KV cache quant [default: q4_0]: " KV_CHOICE
case "${KV_CHOICE:-3}" in
  1) NEW_KV="q8_0" ;;
  2) NEW_KV="q6_0" ;;
  3) NEW_KV="q4_0" ;;
  *) NEW_KV="q4_0" ;;
esac

if is_mtp_model "$NEW_MODEL"; then
  NEW_MTP="yes"
  MTP_INFO="--spec-type draft-mtp --spec-draft-n-max $MTP_DRAFT_N_MAX --parallel 1"
else
  NEW_MTP="no"
  MTP_INFO="(none)"
fi

echo ""
echo "  New model   : $NEW_MODEL"
echo "  ctx-size    : $NEW_CTX"
echo "  KV cache    : $NEW_KV (K and V)"
echo "  MTP mode    : $NEW_MTP  $MTP_INFO"
echo ""
read -rp "Apply and restart $SERVICE? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

is_mtp_model "$NEW_MODEL" && NEW_MTP_FLAG="1" || NEW_MTP_FLAG="0"
rewrite_execstart "$NEW_MODEL" "$NEW_CTX" "$NEW_KV" "$NEW_MTP_FLAG"

systemctl daemon-reload
systemctl restart "$SERVICE"

echo "  Waiting for $SERVICE to start..."
for i in {1..15}; do
  if systemctl is-active --quiet "$SERVICE"; then break; fi
  sleep 2
done

if systemctl is-active --quiet "$SERVICE"; then
  echo "  [✓] Switched to : $NEW_MODEL"
  echo "  [✓] ctx-size    : $NEW_CTX"
  echo "  [✓] KV cache    : $NEW_KV (K and V)"
  echo "  [✓] MTP mode    : $NEW_MTP"
  echo "  [✓] Service     : $SERVICE running"
  echo ""
  echo "  Web UI ready at : http://$(hostname -I | awk '{print $1}'):8081"
  echo "  Verify VRAM     : rocm-smi"
  echo "  Watch logs      : journalctl -u $SERVICE -f"
else
  echo "  [✗] WARNING: $SERVICE did not start cleanly!"
  echo "  Check logs with: journalctl -u $SERVICE -f"
  exit 1
fi
BOOTSTRAP
chmod +x "${SWITCH_SCRIPT}"
cp "${SWITCH_SCRIPT}" "${MODEL_DIR}/switch-model.sh" 2>/dev/null || true

echo "[6/7] Enabling and starting ai-engine service..."
pct exec "${LXC_ID}" -- bash <<'BOOTSTRAP'
systemctl daemon-reload
systemctl enable --now ai-engine
BOOTSTRAP

echo "[7/7] Verifying setup..."
echo ""
pct exec "${LXC_ID}" -- bash <<'BOOTSTRAP'
echo "[rocm-smi]"
rocm-smi 2>/dev/null || echo "rocm-smi not available"
echo ""
echo "[llama-server version]"
/opt/llama.cpp/build/bin/llama-server --version 2>/dev/null || echo "llama-server not built"
echo ""
echo "[Service status]"
systemctl status ai-engine --no-pager 2>/dev/null || echo "Service not active"
echo ""
echo "[Bootstrap complete]"
BOOTSTRAP

echo ""
echo "============================================"
echo "  Dev AI engine deployed and configured!"
echo "============================================"
echo ""
echo "  Container  : LXC ${LXC_ID}"
echo "  Model dir  : ${MODEL_DIR} (shared with prod)"
echo "  llama-server: http://192.168.1.21:8081"
echo "  Switch model: switch-model.sh (run inside container)"
echo "  GPU        : gfx1150 (AMD Radeon 890M)"
echo "  ROCm       : ${ROCM_VERSION}"
echo ""
echo "  Compare with prod: http://192.168.1.12:80"
