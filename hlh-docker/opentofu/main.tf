terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.66.0"
    }
  }
}

provider "proxmox" {
  endpoint  = var.pm_endpoint
  api_token = var.pm_api_token != "" ? var.pm_api_token : null
  username  = var.pm_api_token == "" ? var.pm_username : null
  password  = var.pm_api_token == "" ? var.pm_password : null
  insecure  = true

  # SSH ticket auth — uses local SSH key to get an API ticket from Proxmox.
  # Requires ssh identity_file pointing to a valid key for root@prox01.
  ssh {
    agent          = true
    username       = "root"
    identity_file  = var.pm_ssh_identity
    port           = 22
    known_hosts_file = "~/.ssh/known_hosts"
  }
}

# --- HLH-Docker LXC (vmid 102) ---
# Unprivileged LXC running Docker, Dockhand, LazyDocker
# See ADR-001.md for architecture decisions

resource "proxmox_virtual_environment_container" "hlh_docker" {
  node_name = var.target_node
  vm_id     = 102

  unprivileged = true
  started      = true

  features {
    nesting = true
  }

  initialization {
    hostname = "hlh-docker"

    ip_config {
      ipv4 {
        address = "192.168.1.13/24"
        gateway = "192.168.1.1"
      }
    }

    user_account {
      password = var.lxc_root_password != "" ? var.lxc_root_password : null
    }
  }

  cpu {
    cores = var.cores
  }

  memory {
    dedicated = var.memory
    swap      = 1024
  }

  disk {
    datastore_id = "RaidZ1-6TB"
    size         = 32
  }

  network_interface {
    name    = "eth0"
    bridge  = "vmbr0"
    vlan_id = var.network_tag > 0 ? var.network_tag : null
  }

  operating_system {
    template_file_id = var.ostemplate
    type             = "ubuntu"
  }

  # Persistent ZFS bind-mounts — data survives LXC destroy/recreate.
  # Datasets are mounted via /mnt/RaidZ1-6TB on the Proxmox host.
  mount_point {
    volume = "/mnt/RaidZ1-6TB/hlh-docker/docker-data"
    path   = "/var/lib/docker"
    shared = true
  }

  mount_point {
    volume = "/mnt/RaidZ1-6TB/hlh-docker/dockhand-data"
    path   = "/srv/dockhand/data"
    shared = true
  }
}

output "lxc_vmid" {
  description = "VMID of the hlh-docker container"
  value       = proxmox_virtual_environment_container.hlh_docker.vm_id
}

output "lxc_hostname" {
  description = "Hostname of the hlh-docker container"
  value       = proxmox_virtual_environment_container.hlh_docker.initialization[0].hostname
}
