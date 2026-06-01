#!/usr/bin/env bash
set -euo pipefail

# Updates Proxmox token permissions without storing credentials in this script.

PVE_HOST="${PVE_HOST:-192.168.1.10}"
PVE_USER="${PVE_USER:-root@pam}"
TOKEN_PATH="${TOKEN_PATH:-tofu%40pve!tofu-hlh-docker}"
TARGET_PATH="${TARGET_PATH:-/nodes/prox01}"
PRIVS="${PRIVS:-LXC.Allocate;VM.Allocate;VM.Config.Disk;VM.Config.Network;VM.PowerMgmt;Datastore.Allocate;Datastore.AllocateSpace}"

if [[ -z "${PVE_PASSWORD:-}" ]]; then
  read -rsp "Proxmox password for ${PVE_USER}: " PVE_PASSWORD
  echo
fi

RESPONSE="$(curl -sk -X POST "https://${PVE_HOST}:8006/api2/json/access/ticket" \
  -d "username=${PVE_USER}" \
  -d "password=${PVE_PASSWORD}" 2>/dev/null)"

TICKET="$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print(d['ticket'])")"
CSRF="$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print(d['CSRFPreventionToken'])")"

echo "Ticket acquired for ${PVE_USER} on ${PVE_HOST}."

curl -sk -b "PVEAuthCookie=$TICKET" \
  -H "CSRFPreventionToken: $CSRF" \
  -X PUT "https://${PVE_HOST}:8006/api2/json/access/tokens/${TOKEN_PATH}" \
  -d "privs=${PRIVS}" \
  -d "path=${TARGET_PATH}" 2>&1

echo
