#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -n "${ORCH:-}" ]]; then
  ORCH_SELECTED="${ORCH}"
else
  ORCH_SELECTED="$(awk -F': ' '/^orchestrator:/ {print $2}' "${ROOT_DIR}/config/defaults.yaml" | head -n1 | tr -d '"')"
  ORCH_SELECTED="${ORCH_SELECTED:-docker}"
fi

echo "[verify] Verifying desired state using ${ORCH_SELECTED}"

case "${ORCH_SELECTED}" in
  docker)
    docker compose -f "${ROOT_DIR}/infra/docker/compose.yaml" ps
    ;;
  dockhand)
    dockhand status "${ROOT_DIR}/infra/dockhand/stack.hcl"
    ;;
  k8s)
    kubectl get all
    ;;
  *)
    echo "Unknown orchestrator: ${ORCH_SELECTED}" >&2
    exit 1
    ;;
esac

echo "[verify] Verification complete."
