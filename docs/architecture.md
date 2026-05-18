# HLH Architecture

## 1. Executive Intent

`iac-hlh` is the infrastructure control repository for HLH (`192.168.6.10`).

Its strategic purpose is to provide a stable, shared AI runtime on Proxmox that can serve multiple applications while preserving strict ownership boundaries:

- `iac-hlh` owns infrastructure contracts and runtime placement.
- application repositories own product logic and application behavior.

As of May 2026, the active reconciled runtime is a single shared `engine` LXC.

## 2. Current-State Summary

### Active In Production

- Proxmox-hosted `engine` LXC (`vmid: 101`)
- Privileged LXC (`unprivileged: false`) for deterministic device passthrough
- Native `LocalAI` with `llama-cpp` backend
- `nginx` reverse proxy in front of LocalAI
- Persistent host mounts for model/state/scratch data
- AMD iGPU passthrough using `/dev/dri` for GPU-backed llama.cpp inference

### Defined But Not Active In The Apply Path

- `platforms/presentation.yaml`
- `platforms/trashpanda-app.yaml`
- `scripts/provision-openwebui.bash`
- `scripts/provision-trashpanda-host.bash`

`apply.bash` currently enforces a single-engine generation and exits if legacy inventory keys (`presentation.*` or `trashpanda_app.*`) are present.

## 3. Layered Architecture

```text
Layer 6 - Business Outcomes
	- Fast local inference capability
	- Shared service reuse across products
	- Controlled infrastructure risk and cost

Layer 5 - Consumer Applications
	- TrashPanda and future application repos
	- Depend on API contract, not host internals

Layer 4 - Shared AI Service Contract
	- External Endpoint: 8080 (nginx proxy on host: 192.168.6.252:8080)
	- Internal Endpoint: 3000 (LocalAI inside container)
	- OpenAI-compatible API surface at /v1/*
	- Declarative per-model YAML runtime tuning

Layer 3 - Engine Runtime (Inside LXC)
	- local-ai binary and llama-cpp backend
	- systemd unit: ai-engine-localai.service
	- nginx service for UI/API proxying
	- runtime.env contract for deterministic startup

Layer 2 - Reconciliation Control Plane (Proxmox Host)
	- apply.bash operator
	- YAML merge: platforms/engine.yaml + inventory/hlh-prod.yaml
	- pct lifecycle operations, mounts, device mapping
	- provisioning push/exec and compatibility guardrails

Layer 1 - Host Foundation (HLH)
	- Proxmox VE host at 192.168.6.10
	- storage backing and network bridge policy
	- required amdgpu host binding for /dev/dri passthrough
```

## 4. Architecture Views

### 4.1 Control Flow View

```text
Operator/Automation
	|
	|  ./apply.bash [--plan] inventory/hlh-prod.yaml
	v
apply.bash on HLH (Control Plane)
	|
	|-- validate config + compatibility gates
	|-- pct create/set/start
	|-- pct set mp0/mp1/mp2
	|-- pct set dev0/dev1 (when GPU enabled)
	|-- pct push provision-ai-appliance.bash
	|-- pct exec env ... /root/provision-ai-appliance.bash
	v
Engine LXC (Data Plane)
```

### 4.2 Service Runtime View

```text
Client Applications
	|
	| HTTP requests
	v
nginx :8080 (inside engine)
	|
	| proxy_pass to localhost:3000
	v
LocalAI :3000 (inside engine)
	|
	| llama-cpp backend + model YAML config
	v
Model Artifacts (/srv/ai/models)

State Paths:
	/srv/ai/state    -> LocalAI data + backends
	/srv/ai/scratch  -> transient workload space
```

### 4.3 Host-To-Container Contract View

```text
HLH Host Paths                    Engine Container Paths
-------------------------------   ----------------------------
/srv/ai/models                 -> /srv/ai/models
/srv/ai/state                  -> /srv/ai/state
/srv/ai/scratch                -> /srv/ai/scratch
/dev/dri/card0      (required when engine.enable_gpu=true) -> /dev/dri/card0
/dev/dri/renderD128 (required when engine.enable_gpu=true) -> /dev/dri/renderD128
```

## 5. Operating Model

### Reconciliation Lifecycle

1. Validate and plan desired state (`--plan`).
2. Reconcile LXC base configuration and networking.
3. Reconcile mounts and optional GPU devices.
4. Ensure container runtime is started.
5. Push and execute in-container provisioning.
6. Verify LocalAI readiness (`/readyz`) before success.

### Guardrails And Safety Controls

- Legacy stack protection: non-`localai-stack` engine tags require one-time recreate.
- Legacy inventory key protection: mixed generation keys are rejected.
- GPU safety gate: `engine.enable_gpu=true` requires privileged LXC and host `/dev/dri` device presence.
- Provisioning verifies executable integrity and endpoint readiness before completion.

## 6. Capacity And Configuration Posture

Current inventory and platform defaults combine to a high-capacity engine footprint:

- rootfs: `250G`
- CPU: 12 cores
- memory: 48 GiB
- swap: 4 GiB
- network: bridged static IP (`192.168.6.252/22`)
- GPU mode: enabled (host prerequisite required)

Primary model settings are inventory-controlled (model path, context size, GPU layers, threads, batching, cache behavior), allowing tuning without changing operator code.

## 7. Security And Governance Notes

- The engine runtime is privileged by contract for GPU passthrough to llama.cpp.
- Secrets are expected to be managed outside git and injected by runtime wiring.
- Ownership boundaries remain strict: application repos consume contracts; they do not define HLH host internals.

## 8. Risks And Considerations

- GPU dependency risk: if host remains bound to `vfio-pci`, `/dev/dri` passthrough is unavailable.
- Host readiness risk: if `/dev/dri/card0` or `/dev/dri/renderD128` is missing, apply now fails fast instead of silently degrading to CPU.
- Single-runtime concentration risk: current architecture concentrates shared inference into one LXC.
- Documentation drift risk: future activation of presentation/app slices requires synchronized contract updates.

## 9. Forward Path

The repository already contains artifacts for future runtime slices (presentation and app hosting), but current operator behavior intentionally preserves a single-engine scope.

Expansion should occur only when:

1. service-level objectives for the shared engine are stable,
2. operational observability is sufficient for multi-slice operations,
3. ownership boundaries remain enforceable.

## 10. Key Artifacts

- `apply.bash` - HLH reconciliation entrypoint
- `inventory/hlh-prod.yaml` - production environment values
- `platforms/engine.yaml` - shared AI engine baseline
- `scripts/provision-ai-appliance.bash` - in-container engine provisioning
- `docs/amd-igpu-host.md` - host GPU binding preconditions
