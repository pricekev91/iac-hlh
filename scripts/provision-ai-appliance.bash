#!/usr/bin/env bash

set -euo pipefail

log() {
  echo "[provision-ai-appliance] $*"
}

fail() {
  echo "[provision-ai-appliance] ERROR: $*" >&2
  exit 1
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo "This script must run as root inside the container." >&2
    exit 1
  fi
}

write_runtime_contract() {
  install -d -m 0755 /etc/ai-appliance /srv/ai/models /srv/ai/state /srv/ai/scratch /opt/ai-appliance/bin /opt/ai-appliance/lib

  cat >/etc/ai-appliance/runtime.env <<EOF
AI_APPLIANCE_BACKEND=${AI_APPLIANCE_BACKEND}
AI_APPLIANCE_API_PORT=${AI_APPLIANCE_API_PORT}
AI_APPLIANCE_MANAGER_PORT=${AI_APPLIANCE_MANAGER_PORT}
AI_APPLIANCE_DEFAULT_MODEL=${AI_APPLIANCE_DEFAULT_MODEL}
AI_APPLIANCE_PULL_DEFAULT_MODEL=${AI_APPLIANCE_PULL_DEFAULT_MODEL}
EOF

  cat >/usr/local/bin/ai-appliance-status <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ -f /etc/ai-appliance/runtime.env ]]; then
  . /etc/ai-appliance/runtime.env
fi

cat <<STATUS
backend=${AI_APPLIANCE_BACKEND:-unknown}
api_port=${AI_APPLIANCE_API_PORT:-unknown}
manager_port=${AI_APPLIANCE_MANAGER_PORT:-unknown}
default_model=${AI_APPLIANCE_DEFAULT_MODEL:-unknown}
models_dir=/srv/ai/models
state_dir=/srv/ai/state
scratch_dir=/srv/ai/scratch
STATUS
EOF

  chmod 0755 /usr/local/bin/ai-appliance-status
}

install_base_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl jq pciutils python3 python3-venv lsb-release zstd
}

install_ollama() {
  if ! command -v ollama >/dev/null 2>&1; then
    log "Installing Ollama"
    curl -fsSL https://ollama.com/install.sh | sh
  fi

  install -d -m 0755 /srv/ai/state/ollama-home

  install -d -m 0755 /etc/systemd/system/ollama.service.d
  cat >/etc/systemd/system/ollama.service.d/override.conf <<EOF
[Service]
Environment="OLLAMA_HOST=0.0.0.0:${AI_APPLIANCE_API_PORT}"
Environment="OLLAMA_MODELS=/srv/ai/models"
Environment="HOME=/srv/ai/state/ollama-home"
EOF

  systemctl daemon-reload
  systemctl enable ollama
}

ensure_ollama_storage_permissions() {
  id ollama >/dev/null 2>&1 || fail "ollama user is missing after install"

  install -d -m 0755 /srv/ai/state/ollama-home
  chown -R ollama:ollama /srv/ai/models /srv/ai/state /srv/ai/scratch
  chmod 0755 /srv/ai/models /srv/ai/state /srv/ai/scratch
}

write_manager_service() {
  cat >/opt/ai-appliance/lib/manager.py <<'EOF'
#!/usr/bin/env python3
import json
import os
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

BACKEND = os.environ.get("AI_APPLIANCE_BACKEND", "unknown")
API_PORT = int(os.environ.get("AI_APPLIANCE_API_PORT", "8080"))
MANAGER_PORT = int(os.environ.get("AI_APPLIANCE_MANAGER_PORT", "18080"))
DEFAULT_MODEL = os.environ.get("AI_APPLIANCE_DEFAULT_MODEL", "unknown")


def ollama_status():
    url = f"http://127.0.0.1:{API_PORT}/api/tags"
    try:
        with urllib.request.urlopen(url, timeout=2) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.URLError as exc:
        return {
            "reachable": False,
            "error": str(exc),
            "models": [],
        }

    models = []
    for item in payload.get("models", []):
        name = item.get("name")
        if name:
            models.append(name)

    return {
        "reachable": True,
        "models": models,
    }


class Handler(BaseHTTPRequestHandler):
    def send_json(self, status_code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self.send_json(200, {"status": "ok", "backend": BACKEND})
            return

        if self.path == "/engine/status":
            status = {
                "backend": BACKEND,
                "api_port": API_PORT,
                "manager_port": MANAGER_PORT,
                "default_model": DEFAULT_MODEL,
            }
            if BACKEND == "ollama":
                status["runtime"] = ollama_status()
            self.send_json(200, status)
            return

        self.send_json(404, {"error": "not_found"})

    def log_message(self, fmt, *args):
        return


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", MANAGER_PORT), Handler)
    server.serve_forever()
EOF

  chmod 0755 /opt/ai-appliance/lib/manager.py

  cat >/etc/systemd/system/ai-appliance-manager.service <<EOF
[Unit]
Description=AI Appliance Manager
After=network-online.target ollama.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/ai-appliance/runtime.env
ExecStart=/usr/bin/python3 /opt/ai-appliance/lib/manager.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable ai-appliance-manager.service
  systemctl restart ai-appliance-manager.service
}

wait_for_ollama() {
  local attempt

  for attempt in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:${AI_APPLIANCE_API_PORT}/api/tags" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  fail "Ollama did not become ready on port ${AI_APPLIANCE_API_PORT}"
}

pull_default_model_if_requested() {
  if [[ "${AI_APPLIANCE_PULL_DEFAULT_MODEL,,}" != "true" ]]; then
    log "Skipping default model pull"
    return 0
  fi

  log "Ensuring default model is available: ${AI_APPLIANCE_DEFAULT_MODEL}"
  ollama list 2>/dev/null | awk 'NR>1 { print $1 }' | grep -Fx "${AI_APPLIANCE_DEFAULT_MODEL}" >/dev/null 2>&1 || \
    ollama pull "${AI_APPLIANCE_DEFAULT_MODEL}"
}

main() {
  require_root

  : "${AI_APPLIANCE_BACKEND:=ollama}"
  : "${AI_APPLIANCE_API_PORT:=8080}"
  : "${AI_APPLIANCE_MANAGER_PORT:=18080}"
  : "${AI_APPLIANCE_DEFAULT_MODEL:=qwen2.5-coder:7b}"
  : "${AI_APPLIANCE_PULL_DEFAULT_MODEL:=false}"

  log "Installing baseline packages"
  install_base_packages

  log "Writing AI appliance runtime contract"
  write_runtime_contract

  case "${AI_APPLIANCE_BACKEND}" in
    ollama)
      install_ollama
      ensure_ollama_storage_permissions
      systemctl restart ollama
      wait_for_ollama
      pull_default_model_if_requested
      ;;
    *)
      fail "Unsupported AI_APPLIANCE_BACKEND: ${AI_APPLIANCE_BACKEND}"
      ;;
  esac

  log "Installing appliance manager service"
  write_manager_service

  log "Provisioning baseline complete"
}

main "$@"