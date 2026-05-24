# hlh-docker

This folder contains configuration, automation, and documentation for the HLH Docker host VM (Proxmox LXC).

- **VMID:** 101
- **Hostname:** hlh-ai-engine
- **OS:** Ubuntu (LXC template)
- **CPU:** 4 vCPU
- **RAM:** 4GB
- **Disk:** 32GB (on RAIDZ1-6TB pool)
- **Privileged:** Yes (for Docker compatibility)
- **Features:** Nesting, keyctl enabled
- **Network:** DHCP, bridge=vmbr0

Provision using OpenTofu config in `../infra-docker/opentofu/` and the deploy script in `../infra-docker/deploy-docker-vm.sh`.
