# iac-hlh

Infrastructure-as-Code repository for HLH, the Proxmox host at `192.168.6.10`.

This repository is the infrastructure control plane for HLH. It defines and reconciles host-level runtime contracts, while application repositories remain independently owned and deployed.

## Executive Summary

As of May 2026, `iac-hlh` is operating a **single production shared AI runtime** on HLH:

- `engine` LXC (`vmid: 101`, hostname: `engine`, IP: `192.168.6.252/22`)
- privileged container mode (`engine.unprivileged: false`)
- Native `LocalAI` service with `llama-cpp` backend
- `nginx` reverse proxy for LocalAI UI/API exposure
- Host-mounted model/state/scratch paths for persistent operation
- AMD iGPU passthrough via `/dev/dri` for GPU-backed llama.cpp

This design intentionally centralizes inference infrastructure once and allows multiple applications to consume the same contract without coupling them to host internals.

## Scope And Governance Boundary

`iac-hlh` owns:

- Proxmox host-level preparation and bootstrap automation
- LXC lifecycle reconciliation (create/update/start/provision)
- host storage and bind-mount contracts
- network wiring, addressing, and runtime exposure policy
- shared AI appliance deployment and guardrails

`iac-hlh` does not own:

- application business logic, schemas, prompts, or dashboards
- app-specific compose stacks and Dockerfiles
- product runtime behavior inside application repositories

## Current State (Verified)

The active reconciliation path is:

1. `./apply.bash --plan inventory/hlh-prod.yaml`
2. `./apply.bash inventory/hlh-prod.yaml`

`apply.bash` currently reconciles only the shared `engine` stack and explicitly blocks legacy inventory sections (`presentation.*` and `trashpanda_app.*`) to prevent mixed-generation deployments.

### Runtime Contract

- UI/API proxy endpoint: `http://192.168.6.252:8080`
- Direct LocalAI endpoint: `http://192.168.6.252:8081`
- OpenAI-compatible API base: `http://192.168.6.252:8081/v1/`
- Model configs: `/srv/ai/models/*.yaml`
- Persistent host mounts:
	- `/srv/ai/models` -> `/srv/ai/models`
	- `/srv/ai/state` -> `/srv/ai/state`
	- `/srv/ai/scratch` -> `/srv/ai/scratch`

### Capacity Profile (Current Inventory)

- rootfs size: `250G`
- CPU: 12 cores (platform default)
- memory: 48 GiB (platform default)
- swap: 4 GiB
- privileged LXC with nesting/keyctl enabled (required for this GPU passthrough contract)

## Layered Architecture (Text Diagram)

```text
Layer 5 - Business/Application Consumers
	- TrashPanda and future applications call a stable OpenAI-compatible API
	- No direct ownership of host/LXC mechanics

Layer 4 - Shared Service Contract
	- Engine endpoint contract (8080/8081)
	- Model and inference tuning contract via YAML
	- Runtime health and readiness expectations

Layer 3 - Application Runtime (Inside engine LXC)
	- LocalAI binary + llama-cpp backend
	- nginx reverse proxy
	- systemd-managed services and readiness checks

Layer 2 - Infrastructure Reconciliation (Proxmox Host)
	- apply.bash parses platform + inventory YAML
	- pct create/set/start + mount/device orchestration
	- provisioning script push/exec and safety guardrails

Layer 1 - Physical/Host Foundation (HLH)
	- Proxmox VE host (192.168.6.10)
	- ZFS-backed storage pools
	- required AMD iGPU binding to amdgpu for /dev/dri passthrough when engine.enable_gpu=true
```

## Control And Data Flow (Text Diagram)

```text
Operator
	|
	|  ./apply.bash [--plan] inventory/hlh-prod.yaml
	v
Proxmox Host (HLH)
	|
	|-- pct create/set/start (LXC lifecycle)
	|-- pct set mp* (models/state/scratch mounts)
	|-- pct set dev* (/dev/dri passthrough when enabled; apply fails fast if host devices are missing)
	|-- pct push + pct exec (provision-ai-appliance.bash)
	v
Engine LXC (vmid 101)
	|
	|-- local-ai service (port 8081)
	|-- nginx proxy (port 8080)
	|-- /srv/ai/models/*.yaml inference config
	v
Consuming Applications
	|
	|-- OpenAI-compatible requests -> /v1/*
	|-- receive local inference responses
```

## Repository Layout

```text
iac-hlh/
├── apply.bash                        # Proxmox reconciliation operator
├── inventory/
│   └── hlh-prod.yaml                 # Environment-specific desired state
├── platforms/
│   ├── engine.yaml                   # Active shared AI runtime baseline
│   ├── presentation.yaml             # Defined but not active in apply path
│   └── trashpanda-app.yaml           # Defined but not active in apply path
├── scripts/
│   ├── provision-ai-appliance.bash   # Active in-container provisioning
│   ├── provision-openwebui.bash      # Available for future runtime slice
│   └── provision-trashpanda-host.bash# Available for future runtime slice
├── bootstrap/
│   ├── proxmox-enable-amd-igpu-host.bash
│   └── proxmox-zfs-storage.bash
└── docs/
		├── architecture.md
		├── hlh-host-contract.md
		├── amd-igpu-host.md
		└── trashpanda-app-contract.md
```

## Operational Notes For Leadership

- **Current maturity**: production-capable shared engine slice with reconciliation and guardrails.
- **Risk control**: explicit block on legacy mixed inventory keys reduces accidental cross-generation drift.
- **Scalability path**: additional LXC slices are represented as contracts/artifacts but intentionally not active in the current apply path.
- **Governance model**: strict separation between host infrastructure ownership (`iac-hlh`) and application repository ownership.

For detailed architecture, operating model, and risk posture, see `docs/architecture.md`.