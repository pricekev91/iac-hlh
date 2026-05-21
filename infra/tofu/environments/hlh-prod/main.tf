module "docker_vm" {
  source = "../../modules/docker-vm"

  node_name         = var.proxmox_node_name
  vm_id             = var.docker_vm_id
  name              = var.docker_vm_name
  description       = "HLH Docker host for utility stacks"
  tags              = ["hlh", "docker", "services"]
  cpu_cores         = var.docker_vm_cpu_cores
  memory_mb         = var.docker_vm_memory_mb
  disk_datastore_id = var.proxmox_disk_datastore_id
  disk_size_gb      = var.docker_vm_disk_size_gb
  bridge            = var.docker_vm_bridge
  ipv4_cidr         = var.docker_vm_ipv4_cidr
  ipv4_gateway      = var.docker_vm_gateway
  dns_servers       = var.docker_vm_dns_servers
  ci_user           = var.docker_vm_ci_user
  ci_ssh_public_key = var.docker_vm_ci_ssh_public_key
  iso_datastore_id  = var.proxmox_iso_datastore_id
}
