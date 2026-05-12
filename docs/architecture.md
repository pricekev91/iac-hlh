# HLH Architecture

## Intent

`iac-hlh` manages HLH host infrastructure for `192.168.6.10`.

The first reconciled runtime is a shared AI engine LXC named `engine`. That appliance is shared infrastructure and must remain independent of any single application repository.

## Apply Layout

The repository uses a small apply-style operator layout:

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

- `apply.bash` is the operator entrypoint for Proxmox reconciliation
- `inventory/` contains HLH-specific host values
- `platforms/` contains reusable runtime definitions such as the shared `engine` appliance
- `scripts/` contains in-container provisioning logic
- `bootstrap/` contains host preparation scripts

## First Runtime Target

The first runtime target is the shared `engine` LXC.

Current scope:

- privileged Proxmox LXC
- bridged network attachment
- mounted host paths for models, state, and scratch data
- optional `/dev/dri` passthrough for AMD iGPU-backed inference
- in-container provisioning for one local AI stack: `llama.cpp` server, `LocalAI`, and `llama.cpp Web UI`
- host-side AMD iGPU rebinding workflow for HLH when Proxmox is still binding the device to `vfio-pci`

Out of scope for this slice:

- application-specific Docker stacks
- orchestrator and agents LXCs

## Appliance Contract

The shared appliance should continue presenting a stable local contract to consuming applications:

- `llama.cpp Web UI` on port `8080`
- `LocalAI` API on port `8081`
- `llama.cpp` server on port `8082`
- application-agnostic host mounts and runtime wiring

This repo owns how the appliance runs on HLH. Consuming application repos own how they use it.