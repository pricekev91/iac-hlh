#!/usr/bin/env bash

set -euo pipefail

log() {
  echo "[provision-ai-engine] $*"
}

fail() {
  echo "[provision-ai-engine] ERROR: $*" >&2
  exit 1
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    fail "This script must run as root inside the container."
  fi
}

install_base_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl jq git cmake ninja-build build-essential pkg-config libvulkan-dev vulkan-tools glslc spirv-headers docker.io docker-compose-v2 nginx gettext-base
}

write_runtime_contract() {
  install -d -m 0755 /etc/ai-engine /srv/ai/models /srv/ai/state /srv/ai/scratch /srv/ai/state/localai /opt/ai-engine/web

  cat >/etc/ai-engine/runtime.env <<EOF
AI_ENGINE_WEBUI_HOST=0.0.0.0
AI_ENGINE_WEBUI_PORT=${AI_ENGINE_WEBUI_PORT}
AI_ENGINE_LOCALAI_HOST=0.0.0.0
AI_ENGINE_LOCALAI_PORT=${AI_ENGINE_LOCALAI_PORT}
AI_ENGINE_LOCALAI_IMAGE=${AI_ENGINE_LOCALAI_IMAGE}
AI_ENGINE_LLAMA_SERVER_HOST=127.0.0.1
AI_ENGINE_LLAMA_SERVER_PORT=${AI_ENGINE_LLAMA_SERVER_PORT}
AI_ENGINE_DEFAULT_MODEL=${AI_ENGINE_DEFAULT_MODEL}
AI_ENGINE_DEFAULT_MODEL_URL=${AI_ENGINE_DEFAULT_MODEL_URL}
AI_ENGINE_DEFAULT_MODEL_PATH=${AI_ENGINE_DEFAULT_MODEL_PATH}
AI_ENGINE_PULL_DEFAULT_MODEL=${AI_ENGINE_PULL_DEFAULT_MODEL}
AI_ENGINE_LLAMA_CONTEXT_SIZE=${AI_ENGINE_LLAMA_CONTEXT_SIZE}
AI_ENGINE_LLAMA_GPU_LAYERS=${AI_ENGINE_LLAMA_GPU_LAYERS}
AI_ENGINE_LLAMA_THREADS=${AI_ENGINE_LLAMA_THREADS}
AI_ENGINE_LLAMA_BATCH_SIZE=${AI_ENGINE_LLAMA_BATCH_SIZE}
AI_ENGINE_LLAMA_PARALLEL=${AI_ENGINE_LLAMA_PARALLEL}
AI_ENGINE_LLAMA_FLASH_ATTN=${AI_ENGINE_LLAMA_FLASH_ATTN}
AI_ENGINE_LLAMA_NO_MMAP=${AI_ENGINE_LLAMA_NO_MMAP}
AI_ENGINE_LLAMA_MLOCK=${AI_ENGINE_LLAMA_MLOCK}
AI_ENGINE_LLAMA_MOE_K=${AI_ENGINE_LLAMA_MOE_K}
AI_ENGINE_LLAMA_MOE_EXPERT_OFFLOAD=${AI_ENGINE_LLAMA_MOE_EXPERT_OFFLOAD}
AI_ENGINE_LLAMA_CACHE_QUANT=${AI_ENGINE_LLAMA_CACHE_QUANT}
AI_ENGINE_LLAMA_CACHE_TYPE=${AI_ENGINE_LLAMA_CACHE_TYPE}
EOF

  cat >/usr/local/bin/ai-engine-status <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ -f /etc/ai-engine/runtime.env ]]; then
  . /etc/ai-engine/runtime.env
fi

cat <<STATUS
webui_port=${AI_ENGINE_WEBUI_PORT:-unknown}
localai_port=${AI_ENGINE_LOCALAI_PORT:-unknown}
localai_image=${AI_ENGINE_LOCALAI_IMAGE:-unknown}
llama_server_port=${AI_ENGINE_LLAMA_SERVER_PORT:-unknown}
default_model=${AI_ENGINE_DEFAULT_MODEL:-unknown}
default_model_url=${AI_ENGINE_DEFAULT_MODEL_URL:-unknown}
default_model_path=${AI_ENGINE_DEFAULT_MODEL_PATH:-unknown}
models_dir=/srv/ai/models
state_dir=/srv/ai/state
scratch_dir=/srv/ai/scratch
STATUS
EOF

  chmod 0755 /usr/local/bin/ai-engine-status
}

