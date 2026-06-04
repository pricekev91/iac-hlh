# BACKLOG

Items for future implementation. These are human-entered ideas not yet reflected
in the codebase.

## Infrastructure

- Add AI VM ROCm migration to apply.bash (currently in docs/ai-vm-rocm-migration.md but not operational)
- Add Docker VM (vmid 103) for service stacks (openspeedtest, uptime-kuma) via OpenTofu
- Add LXC snapshot management for critical state preservation
- Add host health monitoring script (disk, GPU, memory, network)
- Add automated GPU driver update procedure
- Add Proxmox cluster expansion playbook (multi-host support)

## Submodule Management

- Add submodule version pinning verification in deploy.sh
- Add automated submodule bump CI check
- Add submodule status report command

## Service Orchestration

- Add deploy.sh stage 6: service stacks (openspeedtest, uptime-kuma)
- Add service health verification after deployment
- Add service rollback procedure

## Ansible

- Add docker_host role to configure Docker VM (separate from hlh-docker repo)
- Add ansible-lint and pre-commit hooks
- Add playbook for AI VM ROCm migration provisioning
- Add inventory management for multi-environment (dev, staging, prod)

## Observability

- Add Prometheus + Grafana for Proxmox host monitoring
- Add container health check integration
- Add structured logging for deploy.sh
- Add API endpoint health monitoring for AI engine

## Documentation

- Add architecture diagram update for AI VM migration path
- Add runbook for common failure scenarios
- Add disaster recovery procedure
- Add cost tracking for infrastructure resources

## Security

- Add secret management via HashiCorp Vault or similar
- Add network segmentation for application repos
- Add LXC firewall rules (pct firewall)
- Add SSH key rotation procedure
