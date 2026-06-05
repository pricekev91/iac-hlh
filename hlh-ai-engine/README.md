# hlh-ai-engine

Infrastructure-as-Code for the HLH shared AI inference engine. Deploys a GPU-accelerated
llama.cpp runtime as a Proxmox LXC container with ROCm support.

## Executive Summary

This repository deploys and configures the **engine** LXC on the HLH Proxmox host. The
engine is a shared AI inference service consumed by all application repos (TrashPanda,
BrickCipher, VoxChimera).

- LXC 101, hostname `hlh-ai-engine`, IP `192.168.1.12`
- ROCm 7.2.3 with AMD RDNA 3 890M iGPU (gfx1150)
- llama.cpp backend serving OpenAI-compatible API on port 8080
- Model storage on `RaidZ1-6TB` ZFS pool

## Repository Boundary

**Owns:**
- LXC lifecycle (create, configure, start) on Proxmox
- GPU passthrough configuration for ROCm
- Model storage mount wiring
- In-container ROCm and llama.cpp installation

**Does not own:**
- Proxmox host configuration (that is `iac-hlh`)
- Application logic or dashboard code (that is `TrashPanda`, `BrickCipher`, etc.)
- AI VM ROCm migration (planned as separate path in `iac-hlh`)

## Quick Start

Deploy the AI engine LXC on the Proxmox host:

```bash
./deploy-hlh-ai-engine.sh
```

Configure an existing LXC:

```bash
./configure-hlh-ai-engine.sh
```

Switch loaded models:

```bash
# Run inside LXC after deployment
./switch-model.sh <model-gguf-filename>
```

## Deployment Model

Deployment and configuration are separate phases:

1. **Provisioning**: `deploy-hlh-ai-engine.sh` creates the LXC, wires GPU passthrough,
   and pushes the in-container bootstrap script.
2. **Configuration**: `ansible/playbooks/hlh-ai-engine.yml` configures services,
   runtime, and networking inside the container.

## OpenTofu Module

For programmatic LXC creation via OpenTofu:

```hcl
module "hlh_ai_engine" {
  source = "./opentofu"
  pm_api_url         = var.pm_api_url
  pm_api_token_id    = var.pm_api_token_id
  pm_api_token_secret = var.pm_api_token_secret
  target_node        = var.target_node
  hostname           = "hlh-ai-engine"
  vmid               = 101
  # ... other variables
}
```

## Runtime Contract

| Item | Value |
|------|-------|
| API endpoint | `http://192.168.1.12:8080` |
| Web UI | `http://192.168.1.12:80` |
| OpenAI-compatible base | `http://192.168.1.12:8080/v1/` |
| Model storage | `/srv/ai/models` (host mount) |
| GPU device | `/dev/dri` + `/dev/kfd` bind-mount |
| Default model | Q4_K_M (35B, MTP variant) |

## Repository Layout

```
hlh-ai-engine/
├── deploy-hlh-ai-engine.sh          # LXC creation + GPU passthrough + bootstrap
├── configure-hlh-ai-engine.sh       # In-container configuration
├── ansible/
│   ├── inventories/hlh-ai-engine.yml
│   ├── playbooks/hlh-ai-engine.yml
│   └── files/configure-ai-engine-inside-lxc.sh
├── opentofu/
│   ├── main.tf
│   └── variables.tf
├── amdgpu-install_6.4.60400-1_all.deb  # ROCm installer (included)
├── 00_BACKLOG.md
├── 10_ACTIVE.md
├── 90_DONE.md
└── 98_README.md
```

## Governance

This repo is a submodule of `iac-hlh`. Deployments consume pinned commits for
deterministic results. See the HLH Agile Design Handbook for the full architecture
and dependency map.
