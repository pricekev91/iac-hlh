# ai-vm module

Creates a Proxmox VM intended to host ROCm and AI engines.

## Inputs

Required:
- node_name
- vm_id
- name
- disk_datastore_id
- iso_datastore_id
- ipv4_cidr
- ipv4_gateway
- ci_ssh_public_key

Optional inputs expose sizing, tags, DNS, and cloud image source.

## Notes

- This module creates only the VM and cloud-init baseline.
- GPU passthrough is configured by host-side wrapper script using qm set.
- Guest package setup is handled by Ansible roles.
