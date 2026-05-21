variable "node_name" {
  description = "Proxmox node that will host the AI VM."
  type        = string
}

variable "vm_id" {
  description = "Unique VMID in Proxmox."
  type        = number
}

variable "name" {
  description = "Proxmox VM name."
  type        = string
}

variable "description" {
  description = "Optional VM description."
  type        = string
  default     = "HLH AI VM"
}

variable "tags" {
  description = "Proxmox tags for the VM."
  type        = list(string)
  default     = ["hlh", "ai", "rocm", "vm"]
}

variable "cpu_cores" {
  description = "Number of vCPU cores."
  type        = number
  default     = 12
}

variable "memory_mb" {
  description = "VM memory in MB."
  type        = number
  default     = 65536
}

variable "disk_datastore_id" {
  description = "Proxmox datastore ID for the VM disk."
  type        = string
}

variable "disk_size_gb" {
  description = "Primary disk size in GB."
  type        = number
  default     = 250
}

variable "bridge" {
  description = "Network bridge for VM NIC."
  type        = string
  default     = "vmbr0"
}

variable "ipv4_cidr" {
  description = "Static IPv4 address in CIDR format."
  type        = string
}

variable "ipv4_gateway" {
  description = "Default IPv4 gateway."
  type        = string
}

variable "dns_servers" {
  description = "DNS servers for cloud-init guest setup."
  type        = list(string)
  default     = ["1.1.1.1", "8.8.8.8"]
}

variable "ci_user" {
  description = "Cloud-init default user."
  type        = string
  default     = "ops"
}

variable "ci_ssh_public_key" {
  description = "SSH public key for cloud-init user."
  type        = string
}

variable "ubuntu_image_file_name" {
  description = "Filename for the downloaded Ubuntu cloud image."
  type        = string
  default     = "ubuntu-24.04-server-cloudimg-amd64.img"
}

variable "ubuntu_image_url" {
  description = "URL for the Ubuntu cloud image."
  type        = string
  default     = "https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img"
}

variable "iso_datastore_id" {
  description = "Proxmox datastore ID where cloud image is stored."
  type        = string
}
