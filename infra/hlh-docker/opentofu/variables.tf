variable "pm_api_url" {
  description = "Proxmox API URL (e.g., 'https://192.168.1.10:8006/api2/json')"
  type        = string
}

variable "pm_api_token_id" {
  description = "Proxmox API Token ID (e.g., 'root@pve!tofu-hlh-docker')"
  type        = string
}

variable "pm_api_token_secret" {
  description = "Proxmox API Token Secret"
  type        = string
  sensitive   = true
}

variable "target_node" {
  description = "Proxmox node name"
  type        = string
  default     = "prox01"
}

variable "ostemplate" {
  description = "LXC OS template (e.g., 'local:vztmpl/ubuntu-22.04-standard_latest.tar.zst')"
  type        = string
}

variable "cores" {
  description = "Number of vCPUs for hlh-docker LXC"
  type        = number
  default     = 4
}

variable "memory" {
  description = "Memory in MB for hlh-docker LXC"
  type        = number
  default     = 4096
}

variable "network_tag" {
  description = "VLAN tag for the LXC bridge interface (0 = untagged/current, >0 = future VLAN)"
  type        = number
  default     = 0
}

variable "lxc_root_password" {
  description = "Root password for the unprivileged LXC (required for container login)"
  type        = string
  sensitive   = true
}

variable "ansible_ssh_user" {
  description = "SSH user for Ansible provisioning after LXC creation"
  type        = string
  default     = "root"
}
