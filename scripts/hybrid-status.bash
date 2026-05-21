#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "[hybrid-status] Docker host docker ps"
ansible docker_hosts -i "${ROOT_DIR}/ansible/inventory/hlh-prod.yml" -b -m shell -a "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"

echo "[hybrid-status] Compose stack states"
ansible docker_hosts -i "${ROOT_DIR}/ansible/inventory/hlh-prod.yml" -b -m shell -a "docker compose -f /opt/hlh/services/openspeedtest/docker-compose.yml ps"
ansible docker_hosts -i "${ROOT_DIR}/ansible/inventory/hlh-prod.yml" -b -m shell -a "docker compose -f /opt/hlh/services/uptime-kuma/docker-compose.yml ps"

echo "[hybrid-status] OpenSpeedTest URL: http://<docker-host-ip>:3001"
echo "[hybrid-status] Uptime Kuma URL: http://<docker-host-ip>:3003"
