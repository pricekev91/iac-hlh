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
  apt-get install -y ca-certificates curl jq docker.io docker-compose-v2 nginx gettext-base
}

write_runtime_contract() {
  install -d -m 0755 /etc/ai-engine /srv/ai/models /srv/ai/state /srv/ai/scratch /srv/ai/state/localai /opt/ai-engine/web

  cat >/etc/ai-engine/runtime.env <<EOF
AI_ENGINE_WEBUI_HOST=0.0.0.0
AI_ENGINE_WEBUI_PORT=${AI_ENGINE_WEBUI_PORT}
AI_ENGINE_LOCALAI_HOST=0.0.0.0
AI_ENGINE_LOCALAI_PORT=${AI_ENGINE_LOCALAI_PORT}
AI_ENGINE_LOCALAI_IMAGE=${AI_ENGINE_LOCALAI_IMAGE}
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

write_localai_model_config() {
  install -d -m 0755 /srv/ai/models

  local model_file
  local mmproj_file
  local model_config_path

  # Use absolute paths within the container's mount point so LocalAI can resolve them directly
  # LocalAI mounts host /srv/ai/models at container /build/models
  model_file="/build/models${AI_ENGINE_DEFAULT_MODEL_PATH#/srv/ai/models}"
  model_config_path="/srv/ai/models/${AI_ENGINE_DEFAULT_MODEL}.yaml"

  # Auto-detect mmproj: look for a gguf in the sibling mmproj/ directory relative to the model.
  # e.g. model at llama-cpp/models/Foo-GGUF/foo.gguf -> check llama-cpp/mmproj/Foo-GGUF/mmproj.gguf
  mmproj_file=""
  local model_dir
  model_dir="$(dirname "${AI_ENGINE_DEFAULT_MODEL_PATH}")"
  local model_parent_name
  model_parent_name="$(basename "$model_dir")"
  local models_root
  models_root="$(dirname "$(dirname "$model_dir")")"
  local mmproj_candidate
  mmproj_candidate="${models_root}/mmproj/${model_parent_name}/mmproj.gguf"
  if [[ -f "$mmproj_candidate" ]]; then
    # Use absolute path for mmproj too
    mmproj_file="/build/models${mmproj_candidate#/srv/ai/models}"
  fi

  # Write YAML using explicit conditionals to avoid heredoc newline escaping issues
  {
    echo "name: ${AI_ENGINE_DEFAULT_MODEL}"
    echo "backend: llama-cpp"
    echo "parameters:"
    echo "  model: ${model_file}"
    [[ -n "$mmproj_file" ]] && echo "  mmproj: ${mmproj_file}"
    echo "context_size: ${AI_ENGINE_LLAMA_CONTEXT_SIZE}"
    echo "threads: ${AI_ENGINE_LLAMA_THREADS}"
    echo "f16: true"
    echo "gpu_layers: ${AI_ENGINE_LLAMA_GPU_LAYERS}"
    echo "n_batch: ${AI_ENGINE_LLAMA_BATCH_SIZE}"
    [[ "${AI_ENGINE_LLAMA_NO_MMAP,,}" == "true" ]] && echo "mmap: false"
    [[ "${AI_ENGINE_LLAMA_MLOCK,,}" == "true" ]] && echo "mlock: true"
    [[ -n "${AI_ENGINE_LLAMA_CACHE_TYPE:-}" ]] && echo "cache_type_k: ${AI_ENGINE_LLAMA_CACHE_TYPE}"
    echo "options:"
    echo "  - use_jinja:true"
    echo "known_usecases:"
    echo "  - chat"
    echo "  - completion"
  } >"${model_config_path}"
}





write_nginx_config() {
  cat >/etc/nginx/sites-available/ai-engine-webui.conf <<'EOF'
server {
  listen ${AI_ENGINE_WEBUI_PORT};
  server_name _;

  # Proxy all traffic to LocalAI (API + built-in WebUI).
  location / {
    proxy_pass http://127.0.0.1:${AI_ENGINE_LOCALAI_PORT}/;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_read_timeout 600s;
    proxy_send_timeout 600s;
  }
}
EOF

  envsubst '${AI_ENGINE_WEBUI_PORT} ${AI_ENGINE_LOCALAI_PORT}' < /etc/nginx/sites-available/ai-engine-webui.conf > /etc/nginx/sites-available/ai-engine-webui.resolved.conf
  mv /etc/nginx/sites-available/ai-engine-webui.resolved.conf /etc/nginx/sites-available/ai-engine-webui.conf
  ln -sf /etc/nginx/sites-available/ai-engine-webui.conf /etc/nginx/sites-enabled/ai-engine-webui.conf
  rm -f /etc/nginx/sites-enabled/default
}



write_localai_wrapper() {
  cat >/usr/local/bin/ai-engine-localai-start <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

. /etc/ai-engine/runtime.env

# Build docker run command with optional GPU device passthrough
local docker_run_args=(
  --rm
  --name ai-engine-localai
  --security-opt apparmor=unconfined
  -p "${AI_ENGINE_LOCALAI_HOST}:${AI_ENGINE_LOCALAI_PORT}:8080"
  -v /srv/ai/models:/build/models
  -v /srv/ai/state/localai:/tmp/localai
  -e LLAMACPP_PARALLEL="${AI_ENGINE_LLAMA_PARALLEL:-1}"
)

# Pass GPU devices if available
if [[ -e /dev/dri/card0 ]]; then
  docker_run_args+=(--device /dev/dri/card0:/dev/dri/card0)
fi
if [[ -e /dev/dri/renderD128 ]]; then
  docker_run_args+=(--device /dev/dri/renderD128:/dev/dri/renderD128)
fi

exec /usr/bin/docker run "${docker_run_args[@]}" "${AI_ENGINE_LOCALAI_IMAGE}"
EOF

  chmod 0755 /usr/local/bin/ai-engine-localai-start
}

write_services() {
  cat >/etc/systemd/system/ai-engine-localai.service <<'EOF'
[Unit]
Description=AI Engine LocalAI (llama-cpp backend)
After=network-online.target docker.service
Wants=network-online.target docker.service

[Service]
Type=simple
EnvironmentFile=/etc/ai-engine/runtime.env
ExecStartPre=-/usr/bin/docker rm -f ai-engine-localai
ExecStart=/usr/local/bin/ai-engine-localai-start
ExecStop=/usr/bin/docker stop ai-engine-localai
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
}

start_services() {
  systemctl restart ai-engine-localai.service
  systemctl restart nginx
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
    return 0
  fi

  # Best-effort LocalAI catalog pull when no direct model URL is set.
  curl -fsSL "http://127.0.0.1:${AI_ENGINE_LOCALAI_PORT}/models/apply" \
    -H 'Content-Type: application/json' \
    -d "{\"id\":\"${AI_ENGINE_DEFAULT_MODEL}\"}" >/dev/null 2>&1 || true
}

verify_endpoints() {
  local attempt
  local status

  for attempt in $(seq 1 120); do
    status="$(curl -sS --connect-timeout 2 --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${AI_ENGINE_LOCALAI_PORT}/readyz" || true)"
    if [[ "$status" == "200" ]]; then
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
  export AI_ENGINE_LOCALAI_IMAGE="${AI_ENGINE_LOCALAI_IMAGE:-localai/localai:latest-cpu}"
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

  log "Writing LocalAI model config"
  write_localai_model_config

  log "Writing nginx config and service definitions"
  write_nginx_config
  write_localai_wrapper
  write_services

  log "Starting services"
  start_services

  pull_default_model_if_requested

  log "Verifying LocalAI API"
  verify_endpoints

  log "Provisioning complete"
}

main "$@"
