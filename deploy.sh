#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_SCRIPT="${ROOT_DIR}/bootstrap/zfsbootstrap.sh"
AI_ENGINE_DEPLOY="${ROOT_DIR}/hlh-ai-engine/infra/hlh-ai-engine/deploy-hlh-ai-engine.sh"
DOCKER_DEPLOY="${ROOT_DIR}/hlh-docker/infra/hlh-docker/deploy-hlh-docker.sh"

require_executable() {
	local path="$1"
	[[ -x "$path" ]] || {
		echo "ERROR: Required executable not found: $path" >&2
		exit 1
	}
}

echo "[1/5] Initializing pinned submodules..."
git -C "$ROOT_DIR" submodule sync --recursive
git -C "$ROOT_DIR" submodule update --init --recursive --checkout

echo "Pinned component revisions:"
git -C "$ROOT_DIR" submodule status --recursive

require_executable "$BOOTSTRAP_SCRIPT"
require_executable "$AI_ENGINE_DEPLOY"
require_executable "$DOCKER_DEPLOY"

echo "[2/5] Running bootstrap..."
"$BOOTSTRAP_SCRIPT"

echo "[3/5] Deploying hlh-ai-engine..."
"$AI_ENGINE_DEPLOY"

echo "[4/5] Deploying hlh-docker..."
"$DOCKER_DEPLOY"

echo "[5/5] Complete."
echo "Deterministic component versions were taken from the pinned submodule commits in this repository."