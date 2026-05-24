variable "pm_api_url" {
  description = "Proxmox API URL"
  type        = string
}

variable "pm_api_token_id" {
  description = "Proxmox API Token ID"
  type        = string
}

variable "pm_api_token_secret" {
  description = "Proxmox API Token Secret"
  type        = string
  sensitive   = true
}

variable "target_node" {
  description = "Proxmox node name (e.g., 'hlh')"
  type        = string
}

variable "hostname" {
  description = "Hostname for the LXC container"
  type        = string
}

variable "ostemplate" {
  description = "LXC OS template (e.g., local:vztmpl/ubuntu-22.04-standard_latest.tar.zst)"
  type        = string
}

variable "vmid" {
  description = "VMID for the LXC container"
  type        = number
}

variable "cores" {
  description = "Number of vCPUs"
  type        = number
}

variable "memory" {
  description = "Memory in MB"
  type        = number
}

variable "bridge" {
  description = "Network bridge (e.g., 'vmbr0')"
  type        = string
}
