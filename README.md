# iac-hlh

Infrastructure-as-Code repository for HLH, the Home Lab Hardware host at `192.168.6.10`.

This repository owns HLH host and runtime infrastructure only.

`apply.bash` is the operator entrypoint for Proxmox reconciliation.

## Repository Boundary

Included here:

- Proxmox host preparation and host-level automation
- LXC definitions and lifecycle management
- storage pools, mounts, and filesystem wiring
- network, bridge, VLAN, and service exposure wiring
- shared AI appliance deployment on HLH
- placement and runtime contracts for application LXCs

Excluded from this repository:

- TrashPanda application code
- BrickCipher application code
- VoxChimera application code
- job pipeline logic, prompts, schemas, or dashboards
- application-specific Dockerfiles and compose stacks

Application code stays in each application repository. This repo only decides how HLH runs and exposes shared or app-specific runtimes.

## HLH Role

HLH is the primary long-running host.

- platform: Proxmox VE
- host address: `192.168.6.10`
- shared AI appliance: hosted here for multiple applications
- application strategy: dedicated LXCs with strict boundaries

## First Host Target

The initial HLH target is intentionally small:

1. a shared AI engine LXC for local inference
2. storage and network contracts required by that runtime
3. clean separation between shared platform services and application repositories

The detailed HLH host contract lives in `docs/hlh-host-contract.md`.

## Repository Layout

```text
iac-hlh/
├── bootstrap/
├── docs/
├── inventory/
├── platforms/
├── scripts/
├── apply.bash
├── README.md
└── zfsbootstrap.sh
```

## Current Operator Workflow

The current reconciled runtime is one shared `engine` LXC.

Inside `engine`, apply provisions:

- `LocalAI` on port `8081` with its built-in llama-cpp gRPC backend (model loading + OpenAI-compatible API)
- `nginx` on port `8080` proxying the LocalAI UI and API
- per-model YAML configs in `/srv/ai/models/` for full llama.cpp flag control

`./apply.bash --plan inventory/hlh-prod.yaml` validates the inventory and prints the Proxmox reconciliation plan.
`./apply.bash inventory/hlh-prod.yaml` reconciles the shared AI appliance LXC on HLH.

Legacy engine containers from pre-localai-stack runs are blocked with a clear recreate-required error. Recreate once, then normal reconciliation continues.

## Additional Contracts

- `bootstrap/proxmox-enable-amd-igpu-host.bash` prepares the HLH Proxmox host to bind the AMD iGPU to `amdgpu` instead of `vfio-pci` so `/dev/dri` can be passed into the `engine` LXC after reboot.