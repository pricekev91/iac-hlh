#!/usr/bin/env bash
# switch-backend.sh — Interactive backend + model switcher for llama.cpp AI engine
#
# Toggles between HIP and Vulkan builds, then optionally switches models.
set -euo pipefail

MODEL_DIR="/srv/ai/models"
SERVICE="ai-engine"
SYSTEMD_SERVICE="/etc/systemd/system/${SERVICE}.service"
ENV_FILE="/etc/ai-engine.env"
MTP_DRAFT_N_MAX="${MTP_DRAFT_N_MAX:-3}"
BIN_DIR="/opt/llama.cpp/bin"

is_mtp_model() {
  [[ "$(basename "$1")" =~ [Mm][Tt][Pp] ]]
}

update_execstart() {
  local backend_bin="$1" model="$2" ctx="$3" kv="$4" mtp="$5"
  local tmp_file
  tmp_file="$(mktemp)"
  cp "$SYSTEMD_SERVICE" "${SYSTEMD_SERVICE}.backup.$(date +%s)"

  awk -v backend="$backend_bin" -v model="$model" -v ctx="$ctx" -v kv="$kv" -v mtp="$mtp" -v mtpn="$MTP_DRAFT_N_MAX" '
    BEGIN { in_block=0; done=0 }
    /^ExecStart=.*llama-server/ {
      done=1
      print "ExecStart=" backend " \\"
      print "  --model " model " \\"
      print "  --host 0.0.0.0 --port 80 \\"
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
  echo "  Service config updated."
}

echo "╔══════════════════════════════════════════╗"
echo "║   llama.cpp Backend + Model Switcher     ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# Read current backend from the service file
current_backend_name=$(grep -oP 'ExecStart=/opt/llama\.cpp/bin/(\S+)' "$SYSTEMD_SERVICE" 2>/dev/null | grep -oP 'bin/\K\w+' || echo "hip")
current_model=$(grep -oP '\-\-model \K/[^ ]+' "$SYSTEMD_SERVICE" 2>/dev/null || echo "unknown")
echo "Current backend : ${current_backend_name}"
echo "Current model   : ${current_model##*/}"
echo ""

# ─── Step 1: Backend selection ────────────────────────────────────────────────
echo "Backend options:"
echo "  1) hip      — AMD ROCm (native AMD GPU compute)"
echo "  2) vulkan   — Vulkan (cross-platform GPU)"
echo ""

read -rp "Select backend [default: ${current_backend_name}]: " BACKEND_CHOICE
case "${BACKEND_CHOICE:-$current_backend_name}" in
  hip|1)    NEW_BACKEND_NAME="hip" ;;
  vulkan|2) NEW_BACKEND_NAME="vulkan" ;;
  *)
    echo "Invalid backend."
    exit 1
    ;;
esac

NEW_BACKEND_BIN="${BIN_DIR}/${NEW_BACKEND_NAME}"

if [ "$NEW_BACKEND_NAME" = "$current_backend_name" ]; then
  echo "Already using backend: ${NEW_BACKEND_NAME}"
else
  echo "Switching backend: ${current_backend_name} → ${NEW_BACKEND_NAME}"

  # Update env file for persistency
  sed -i "s/^DEFAULT_BACKEND=.*/DEFAULT_BACKEND=${NEW_BACKEND_NAME}/" "$ENV_FILE"
fi

echo ""

# ─── Step 2: Model selection ──────────────────────────────────────────────────
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

read -rp "Select model number (or 0 to skip): " CHOICE
if [ "$CHOICE" -gt 0 ] 2>/dev/null && [ "$CHOICE" -le "${#MODELS[@]}" ]; then
  NEW_MODEL="${MODELS[$((CHOICE-1))]}"

  # Context size
  echo ""
  echo "Context size options:"
  echo "   1) 98304  (96K)  — maximum long-context"
  echo "   2) 73728  (72K)  — extended long-context"
  echo "   3) 65536  (64K)  — full long-context"
  echo "   4) 32728  (32K)  — half, saves ~50% KV VRAM"
  echo "   5) 16384  (16K)  — quarter, minimal KV usage"
  echo "   6)  8192   (8K)  — minimal, maximum VRAM headroom"
  echo "   7) Custom"

  read -rp "Select context size [default: 65536]: " CTX_CHOICE
  case "${CTX_CHOICE:-3}" in
    1) NEW_CTX=98304  ;;
    2) NEW_CTX=73728 ;;
    3) NEW_CTX=65536 ;;
    4) NEW_CTX=32768 ;;
    5) NEW_CTX=16384 ;;
    6) NEW_CTX=8192   ;;
    7)
      read -rp "Enter custom ctx-size: " NEW_CTX
      if ! [[ "$NEW_CTX" =~ ^[0-9]+$ ]]; then echo "Invalid ctx-size."; exit 1; fi
      ;;
    *) NEW_CTX=65536 ;;
  esac

  # KV cache quantization
  echo ""
  echo "KV cache quantization:"
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

  # MTP detection
  is_mtp_model "$NEW_MODEL" && NEW_MTP_FLAG="1" || NEW_MTP_FLAG="0"

  echo ""
  echo "  New backend : ${NEW_BACKEND_NAME}"
  echo "  New model   : ${NEW_MODEL##*/}"
  echo "  ctx-size    : ${NEW_CTX}"
  echo "  KV cache    : ${NEW_KV} (K and V)"
  [ "$NEW_MTP_FLAG" = "1" ] && echo "  MTP mode    : enabled"
  echo ""
  read -rp "Apply and restart ${SERVICE}? [y/N]: " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi

  update_execstart "$NEW_BACKEND_BIN" "$NEW_MODEL" "$NEW_CTX" "$NEW_KV" "$NEW_MTP_FLAG"
else
  echo "Skipping model switch (keeping current)."
fi

# ─── Restart ──────────────────────────────────────────────────────────────────
systemctl daemon-reload
systemctl restart "$SERVICE"

echo ""
echo "  Waiting for ${SERVICE} to start..."
for i in {1..15}; do
  if systemctl is-active --quiet "$SERVICE"; then break; fi
  sleep 2
done

if systemctl is-active --quiet "$SERVICE"; then
  echo "  [✓] Backend     : ${NEW_BACKEND_NAME}"
  [ "$CHOICE" -gt 0 ] 2>/dev/null && echo "  [✓] Model       : ${NEW_MODEL##*/}"
  echo "  [✓] Service     : ${SERVICE} running"
  echo ""
  echo "  Web UI ready at : http://$(hostname -I | awk '{print $1}'):80"
  echo "  Verify VRAM     : rocm-smi"
  echo "  Watch logs      : journalctl -u ${SERVICE} -f"
else
  echo "  [✗] WARNING: ${SERVICE} did not start cleanly!"
  echo "  Check logs with: journalctl -u ${SERVICE} -f"
  exit 1
fi
