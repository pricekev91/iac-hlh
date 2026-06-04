# DONE

This is what is already implemented and verified in this repository.

## Orchestrator Structure

- Flat orchestrator with pinned submodules for deterministic deployments
- Submodules: `hlh-ai-engine` (AI inference LXC), `hlh-docker` (Docker container host)
- Submodule sync and update in `deploy.sh`
- Component revisions pinned at specific commits

## Host Bootstrap

- `bootstrap/zfsbootstrap.sh`: ZFS pool creation for Proxmox host
  - Creates `Raid0-2TB` (striped) on `/dev/sda`, `/dev/sdb`
  - Creates `RaidZ1-6TB` (raidz1) on `/dev/sdc`, `/dev/sdd`, `/dev/sde`
  - Protects system NVMe (`/dev/nvme0n1`)
  - Idempotent with retry logic (3 attempts)

- `bootstrap/proxmox-enable-amd-igpu-host.bash`: AMD iGPU host binding
  - Configures `vfio-pci` and `amdgpu` driver binding
  - Required for `/dev/dri` device passthrough to LXC

- `bootstrap/proxmox-zfs-storage.bash`: ZFS storage configuration
  - Creates ZFS pools on specified disks
  - Validates no overlap with system disk

## Deployment Pipeline

- `deploy.sh`: 5-stage orchestration entrypoint
  1. Initialize pinned submodules (sync + update)
  2. Run host bootstrap (ZFS storage)
  3. Deploy hlh-ai-engine (submodule)
  4. Deploy hlh-docker (submodule)
  5. Complete with deterministic version report

- Pre-flight checks: executable validation for all scripts
- Deterministic component versions from pinned submodule commits

## AI Engine (via hlh-ai-engine submodule)

- Privileged LXC 101 with hostname `hlh-ai-engine`
- AMD iGPU passthrough via `/dev/dri` and `/dev/kfd`
- ROCm 7.2.3 with LocalAI + llama.cpp backend
- nginx reverse proxy for AI API on port 8080
- Model storage on `RaidZ1-6TB` ZFS pool

## Docker Host (via hlh-docker submodule)

- Unprivileged LXC 102 with hostname `hlh-docker`
- Docker Engine + Dockhand (GUI) + LazyDocker (TUI)
- VLAN-aware networking for future per-app IP assignment
- ZFS bind-mounts for persistent data

## Ansible Roles

- `roles/docker_host/`: Docker host provisioning
  - Docker CE installation
  - Dockhand container deployment
  - Dockhand systemd service
  - LazyDocker installation

## Documentation

- `docs/architecture.md`: Full layered architecture (6 layers)
- `docs/ai-vm-rocm-migration.md`: AI VM ROCm migration plan
- `docs/amd-igpu-host.md`: Host GPU binding preconditions
- `docs/hlh-host-contract.md`: HLH host contract
- `docs/hybrid-iac-migration.md`: Hybrid IaC migration plan
- `docs/trashpanda-app-contract.md`: TrashPanda application contract

## Services

- `services/openspeedtest/`: Docker Compose for OpenSpeedTest
- `services/uptime-kuma/`: Docker Compose for Uptime Kuma
- `services/README.md`: Service deployment instructions

## Repository Layout

```
iac-hlh/
├── deploy.sh                    # 5-stage orchestrator entrypoint
├── bootstrap/
│   ├── zfsbootstrap.sh          # ZFS pool creation
│   ├── proxmox-enable-amd-igpu-host.bash
│   ├── proxmox-zfs-storage.bash
│   └── README.md
├── roles/
│   └── docker_host/
│       ├── defaults/main.yml
│       ├── handlers/main.yml
│       ├── tasks/main.yml
│       └── templates/
├── services/
│   ├── openspeedtest/docker-compose.yml
│   ├── uptime-kuma/docker-compose.yml
│   └── README.md
├── docs/
│   ├── architecture.md          # Full layered architecture
│   ├── ai-vm-rocm-migration.md
│   ├── amd-igpu-host.md
│   ├── hlh-host-contract.md
│   ├── hybrid-iac-migration.md
│   └── trashpanda-app-contract.md
├── .gitmodules                  # Submodule pins
├── .gitignore
├── 00_BACKLOG.md
├── 10_ACTIVE.md
├── 90_DONE.md
└── 98_README.md
```
