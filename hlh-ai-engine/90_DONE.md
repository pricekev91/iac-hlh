# DONE

This is what is already implemented and verified in this repository.

## LXC Deployment

- Direct Proxmox LXC creation via `deploy-hlh-ai-engine.sh` (no OpenTofu required for initial setup)
- Privileged LXC 101 with hostname `hlh-ai-engine`
- 48 GiB RAM, 12 cores, 64 GiB rootfs on `RaidZ1-6TB` pool
- Static IP assignment: `192.168.1.12/24`
- Nesting and keyctl features enabled

## GPU Passthrough

- AMD iGPU `/dev/dri` bind-mount for ROCm device access
- AMD iGPU `/dev/kfd` bind-mount for HIP/ROCm compute
- cgroup2 device allow rules: `c 226:* rwm`, `c 511:0 rwm`
- GPU detected as gfx1150 (Radeon 890M, RDNA 3)

## ROCm / Runtime

- ROCm 7.2.3 installed (amdgpu-install package included in repo)
- llama.cpp backend for inference
- llama-server default model: Q4_K_M (35B parameter, Qwen3.6-35B-A3B-MTP variant)
- Model download skipped when `/srv/ai/models` mount already contains GGUF files
- MTP (Mixture of Parameter Transfer) auto-detect in switch-model.sh

## Model Management

- switch-model.sh with MTP auto-detect (v1.3.0)
- Model storage: host `/srv/ai/models` bind-mounted to LXC `/srv/ai/models`
- Default model pinned to Q4_K_M variant

## Networking

- Web UI served on port 80 inside LXC
- API proxy on port 8080 (nginx reverse proxy)
- OpenAI-compatible API at port 8080/v1/

## Ansible Configuration

- Ansible inventory: `ansible/inventories/hlh-ai-engine.yml`
- Playbook: `ansible/playbooks/hlh-ai-engine.yml`
- Bootstrap script: `ansible/files/configure-ai-engine-inside-lxc.sh`
- SSH key-based auth: `~/.ssh/id_ed25519`

## OpenTofu Provisioning

- Proxmox provider: `telmate/proxmox >= 2.7.2`
- LXC resource with GPU passthrough, network, and storage configuration
- Variables for API URL, token auth, network, and storage

## Configuration Scripts

- `deploy-hlh-ai-engine.sh` - Full LXC creation, GPU passthrough, bootstrap
- `configure-hlh-ai-engine.sh` - In-container configuration
