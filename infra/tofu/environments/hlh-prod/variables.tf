variable "proxmox_endpoint" {
  description = "Proxmox API endpoint, e.g. https://192.168.6.10:8006/api2/json."
  type        = string
}

variable "proxmox_username" {
  description = "Proxmox API username, e.g. root@pam or terraform@pve."
  type        = string
}

variable "proxmox_password" {
  description = "Proxmox API password."
  type        = string
  sensitive   = true
}

variable "proxmox_insecure_tls" {
  description = "Allow insecure TLS for Proxmox API."
  type        = bool
  default     = false
}

variable "proxmox_node_name" {
  description = "Proxmox node where Docker VM should run."
  type        = string
  default     = "prox01"
}

variable "docker_vm_id" {
  description = "VMID for Docker host VM."
  type        = number
}

variable "docker_vm_name" {
  description = "Name for Docker host VM."
  type        = string
  default     = "docker-host"
}

variable "docker_vm_ipv4_cidr" {
  description = "Static IP CIDR for Docker host VM."
  type        = string
}

variable "docker_vm_gateway" {
  description = "Gateway for Docker host VM."
  type        = string
}

variable "docker_vm_bridge" {
  description = "Bridge for Docker host VM NIC."
  type        = string
  default     = "vmbr0"
}

variable "docker_vm_cpu_cores" {
  description = "vCPU cores for Docker host VM."
  type        = number
  default     = 4
}

variable "docker_vm_memory_mb" {
  description = "Memory in MB for Docker host VM."
  type        = number
  default     = 8192
}

variable "docker_vm_disk_size_gb" {
  description = "Primary disk size in GB for Docker host VM."
  type        = number
  default     = 120
}

variable "proxmox_disk_datastore_id" {
  description = "Datastore ID for VM disks."
  type        = string
  default     = "local-zfs"
}

variable "proxmox_iso_datastore_id" {
  description = "Datastore ID for ISO/cloud images."
  type        = string
  default     = "local"
}

variable "docker_vm_ci_user" {
  description = "Cloud-init username for Docker host VM."
  type        = string
  default     = "ops"
}

variable "docker_vm_ci_ssh_public_key" {
  description = "SSH public key for cloud-init user."
  type        = string
}

variable "docker_vm_dns_servers" {
  description = "DNS servers for Docker host VM."
  type        = list(string)
  default     = ["1.1.1.1", "8.8.8.8"]
}
