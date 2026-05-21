output "vm_id" {
  description = "Proxmox VMID for the Docker host."
  value       = proxmox_virtual_environment_vm.docker_host.vm_id
}

output "name" {
  description = "VM name."
  value       = proxmox_virtual_environment_vm.docker_host.name
}

output "ipv4" {
  description = "Configured static IPv4 CIDR."
  value       = var.ipv4_cidr
}

output "node_name" {
  description = "Proxmox node name."
  value       = proxmox_virtual_environment_vm.docker_host.node_name
}
