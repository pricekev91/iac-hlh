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
4. Benchmark and validate parity or superiority (manual)
5. Switch traffic to AI VM endpoint (manual)
6. Decommission LXC after burn-in (manual)

## Commands

Plan:
./scripts/ai-vm-plan.bash

Apply:
./scripts/ai-vm-apply.bash

Steps 4-6 are manual by policy in this repo.

## Notes

- Default AI backend is llama.cpp for homelab use.
- vLLM is optional and disabled by default.
- GPU passthrough playbook expects PCI IDs in ansible/playbooks/proxmox-gpu-passthrough.yml.
- Benchmark, endpoint cutover, and LXC decommission are operator-run manual actions.
- AI VM networking supports `dhcp` or `static` via `ai_vm_network_mode` in OpenTofu variables.
- When using DHCP, discover the assigned AI VM IPv4 first and update ansible/inventory/hlh-prod.yml before running step 3.

## Manual Operator Checklist (Steps 4-6)

Use this checklist after steps 1-3 complete.

### Step 4: Benchmark and Validate (Manual)

- [ ] Confirm ROCm device visibility in AI VM (`rocminfo`, `rocm-smi`).
- [ ] Confirm llama.cpp HIP runtime starts and serves requests.
- [ ] Run representative prompt set against legacy LXC and AI VM.
- [ ] Record token throughput, latency, and error rate for both paths.
- [ ] Confirm AI VM is at parity or better before cutover.

Evidence to capture:

- [ ] benchmark command lines
- [ ] benchmark raw outputs
- [ ] summary comparison table (LXC vs AI VM)

Go/No-Go gate:

- [ ] Go only if AI VM meets or exceeds agreed baseline.

### Step 5: Switch Traffic to AI VM Endpoint (Manual)

- [ ] Update endpoint mapping/DNS/reverse-proxy target to AI VM.
- [ ] Run health checks from at least one consumer host.
- [ ] Execute smoke prompts through the production route.
- [ ] Monitor logs/errors for a burn-in window.

Evidence to capture:

- [ ] old endpoint target
- [ ] new endpoint target
- [ ] timestamp of cutover
- [ ] post-cutover smoke test results

Rollback criteria:

- [ ] Revert endpoint target immediately if error rate or latency regresses.

### Step 6: Decommission Legacy LXC (Manual)

- [ ] Confirm burn-in window completed without regression.
- [ ] Snapshot/export any required LXC state for retention.
- [ ] Stop legacy LXC.
- [ ] Destroy legacy LXC only after retention checks pass.

Evidence to capture:

- [ ] retention/snapshot reference
- [ ] stop timestamp
- [ ] destroy timestamp

Final acceptance:

- [ ] AI VM is the only active production inference path.
