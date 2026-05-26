terraform {
  required_providers {
    proxmox = {
      source  = "Telmate/proxmox"
      version = ">= 2.9.11"
    }
  }
}

provider "proxmox" {
  # These should be set via environment variables or a .tfvars file
  pm_api_url      = var.pm_api_url
  pm_api_token_id = var.pm_api_token_id
  pm_api_token_secret = var.pm_api_token_secret
  pm_tls_insecure = true
}

resource "proxmox_lxc" "docker_host" {
  target_node = var.target_node
  hostname    = var.hostname
  ostemplate  = var.ostemplate
  vmid        = var.vmid
  cores       = var.cores
  memory      = var.memory
  rootfs      = "raidz1-6tb:32"
  features {
    nesting = true
    keyctl  = true
  }
  unprivileged = false
  start        = true
  network {
    name   = "eth0"
    bridge = var.bridge
    ip     = "dhcp"
  }
}
