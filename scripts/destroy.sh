#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -n "${ORCH:-}" ]]; then
  ORCH_SELECTED="${ORCH}"
else
  ORCH_SELECTED="$(awk -F': ' '/^orchestrator:/ {print $2}' "${ROOT_DIR}/config/defaults.yaml" | head -n1 | tr -d '"')"
  ORCH_SELECTED="${ORCH_SELECTED:-docker}"
fi

echo "[destroy] Tearing down orchestrator state for ${ORCH_SELECTED}"

case "${ORCH_SELECTED}" in
  docker)
    docker compose -f "${ROOT_DIR}/infra/docker/compose.yaml" down --remove-orphans
    ;;
  dockhand)
    dockhand destroy "${ROOT_DIR}/infra/dockhand/stack.hcl"
    ;;
  k8s)
    kubectl delete -f "${ROOT_DIR}/infra/k8s/" --ignore-not-found
    ;;
  *)
    echo "Unknown orchestrator: ${ORCH_SELECTED}" >&2
    exit 1
    ;;
esac

echo "[destroy] Teardown complete."
