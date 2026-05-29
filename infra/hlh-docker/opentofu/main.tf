terraform {
  required_providers {
    proxmox = {
      source  = "Telmate/proxmox"
      version = ">= 2.11.0"
    }
  }
}

provider "proxmox" {
  pm_api_url      = var.pm_api_url
  pm_api_token_id = var.pm_api_token_id
  pm_api_token_secret = var.pm_api_token_secret
  pm_tls_insecure = true
}

# --- HLH-Docker LXC (vmid 102) ---
# Unprivileged LXC running Docker, Dockhand, LazyDocker
# See ADR-001.md for architecture decisions

resource "proxmox_lxc" "hlh_docker" {
  target_node = var.target_node
  hostname    = "hlh-docker"
  ostemplate  = var.ostemplate
  vmid        = 102
  cores       = var.cores
  memory      = var.memory
  swap        = 1024
  rootfs      = "RAIDZ1-6TB:32"

  unprivileged = true
  start        = true

  features {
    nesting  = true
    keyctl   = true
    fuse     = true
  }

  network {
    name   = "eth0"
    bridge = "vmbr0"
    ipv4   = "dhcp"
    tag    = var.network_tag
  }

  # Unprivileged LXC: requires password set for root
  passwords {
    root = var.lxc_root_password
  }

  # ZFS mounts for persistent data
  # /srv/ct/hlh-docker (docker data directory)
  # /srv/ct/openspeedtest (reserved for future app)
  unmounted = "1"

  mounts {
    volume    = "RAIDZ1-6TB"
    mountpoint = "mp0"
    mp        = "/srv/ct/hlh-docker"
    size      = "64G"
  }

  mounts {
    volume    = "RAIDZ1-6TB"
    mountpoint = "mp1"
    mp        = "/srv/ct/openspeedtest"
    size      = "32G"
  }

  # VLAN-aware bridge with optional tag for future segmentation
  # Currently untagged (tag = 0 = off), ready for VLAN tagging later
}

output "lxc_vmid" {
  description = "VMID of the hlh-docker container"
  value       = proxmox_lxc.hlh_docker.vmid
}

output "lxc_hostname" {
  description = "Hostname of the hlh-docker container"
  value       = proxmox_lxc.hlh_docker.hostname
}
