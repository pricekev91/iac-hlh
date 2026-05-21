resource "proxmox_virtual_environment_download_file" "ubuntu_cloud_image" {
  node_name                = var.node_name
  datastore_id             = var.iso_datastore_id
  content_type             = "iso"
  file_name                = var.ubuntu_image_file_name
  url                      = var.ubuntu_image_url
}

resource "proxmox_virtual_environment_vm" "ai_vm" {
  node_name   = var.node_name
  vm_id       = var.vm_id
  name        = var.name
  description = var.description
  tags        = var.tags

  on_boot = true
  started = true

  machine = "q35"

  cpu {
    cores = var.cpu_cores
    type  = "host"
  }

  memory {
    dedicated = var.memory_mb
  }

  network_device {
    bridge = var.bridge
    model  = "virtio"
  }

  agent {
    enabled = true
  }

  operating_system {
    type = "l26"
  }

  initialization {
    user_account {
      username = var.ci_user
      keys     = [var.ci_ssh_public_key]
    }

    ip_config {
      ipv4 {
        address = var.network_mode == "dhcp" ? "dhcp" : var.ipv4_cidr
        gateway = var.network_mode == "dhcp" ? null : var.ipv4_gateway
      }
    }

    dns {
      servers = var.dns_servers
    }
  }

  disk {
    datastore_id = var.disk_datastore_id
    interface    = "scsi0"
    size         = var.disk_size_gb
    file_id      = proxmox_virtual_environment_download_file.ubuntu_cloud_image.id
    iothread     = true
    discard      = "on"
  }

  serial_device {}

  lifecycle {
    precondition {
      condition     = var.network_mode == "dhcp" || (var.ipv4_cidr != null && var.ipv4_gateway != null)
      error_message = "When network_mode is static, both ipv4_cidr and ipv4_gateway are required."
    }
  }
}
