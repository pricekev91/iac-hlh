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
