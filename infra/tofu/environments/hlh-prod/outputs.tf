output "docker_vm_id" {
  value       = module.docker_vm.vm_id
  description = "Docker VMID created in Proxmox."
}

output "docker_vm_name" {
  value       = module.docker_vm.name
  description = "Docker VM name."
}

output "docker_vm_ipv4" {
  value       = module.docker_vm.ipv4
  description = "Docker VM IPv4 CIDR contract."
}

output "ai_vm_id" {
  value       = module.ai_vm.vm_id
  description = "AI VMID created in Proxmox."
}

output "ai_vm_name" {
  value       = module.ai_vm.name
  description = "AI VM name."
}

output "ai_vm_ipv4" {
  value       = module.ai_vm.ipv4
  description = "AI VM IPv4 CIDR contract."
}
