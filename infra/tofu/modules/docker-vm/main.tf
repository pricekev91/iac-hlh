resource "proxmox_virtual_environment_download_file" "ubuntu_cloud_image" {
  node_name               = var.node_name
  datastore_id            = var.iso_datastore_id
  content_type            = "iso"
  file_name               = var.ubuntu_image_file_name
  url                     = var.ubuntu_image_url
}

resource "proxmox_virtual_environment_vm" "docker_host" {
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
    type  = "x86-64-v2-AES"
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
        address = var.ipv4_cidr
        gateway = var.ipv4_gateway
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
}
