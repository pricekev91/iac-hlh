output "vm_id" {
  description = "Proxmox VMID for the AI VM."
  value       = proxmox_virtual_environment_vm.ai_vm.vm_id
}

output "name" {
  description = "AI VM name."
  value       = proxmox_virtual_environment_vm.ai_vm.name
}

output "ipv4" {
  description = "Configured static IPv4 CIDR."
  value       = var.ipv4_cidr
}

output "node_name" {
  description = "Proxmox node name."
  value       = proxmox_virtual_environment_vm.ai_vm.node_name
}
