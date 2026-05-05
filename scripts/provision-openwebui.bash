#!/usr/bin/env bash

set -euo pipefail

log() {
  echo "[provision-openwebui] $*"
}

fail() {
  echo "[provision-openwebui] ERROR: $*" >&2
  exit 1
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    fail "This script must run as root inside the container."
  fi
}

package_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -Fq 'install ok installed'
}

ensure_apt_packages() {
  local package
  local missing_packages=()

  for package in "$@"; do
    if ! package_installed "$package"; then
      missing_packages+=("$package")
    fi
  done

  if (( ${#missing_packages[@]} == 0 )); then
    return 0
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends "${missing_packages[@]}"
}

script_sha256() {
  sha256sum "$0" | awk '{ print $1 }'
}

write_runtime_contract() {
  install -d -m 0755 /etc/ai-presentation /opt/openwebui /var/lib/open-webui

  cat >/etc/ai-presentation/runtime.env <<EOF
AI_PRESENTATION_HOST=${AI_PRESENTATION_HOST}
AI_PRESENTATION_PORT=${AI_PRESENTATION_PORT}
AI_PRESENTATION_OLLAMA_BASE_URL=${AI_PRESENTATION_OLLAMA_BASE_URL}
AI_PRESENTATION_WEBUI_AUTH=${AI_PRESENTATION_WEBUI_AUTH}
EOF
}

install_wrapper() {
  cat >/usr/local/bin/ai-presentation <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

export HOST="${AI_PRESENTATION_HOST:-0.0.0.0}"
export PORT="${AI_PRESENTATION_PORT:-3000}"
export OLLAMA_BASE_URL="${AI_PRESENTATION_OLLAMA_BASE_URL:-http://127.0.0.1:8080}"
export WEBUI_AUTH="${AI_PRESENTATION_WEBUI_AUTH:-False}"

if [[ $# -eq 0 ]]; then
  exec /opt/openwebui/venv/bin/open-webui serve --host "$HOST" --port "$PORT"
fi

if [[ "$1" == "serve" ]]; then
  shift
  exec /opt/openwebui/venv/bin/open-webui serve --host "$HOST" --port "$PORT" "$@"
fi

exec /opt/openwebui/venv/bin/open-webui "$@"
EOF

  chmod 0755 /usr/local/bin/ai-presentation
}

cleanup_partial_install() {
  rm -rf /root/.cache/pip

  if [[ -d /opt/openwebui/venv && ! -x /opt/openwebui/venv/bin/open-webui ]]; then
    rm -rf /opt/openwebui/venv
  fi
}

install_openwebui() {
  local install_stamp_path="/opt/openwebui/.install-script.sha256"
  local current_script_sha
  local installed_script_sha=""

  current_script_sha="$(script_sha256)"
  if [[ -f "$install_stamp_path" ]]; then
    installed_script_sha="$(cat "$install_stamp_path")"
  fi

  if [[ "$installed_script_sha" == "$current_script_sha" && -x /opt/openwebui/venv/bin/open-webui ]]; then
    install_wrapper
    return 0
  fi

  ensure_apt_packages build-essential ca-certificates python3 python3-pip python3-venv curl
  cleanup_partial_install

  if [[ ! -x /opt/openwebui/venv/bin/python ]]; then
    python3 -m venv /opt/openwebui/venv
  fi

  PIP_NO_CACHE_DIR=1 /opt/openwebui/venv/bin/pip install --upgrade --no-cache-dir pip setuptools wheel

  if ! /opt/openwebui/venv/bin/pip show torch >/dev/null 2>&1; then
    PIP_NO_CACHE_DIR=1 /opt/openwebui/venv/bin/pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu torch
  fi

  PIP_NO_CACHE_DIR=1 /opt/openwebui/venv/bin/pip install --upgrade --no-cache-dir open-webui

  install_wrapper
  printf '%s\n' "$current_script_sha" >"$install_stamp_path"
}

write_service() {
  cat >/etc/systemd/system/ai-presentation.service <<'EOF'
[Unit]
Description=AI Presentation Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/ai-presentation/runtime.env
Environment=DATA_DIR=/var/lib/open-webui
ExecStart=/usr/local/bin/ai-presentation serve
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable ai-presentation.service
  systemctl restart ai-presentation.service
}

verify_openwebui() {
  local attempt

  for attempt in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:${AI_PRESENTATION_PORT}/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  fail "Open WebUI did not become ready on port ${AI_PRESENTATION_PORT}"
}

main() {
  require_root

  : "${AI_PRESENTATION_HOST:=0.0.0.0}"
  : "${AI_PRESENTATION_PORT:=3000}"
  : "${AI_PRESENTATION_OLLAMA_BASE_URL:=http://127.0.0.1:8080}"
  : "${AI_PRESENTATION_WEBUI_AUTH:=False}"

  log "Writing presentation runtime contract"
  write_runtime_contract

  log "Installing Open WebUI"
  install_openwebui

  log "Installing presentation service"
  write_service

  log "Waiting for Open WebUI"
  verify_openwebui

  log "Provisioning complete"
}

main "$@"