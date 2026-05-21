# docker-vm module

Creates a Proxmox VM intended to host Docker service stacks for HLH.

## Inputs

Required:
- `node_name`
- `vm_id`
- `name`
- `disk_datastore_id`
- `iso_datastore_id`
- `ipv4_cidr`
- `ipv4_gateway`
- `ci_ssh_public_key`

Optional inputs expose sizing, tags, DNS, and cloud image source.

## Notes

- This module only creates the VM base contract.
- Guest package setup is handled by Ansible.
- Service deployment is handled via Docker Compose stacks in `services/`.