install_llama_cpp_server() {
  local src_root="/opt/llama.cpp"
  local build_root="${src_root}/build"

  if [[ ! -d "$src_root/.git" ]]; then
    git clone --depth 1 https://github.com/ggml-org/llama.cpp "$src_root"
  else
    git -C "$src_root" fetch --depth 1 origin
    git -C "$src_root" reset --hard origin/master
  fi

  # Clean stale build cache to avoid cmake re-using invalid cached paths
  rm -rf "$build_root"

  cmake -S "$src_root" -B "$build_root" -G Ninja -DGGML_VULKAN=ON -DLLAMA_BUILD_SERVER=ON -DCMAKE_BUILD_TYPE=Release
  cmake --build "$build_root" --target llama-server -j"$(nproc)"

  if [[ -x "$build_root/bin/llama-server" ]]; then
    install -m 0755 "$build_root/bin/llama-server" /usr/local/bin/llama-server
    return 0
  fi

  if [[ -x "$build_root/bin/server" ]]; then
    install -m 0755 "$build_root/bin/server" /usr/local/bin/llama-server
    return 0
  fi

  fail "Unable to find built llama.cpp server binary"
}

write_nginx_config() {
  cat >/etc/nginx/sites-available/ai-engine-webui.conf <<'EOF'
server {
  listen ${AI_ENGINE_WEBUI_PORT};
  server_name _;

  # Serve the official llama.cpp Svelte WebUI from llama-server.
  location / {
    proxy_pass http://127.0.0.1:${AI_ENGINE_LLAMA_SERVER_PORT}/;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  }

  # Endpoints used by llama.cpp WebUI.
  location /v1/ {
    proxy_pass http://127.0.0.1:${AI_ENGINE_LLAMA_SERVER_PORT}/v1/;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  }

  location /props {
    proxy_pass http://127.0.0.1:${AI_ENGINE_LLAMA_SERVER_PORT}/props;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  }

  location /slots {
    proxy_pass http://127.0.0.1:${AI_ENGINE_LLAMA_SERVER_PORT}/slots;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  }

  location /models {
    proxy_pass http://127.0.0.1:${AI_ENGINE_LLAMA_SERVER_PORT}/models;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  }

  # Optional LocalAI passthrough for model management APIs.
  location /localai/ {
    proxy_pass http://127.0.0.1:${AI_ENGINE_LOCALAI_PORT}/;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  }
}
EOF

  envsubst '${AI_ENGINE_WEBUI_PORT} ${AI_ENGINE_LOCALAI_PORT} ${AI_ENGINE_LLAMA_SERVER_PORT}' < /etc/nginx/sites-available/ai-engine-webui.conf > /etc/nginx/sites-available/ai-engine-webui.resolved.conf
  mv /etc/nginx/sites-available/ai-engine-webui.resolved.conf /etc/nginx/sites-available/ai-engine-webui.conf
  ln -sf /etc/nginx/sites-available/ai-engine-webui.conf /etc/nginx/sites-enabled/ai-engine-webui.conf
  rm -f /etc/nginx/sites-enabled/default
}

write_llama_server_wrapper() {
  cat >/usr/local/bin/ai-engine-llama-server <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

. /etc/ai-engine/runtime.env

model_path="${AI_ENGINE_DEFAULT_MODEL_PATH}"
if [[ ! -f "$model_path" ]]; then
  candidate="$(find /srv/ai/models -type f \( -name '*.gguf' -o -name '*.GGUF' \) | head -n 1 || true)"
  if [[ -n "$candidate" ]]; then
    model_path="$candidate"
  fi
fi

if [[ ! -f "$model_path" ]]; then
  echo "No GGUF model found at ${AI_ENGINE_DEFAULT_MODEL_PATH} or /srv/ai/models; llama.cpp server not started" >&2
  exit 0
fi

extra_args=()
[[ "${AI_ENGINE_LLAMA_FLASH_ATTN,,}" == "true" ]] && extra_args+=(--flash-attn on)
[[ "${AI_ENGINE_LLAMA_NO_MMAP,,}" == "true" ]] && extra_args+=(--no-mmap)
[[ "${AI_ENGINE_LLAMA_MLOCK,,}" == "true" ]] && extra_args+=(--mlock)
[[ -n "${AI_ENGINE_LLAMA_MOE_K:-}" && "${AI_ENGINE_LLAMA_MOE_K}" != "0" ]] && extra_args+=(--n-cpu-moe "${AI_ENGINE_LLAMA_MOE_K}")
[[ -n "${AI_ENGINE_LLAMA_MOE_EXPERT_OFFLOAD:-}" ]] && extra_args+=(--cpu-moe)
[[ -n "${AI_ENGINE_LLAMA_CACHE_QUANT:-}" && "${AI_ENGINE_LLAMA_CACHE_QUANT}" != "0" ]] && true  # --cache-quant not supported; skipped
[[ -n "${AI_ENGINE_LLAMA_CACHE_TYPE:-}" ]] && extra_args+=(--cache-type-k "${AI_ENGINE_LLAMA_CACHE_TYPE}")

exec /usr/local/bin/llama-server \
  --host "${AI_ENGINE_LLAMA_SERVER_HOST}" \
  --port "${AI_ENGINE_LLAMA_SERVER_PORT}" \
  --model "$model_path" \
  --ctx-size "${AI_ENGINE_LLAMA_CONTEXT_SIZE}" \
  --batch-size "${AI_ENGINE_LLAMA_BATCH_SIZE:-512}" \
  --gpu-layers "${AI_ENGINE_LLAMA_GPU_LAYERS}" \
  --threads "${AI_ENGINE_LLAMA_THREADS}" \
  --parallel "${AI_ENGINE_LLAMA_PARALLEL:-1}" \
  "${extra_args[@]}"
EOF

  chmod 0755 /usr/local/bin/ai-engine-llama-server
}

write_services() {
  cat >/etc/systemd/system/ai-engine-localai.service <<'EOF'
[Unit]
Description=AI Engine LocalAI API (middleware)
After=network-online.target docker.service
Wants=network-online.target docker.service

[Service]
Type=simple
EnvironmentFile=/etc/ai-engine/runtime.env
ExecStartPre=-/usr/bin/docker rm -f ai-engine-localai
ExecStart=/usr/bin/docker run --rm --name ai-engine-localai \
  --security-opt apparmor=unconfined \
  -p ${AI_ENGINE_LOCALAI_HOST}:${AI_ENGINE_LOCALAI_PORT}:8080 \
  -v /srv/ai/models:/models \
  -v /srv/ai/state/localai:/tmp/localai \
  ${AI_ENGINE_LOCALAI_IMAGE}
ExecStop=/usr/bin/docker stop ai-engine-localai
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  cat >/etc/systemd/system/ai-engine-llama-server.service <<'EOF'
[Unit]
Description=AI Engine llama.cpp server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/ai-engine/runtime.env
ExecStart=/usr/local/bin/ai-engine-llama-server
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable docker
  systemctl restart docker
  systemctl enable nginx
  systemctl enable ai-engine-localai.service
  systemctl enable ai-engine-llama-server.service
}

start_services() {
  systemctl restart ai-engine-localai.service
  systemctl restart nginx
  # This service exits cleanly when no GGUF model exists yet.
  systemctl restart ai-engine-llama-server.service || true
}

pull_default_model_if_requested() {
  if [[ "${AI_ENGINE_PULL_DEFAULT_MODEL,,}" != "true" ]]; then
    log "Skipping default model pull"
    return 0
  fi

  if [[ -n "${AI_ENGINE_DEFAULT_MODEL_URL}" ]]; then
    install -d -m 0755 "$(dirname "${AI_ENGINE_DEFAULT_MODEL_PATH}")"
    log "Downloading default GGUF model to ${AI_ENGINE_DEFAULT_MODEL_PATH}"
    local tmp_model_path
    tmp_model_path="${AI_ENGINE_DEFAULT_MODEL_PATH}.part"

    rm -f "${tmp_model_path}" "${AI_ENGINE_DEFAULT_MODEL_PATH}"
    curl -fL --retry 5 --retry-delay 3 -o "${tmp_model_path}" "${AI_ENGINE_DEFAULT_MODEL_URL}"

    # Validate GGUF magic before promoting to default model path.
    if [[ "$(head -c 4 "${tmp_model_path}" 2>/dev/null || true)" != "GGUF" ]]; then
      fail "Downloaded model is not a valid GGUF payload (missing GGUF header)"
    fi

    mv -f "${tmp_model_path}" "${AI_ENGINE_DEFAULT_MODEL_PATH}"
    chmod 0644 "${AI_ENGINE_DEFAULT_MODEL_PATH}"

    systemctl restart ai-engine-localai.service
    systemctl reset-failed ai-engine-llama-server.service || true
    systemctl restart ai-engine-llama-server.service || true
    return 0
  fi

  # Best-effort LocalAI catalog pull when no direct model URL is set.
  curl -fsSL "http://127.0.0.1:${AI_ENGINE_LOCALAI_PORT}/models/apply" \
    -H 'Content-Type: application/json' \
    -d "{\"id\":\"${AI_ENGINE_DEFAULT_MODEL}\"}" >/dev/null 2>&1 || true
}

verify_endpoints() {
  local attempt

  for attempt in $(seq 1 40); do
    if curl -fsS "http://127.0.0.1:${AI_ENGINE_WEBUI_PORT}/" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  for attempt in $(seq 1 40); do
    if curl -fsS "http://127.0.0.1:${AI_ENGINE_LOCALAI_PORT}/readyz" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  fail "LocalAI API did not become ready on port ${AI_ENGINE_LOCALAI_PORT}"
}

main() {
  require_root

  export AI_ENGINE_WEBUI_PORT="${AI_ENGINE_WEBUI_PORT:-8080}"
  export AI_ENGINE_LOCALAI_PORT="${AI_ENGINE_LOCALAI_PORT:-8081}"
  export AI_ENGINE_LOCALAI_IMAGE="${AI_ENGINE_LOCALAI_IMAGE:-localai/localai:latest-aio-cpu}"
  export AI_ENGINE_LLAMA_SERVER_PORT="${AI_ENGINE_LLAMA_SERVER_PORT:-8082}"
  export AI_ENGINE_DEFAULT_MODEL="${AI_ENGINE_DEFAULT_MODEL:-tinyllama-1.1b-chat-v1.0}"
  export AI_ENGINE_DEFAULT_MODEL_URL="${AI_ENGINE_DEFAULT_MODEL_URL:-https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf}"
  export AI_ENGINE_DEFAULT_MODEL_PATH="${AI_ENGINE_DEFAULT_MODEL_PATH:-/srv/ai/models/default.gguf}"
  export AI_ENGINE_PULL_DEFAULT_MODEL="${AI_ENGINE_PULL_DEFAULT_MODEL:-true}"
  export AI_ENGINE_LLAMA_CONTEXT_SIZE="${AI_ENGINE_LLAMA_CONTEXT_SIZE:-8192}"
  export AI_ENGINE_LLAMA_GPU_LAYERS="${AI_ENGINE_LLAMA_GPU_LAYERS:-99}"
  export AI_ENGINE_LLAMA_THREADS="${AI_ENGINE_LLAMA_THREADS:-12}"

  log "Installing baseline packages"
  install_base_packages

  log "Writing AI engine runtime contract"
  write_runtime_contract

  log "Building llama.cpp server with Vulkan"
  install_llama_cpp_server

  log "Writing web UI and service definitions"
  write_nginx_config
  write_llama_server_wrapper
  write_services

  log "Starting services"
  start_services

  pull_default_model_if_requested

  log "Verifying web UI and LocalAI API"
  verify_endpoints

  log "Provisioning complete"
}

main "$@"
