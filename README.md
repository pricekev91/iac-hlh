# iac-hlh

`iac-hlh` is now the HLH orchestrator repository.

It coordinates independently versioned infrastructure components instead of carrying their implementation directly in the monorepo.

## Orchestrator Model

The orchestrator owns top-level coordination, bootstrap flow, and pinned component selection.

Component repositories are versioned independently:

- `hlh-ai-engine`
- `hlh-docker`

Each component is included as a Git submodule pinned to a specific commit. Deployment workflows use those pinned revisions so runs stay deterministic and reviewable.

The repository uses a flat top-level structure for clarity and scalability. Components live at the repo root instead of under a shared `infra/` directory.

## Deployment Model

`deploy.sh` performs the orchestrator flow:

1. Initialize submodules at the pinned revisions recorded in this repository.
2. Run host bootstrap.
3. Deploy `hlh-ai-engine`.
4. Deploy `hlh-docker`.

Because submodules are pinned in the superproject commit, deployments consume deterministic component versions rather than whatever happens to be latest upstream.