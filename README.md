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
- LocalAI internal endpoint: `http://127.0.0.1:3000` (inside container)
- OpenAI-compatible API base: `http://192.168.6.252:8080/v1/`
- Model configs: `/srv/ai/models/*.yaml`
- Persistent host mounts:
	- `/srv/ai/models` -> `/srv/ai/models`
	- `/srv/ai/state` -> `/srv/ai/state`
	- `/srv/ai/scratch` -> `/srv/ai/scratch`

For VS Code Chat and other OpenAI-compatible clients, point the client at the `/v1/` base URL and choose a model from `GET /v1/models`. A `404` from `GET /v1` is not a failure for this stack; the compatibility contract is the OpenAI-style subroutes, especially `/v1/models` and `/v1/chat/completions`.

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

## Hybrid Migration Baseline (May 2026)

The existing engine path is intentionally unchanged:

1. `./apply.bash --plan inventory/hlh-prod.yaml`
2. `./apply.bash inventory/hlh-prod.yaml`

New Docker VM + service stacks are now introduced as a separate control path:

- OpenTofu module: `infra/tofu/modules/docker-vm`
- OpenTofu environment: `infra/tofu/environments/hlh-prod`
- Ansible role/playbook: `ansible/roles/docker_host`, `ansible/playbooks/docker-host.yml`
- Service stacks: `services/openspeedtest`, `services/uptime-kuma`
- Bash wrappers:
	- `scripts/hybrid-plan.bash`
	- `scripts/hybrid-apply.bash`
	- `scripts/hybrid-status.bash`

This keeps Bash as thin orchestration while OpenTofu manages infrastructure state and Ansible manages guest configuration.

### Hybrid Workflow

1. Copy `infra/tofu/environments/hlh-prod/terraform.tfvars.example` to `terraform.tfvars` and fill credentials/SSH key.
2. Update `ansible/inventory/hlh-prod.yml` to the Docker VM IP/SSH user.
3. Run:

```bash
./scripts/hybrid-plan.bash
./scripts/hybrid-apply.bash
./scripts/hybrid-status.bash
```

See `docs/hybrid-iac-migration.md` for details.

## AI VM ROCm Migration Path

The repository now supports a parallel migration from AI LXC to AI VM while keeping the existing path stable until cutover.

- Build and configure AI VM: `./scripts/ai-vm-apply.bash`
- Benchmark and validate: included in `ai-vm-apply.bash` and available in `ansible/playbooks/benchmark-ai-vm.yml`
- Switch endpoint: `./scripts/ai-vm-cutover.bash`
- Decommission legacy LXC (explicit confirm required): `./scripts/ai-vm-decommission-lxc.bash --confirm`

Modularity is a prime directive:

- Runtime provider switch lives in `ansible/group_vars/all.yml` (`container_runtime_provider`)
- Service orchestrator switch lives in `ansible/group_vars/all.yml` (`service_orchestrator_provider`)
- AI backend switch lives in `ansible/roles/ai_rocm_engine/defaults/main.yml` (`ai_backend_provider`, default `llama_cpp`)

See `docs/ai-vm-rocm-migration.md` for the full phase-by-phase flow.