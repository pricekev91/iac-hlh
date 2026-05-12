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
  apt-get install -y ca-certificates curl jq git cmake ninja-build build-essential pkg-config libvulkan-dev vulkan-tools docker.io docker-compose-v2 nginx gettext-base
}

write_runtime_contract() {
  install -d -m 0755 /etc/ai-engine /srv/ai/models /srv/ai/state /srv/ai/scratch /srv/ai/state/localai /opt/ai-engine/web

  cat >/etc/ai-engine/runtime.env <<EOF
AI_ENGINE_WEBUI_HOST=0.0.0.0
AI_ENGINE_WEBUI_PORT=${AI_ENGINE_WEBUI_PORT}
AI_ENGINE_LOCALAI_HOST=0.0.0.0
AI_ENGINE_LOCALAI_PORT=${AI_ENGINE_LOCALAI_PORT}
AI_ENGINE_LLAMA_SERVER_HOST=0.0.0.0
AI_ENGINE_LLAMA_SERVER_PORT=${AI_ENGINE_LLAMA_SERVER_PORT}
AI_ENGINE_DEFAULT_MODEL=${AI_ENGINE_DEFAULT_MODEL}
AI_ENGINE_DEFAULT_MODEL_PATH=${AI_ENGINE_DEFAULT_MODEL_PATH}
AI_ENGINE_PULL_DEFAULT_MODEL=${AI_ENGINE_PULL_DEFAULT_MODEL}
AI_ENGINE_LLAMA_CONTEXT_SIZE=${AI_ENGINE_LLAMA_CONTEXT_SIZE}
AI_ENGINE_LLAMA_GPU_LAYERS=${AI_ENGINE_LLAMA_GPU_LAYERS}
AI_ENGINE_LLAMA_THREADS=${AI_ENGINE_LLAMA_THREADS}
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
llama_server_port=${AI_ENGINE_LLAMA_SERVER_PORT:-unknown}
default_model=${AI_ENGINE_DEFAULT_MODEL:-unknown}
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

  cmake -S "$src_root" -B "$build_root" -G Ninja -DGGML_VULKAN=ON -DLLAMA_BUILD_SERVER=ON -DCMAKE_BUILD_TYPE=Release
  if ! cmake --build "$build_root" --target llama-server -j"$(nproc)"; then
    cmake --build "$build_root" --target server -j"$(nproc)"
  fi

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

write_web_ui() {
  cat >/opt/ai-engine/web/index.html <<'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>llama.cpp Web UI</title>
  <style>
    :root { color-scheme: dark; }
    body { font-family: "IBM Plex Sans", sans-serif; margin: 0; background: radial-gradient(circle at 20% 20%, #244, #0b1016 45%, #05070a 100%); color: #e8edf2; }
    .wrap { max-width: 900px; margin: 0 auto; padding: 32px 20px; }
    h1 { margin: 0 0 10px; font-size: 1.8rem; }
    p { opacity: 0.85; }
    textarea { width: 100%; min-height: 120px; border-radius: 12px; border: 1px solid #3c5068; padding: 12px; background: #111a24; color: #e8edf2; }
    button { margin-top: 12px; background: #4eb5ff; color: #04111f; border: 0; border-radius: 10px; font-weight: 700; padding: 10px 14px; cursor: pointer; }
    pre { white-space: pre-wrap; background: #0b141d; border: 1px solid #2b3f54; border-radius: 12px; padding: 12px; min-height: 120px; }
  </style>
</head>
<body>
  <div class="wrap">
    <h1>llama.cpp Web UI</h1>
    <p>Frontend on port 8080 calling LocalAI middleware on port 8081.</p>
    <textarea id="prompt" placeholder="Enter a prompt..."></textarea>
    <button id="run">Generate</button>
    <pre id="out"></pre>
  </div>
  <script>
    const promptEl = document.getElementById("prompt");
    const outEl = document.getElementById("out");
    document.getElementById("run").addEventListener("click", async () => {
      const prompt = promptEl.value.trim();
      if (!prompt) return;
      outEl.textContent = "Running...";
      try {
        const res = await fetch("/api/v1/chat/completions", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ model: "local-model", messages: [{ role: "user", content: prompt }], stream: false })
        });
        const payload = await res.json();
        outEl.textContent = payload?.choices?.[0]?.message?.content ?? JSON.stringify(payload, null, 2);
      } catch (err) {
        outEl.textContent = String(err);
      }
    });
  </script>
</body>
</html>
EOF
}

write_nginx_config() {
  cat >/etc/nginx/sites-available/ai-engine-webui.conf <<'EOF'
server {
  listen ${AI_ENGINE_WEBUI_PORT};
  server_name _;

  root /opt/ai-engine/web;
  index index.html;

  location / {
    try_files $uri $uri/ /index.html;
  }

  location /api/ {
    proxy_pass http://127.0.0.1:${AI_ENGINE_LOCALAI_PORT}/;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  }
}
EOF

  envsubst '${AI_ENGINE_WEBUI_PORT} ${AI_ENGINE_LOCALAI_PORT}' < /etc/nginx/sites-available/ai-engine-webui.conf > /etc/nginx/sites-available/ai-engine-webui.resolved.conf
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

exec /usr/local/bin/llama-server \
  --host "${AI_ENGINE_LLAMA_SERVER_HOST}" \
  --port "${AI_ENGINE_LLAMA_SERVER_PORT}" \
  --model "$model_path" \
  --ctx-size "${AI_ENGINE_LLAMA_CONTEXT_SIZE}" \
  --gpu-layers "${AI_ENGINE_LLAMA_GPU_LAYERS}" \
  --threads "${AI_ENGINE_LLAMA_THREADS}"
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
  -p ${AI_ENGINE_LOCALAI_HOST}:${AI_ENGINE_LOCALAI_PORT}:8080 \
  -v /srv/ai/models:/models \
  -v /srv/ai/state/localai:/tmp/localai \
  ghcr.io/mudler/localai:latest
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

  # Best-effort default model fetch. Users can still manage models via LocalAI.
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
    if curl -fsS "http://127.0.0.1:${AI_ENGINE_LOCALAI_PORT}/v1/models" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  fail "LocalAI API did not become ready on port ${AI_ENGINE_LOCALAI_PORT}"
}

main() {
  require_root

  : "${AI_ENGINE_WEBUI_PORT:=8080}"
  : "${AI_ENGINE_LOCALAI_PORT:=8081}"
  : "${AI_ENGINE_LLAMA_SERVER_PORT:=8082}"
  : "${AI_ENGINE_DEFAULT_MODEL:=qwen2.5-coder:7b}"
  : "${AI_ENGINE_DEFAULT_MODEL_PATH:=/srv/ai/models/default.gguf}"
  : "${AI_ENGINE_PULL_DEFAULT_MODEL:=false}"
  : "${AI_ENGINE_LLAMA_CONTEXT_SIZE:=8192}"
  : "${AI_ENGINE_LLAMA_GPU_LAYERS:=99}"
  : "${AI_ENGINE_LLAMA_THREADS:=12}"

  log "Installing baseline packages"
  install_base_packages

  log "Writing AI engine runtime contract"
  write_runtime_contract

  log "Building llama.cpp server with Vulkan"
  install_llama_cpp_server

  log "Writing web UI and service definitions"
  write_web_ui
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
