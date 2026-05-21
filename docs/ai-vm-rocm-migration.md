# AI VM ROCm Migration

This migration keeps the current AI Engine LXC running while building a parallel AI VM.

## Prime Directive

Everything is modular. Runtime and orchestration provider changes must happen in one place, not per service stack.

- Runtime provider switch: ansible/group_vars/all.yml -> container_runtime_provider
- Orchestrator provider switch: ansible/group_vars/all.yml -> service_orchestrator_provider
- AI backend switch: ansible/roles/ai_rocm_engine/defaults/main.yml -> ai_backend_provider

## Migration Phases

1. Build AI VM in parallel
2. Attach AMD GPU via passthrough
3. Configure ROCm and AI engines with Ansible
4. Benchmark and validate parity or superiority
5. Switch traffic to AI VM endpoint
6. Decommission LXC after burn-in

## Commands

Plan:
./scripts/ai-vm-plan.bash

Apply:
./scripts/ai-vm-apply.bash

Cutover:
./scripts/ai-vm-cutover.bash

Decommission legacy LXC (destructive):
./scripts/ai-vm-decommission-lxc.bash --confirm

## Notes

- Default AI backend is llama.cpp for homelab use.
- vLLM is optional and disabled by default.
- GPU passthrough playbook expects PCI IDs in ansible/playbooks/proxmox-gpu-passthrough.yml.
- Benchmark artifact is written to /var/log/ai-benchmark-latest.txt on the AI VM.
