#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Priority: explicit env ORCH, then config/defaults.yaml value, then docker.
if [[ -n "${ORCH:-}" ]]; then
  ORCH_SELECTED="${ORCH}"
else
  ORCH_SELECTED="$(awk -F': ' '/^orchestrator:/ {print $2}' "${ROOT_DIR}/config/defaults.yaml" | head -n1 | tr -d '"')"
  ORCH_SELECTED="${ORCH_SELECTED:-docker}"
fi

echo "[apply] Ensuring idempotent desired state..."
echo "[apply] Orchestrator=${ORCH_SELECTED}"

mkdir -p "${ROOT_DIR}/logs" "${ROOT_DIR}/tmp" "${ROOT_DIR}/.cache"

case "${ORCH_SELECTED}" in
  docker)
    docker compose -f "${ROOT_DIR}/infra/docker/compose.yaml" up -d
    ;;
  dockhand)
    dockhand apply "${ROOT_DIR}/infra/dockhand/stack.hcl"
    ;;
  k8s)
    kubectl apply -f "${ROOT_DIR}/infra/k8s/"
    ;;
  *)
    echo "Unknown orchestrator: ${ORCH_SELECTED}" >&2
    exit 1
    ;;
esac

echo "[apply] Done. State converged."
