#!/usr/bin/env bash

set -euo pipefail

log() {
  echo "[provision-ai-appliance] $*"
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo "This script must run as root inside the container." >&2
    exit 1
  fi
}

write_runtime_contract() {
  install -d -m 0755 /etc/ai-appliance /srv/ai/models /srv/ai/state /srv/ai/scratch /opt/ai-appliance/bin

  cat >/etc/ai-appliance/runtime.env <<EOF
AI_APPLIANCE_BACKEND=${AI_APPLIANCE_BACKEND}
AI_APPLIANCE_API_PORT=${AI_APPLIANCE_API_PORT}
AI_APPLIANCE_MANAGER_PORT=${AI_APPLIANCE_MANAGER_PORT}
AI_APPLIANCE_DEFAULT_MODEL=${AI_APPLIANCE_DEFAULT_MODEL}
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
  apt-get install -y ca-certificates curl jq pciutils python3 python3-venv
}

main() {
  require_root

  : "${AI_APPLIANCE_BACKEND:=ollama}"
  : "${AI_APPLIANCE_API_PORT:=8080}"
  : "${AI_APPLIANCE_MANAGER_PORT:=18080}"
  : "${AI_APPLIANCE_DEFAULT_MODEL:=qwen2.5-coder:7b}"

  log "Installing baseline packages"
  install_base_packages

  log "Writing AI appliance runtime contract"
  write_runtime_contract

  log "Provisioning baseline complete"
}

main "$@"