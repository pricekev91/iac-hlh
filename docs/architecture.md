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
- in-container provisioning for LocalAI with its built-in llama-cpp gRPC backend
- LocalAI owns model loading, inference, and the OpenAI-compatible API
- per-model YAML configs in `/srv/ai/models/` expose full llama.cpp flags (context, cache type, flash attention, mlock, threads, etc.)
- nginx on port `8080` proxies the LocalAI UI and API
- host-side AMD iGPU rebinding workflow for HLH when Proxmox is still binding the device to `vfio-pci`

Out of scope for this slice:

- standalone `llama-server` (removed; LocalAI's llama-cpp backend replaces it)
- application-specific Docker stacks
- orchestrator and agents LXCs

## Appliance Contract

The shared appliance presents a stable local contract to consuming applications:

- `LocalAI` UI and API on port `8080` (via nginx proxy) and port `8081` (direct)
- OpenAI-compatible API at `http://192.168.6.252:8081/v1/`
- application-agnostic host mounts and runtime wiring

Model configuration is fully declarative: each GGUF model in `/srv/ai/models/` has a matching `.yaml` config that controls all inference parameters. No SSH required to change model flags — edit the YAML and restart LocalAI.

This repo owns how the appliance runs on HLH. Consuming application repos own how they use it.