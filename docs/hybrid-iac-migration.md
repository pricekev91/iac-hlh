# Hybrid IaC Migration (Bash + OpenTofu + Ansible)

This document defines the first migration slice while keeping the existing AI engine LXC path unchanged.

## Scope of this phase

- Keep `apply.bash` and engine provisioning stable.
- Add OpenTofu module for Docker VM lifecycle on Proxmox.
- Add Ansible role for guest configuration (Docker, compose plugin, lazydocker).
- Add first Docker service stacks: OpenSpeedTest and Uptime Kuma.
- Use thin Bash wrappers to orchestrate `tofu` and `ansible` commands.

## New control paths

- OpenTofu environment: `infra/tofu/environments/hlh-prod`
- OpenTofu module: `infra/tofu/modules/docker-vm`
- Ansible playbook: `ansible/playbooks/docker-host.yml`
- Ansible playbook: `ansible/playbooks/deploy-services.yml`
- Services: `services/openspeedtest`, `services/uptime-kuma`
- Wrappers: `scripts/hybrid-plan.bash`, `scripts/hybrid-apply.bash`, `scripts/hybrid-status.bash`

## Prerequisites

- `tofu` installed on operator host
- `ansible` installed on operator host
- Proxmox API credentials with VM create permissions
- SSH access from operator host to Docker VM cloud-init user

## First-time setup

1. Copy `infra/tofu/environments/hlh-prod/terraform.tfvars.example` to `terraform.tfvars`.
2. Set secure Proxmox credentials and SSH public key in `terraform.tfvars`.
3. Update `ansible/inventory/hlh-prod.yml` host/IP if needed.

## Plan and apply

```bash
./scripts/hybrid-plan.bash
./scripts/hybrid-apply.bash
./scripts/hybrid-status.bash
```

`hybrid-apply.bash` performs:

1. OpenTofu apply for Docker VM lifecycle.
2. Ansible guest configuration (`docker-host.yml`).
3. Ansible stack deployment (`deploy-services.yml`).

## Service endpoints (default)

- OpenSpeedTest: `http://<docker-host-ip>:3001`
- Uptime Kuma: `http://<docker-host-ip>:3003`

## Next migration slices

- DNS stack as `services/dns/` on docker-vm
- Additional monitoring stacks
- Move any remaining imperative host scripts into module- or role-backed workflows
