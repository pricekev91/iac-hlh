#!/usr/bin/env bash

set -euo pipefail

log() {
  echo "[provision-trashpanda-host] $*"
}

fail() {
  echo "[provision-trashpanda-host] ERROR: $*" >&2
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

write_daemon_config() {
  local docker_data_root="${TRASHPANDA_DOCKER_DATA_ROOT:-/var/lib/docker}"

  install -d -m 0755 /etc/docker "$docker_data_root" /srv/trashpanda/data

  cat >/etc/docker/daemon.json <<EOF
{
  "data-root": "${docker_data_root}",
  "log-driver": "local"
}
EOF
}

enable_docker() {
  systemctl enable docker
  systemctl restart docker
}

verify_runtime() {
  docker version >/dev/null
  docker compose version >/dev/null
}

main() {
  require_root

  log "Installing Docker runtime packages"
  ensure_apt_packages ca-certificates curl docker.io docker-compose-v2 git

  log "Writing Docker daemon configuration"
  write_daemon_config

  log "Enabling Docker service"
  enable_docker

  log "Verifying Docker runtime"
  verify_runtime

  log "Provisioning complete"
}

main "$@"