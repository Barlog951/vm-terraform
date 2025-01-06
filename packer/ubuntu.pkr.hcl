################################################################################
# Packer Configuration for Ubuntu Template
# Filename: ubuntu.pkr.hcl
################################################################################

packer {
  required_plugins {
    vsphere = {
      source  = "github.com/hashicorp/vsphere"
      version = ">= 1.4.2"
    }
  }
}

# -------------------------------------------------------------------
# Variables
# -------------------------------------------------------------------
variable "vsphere_server" {
  type        = string
  description = "vSphere server hostname or IP"
}

variable "vsphere_user" {
  type        = string
  description = "vSphere username"
}

variable "vsphere_password" {
  type        = string
  sensitive   = true
  description = "vSphere password"
}

variable "vsphere_datacenter" {
  type        = string
  description = "vSphere datacenter name"
}

variable "vsphere_cluster" {
  type        = string
  description = "vSphere cluster name"
}

variable "vsphere_datastore" {
  type        = string
  description = "vSphere datastore name"
}

variable "vsphere_network" {
  type        = string
  description = "vSphere network name"
}

variable "template_name" {
  type        = string
  default     = "ubuntu-template"
  description = "Name of the template to be created"
}

variable "template_cpu_num" {
  type        = number
  default     = 2
  description = "Number of CPUs for the template"
}

variable "template_mem_size" {
  type        = number
  default     = 2048
  description = "Memory size in MB for the template"
}

variable "template_disk_size" {
  type        = number
  default     = 50000  # 50GB
  description = "Disk size in MB for the template"
}

# Local variables for template configuration
locals {
  template_description = "Ubuntu Server 24.04 template built by Packer on ${formatdate("YYYY-MM-DD hh:mm ZZZ", timestamp())}"
  build_timestamp      = formatdate("YYYYMMDDhhmmss", timestamp())
  build_version        = formatdate("YYYY.MM", timestamp())
  ssh_username         = "barlog"
  http_directory       = "${path.root}/http"
}

# -------------------------------------------------------------------
# vSphere-ISO Builder
# -------------------------------------------------------------------
source "vsphere-iso" "ubuntu" {
  # vSphere connection settings
  vcenter_server      = var.vsphere_server
  username            = var.vsphere_user
  password            = var.vsphere_password
  insecure_connection = true
  ip_wait_timeout     = "60m"

  # vSphere location settings
  datacenter = var.vsphere_datacenter
  cluster    = var.vsphere_cluster
  datastore  = var.vsphere_datastore
  folder     = "templates"

  # VM Hardware settings
  vm_name              = var.template_name
  guest_os_type        = "ubuntu64Guest"
  CPUs                 = var.template_cpu_num
  RAM                  = var.template_mem_size
  RAM_reserve_all      = true
  disk_controller_type = ["pvscsi"]
  storage {
    disk_size             = var.template_disk_size
    disk_thin_provisioned = true
  }
  network_adapters {
    network      = var.vsphere_network
    network_card = "vmxnet3"
  }

  # ISO and boot settings (Ubuntu 24.04)
  iso_paths = [
    "[${var.vsphere_datastore}] iso/ubuntu-24.04.1-live-server-amd64.iso"
  ]

  # Autoinstall with NoCloud (for the initial OS install)
  cd_files = [
    "files/cloud-init/meta-data",
    "files/cloud-init/user-data"
  ]
  cd_label = "cidata"

  boot_order = "disk,cdrom"
  boot_wait  = "10s"
  boot_command = [
    "<wait>e<wait>",
    "<down><down><down><end>",
    " autoinstall ds=nocloud;s=/cdrom/",     # Needed for the initial install
    "<f10>"
  ]

  # SSH connection settings
  ssh_username           = local.ssh_username
  ssh_private_key_file   = "~/.ssh/id_ed25519"
  ssh_timeout            = "30m"
  ssh_handshake_attempts = 100

  # Convert directly to template after build
  convert_to_template = true
  notes               = local.template_description

  # Additional configuration
  remove_cdrom         = true
  tools_upgrade_policy = true
  vm_version           = "19"
}

# -------------------------------------------------------------------
# Build Block with Provisioners
# -------------------------------------------------------------------
build {
  name    = "ubuntu-server"
  sources = ["source.vsphere-iso.ubuntu"]

  # 1) Wait for cloud-init's first boot & do system updates
  provisioner "shell" {
    inline = [
      # Wait until cloud-init (autoinstall) is done
      "while [ ! -f /var/lib/cloud/instance/boot-finished ]; do echo 'Waiting for autoinstall...'; sleep 5; done",
      "export DEBIAN_FRONTEND=noninteractive",

      # Basic system update
      "sudo apt-get update -y",
      "sudo apt-get upgrade -y",

      # Ensure open-vm-tools & cloud-init are installed
      "sudo apt-get install -y open-vm-tools cloud-init curl wget git vim nano",

      # Enable & start open-vm-tools
      "sudo systemctl enable open-vm-tools",
      "sudo systemctl start open-vm-tools",
      "until systemctl is-active --quiet open-vm-tools; do echo 'Waiting for open-vm-tools...'; sleep 15; done",
    ]
  }

  # 2) Configure VMware guestinfo datasource in cloud-init
  provisioner "shell" {
    inline = [
      "sudo tee /etc/cloud/cloud.cfg.d/99-vmware-guest-info.cfg <<EOF",
      "datasource_list: [VMware, NoCloud, ConfigDrive]",
      "disable_vmware_customization: false",
      "datasource:",
      "  VMware:",
      "    allow_raw_data: true",
      "    vmware_cust_file_max_wait: 10",
      "    clean_on_fail: true",
      "EOF"
    ]
  }

  # 3) Run your existing cleanup script
  provisioner "shell" {
    script          = "scripts/cleanup.sh"
    execute_command = "sudo bash -c '{{ .Path }}'"
  }

  # 4) Remove ds=nocloud from grub, leftover seeds, then 'cloud-init clean'
  provisioner "shell" {
    inline = [
      # Remove references to 'autoinstall ds=nocloud' from both grub and grub.ucf-dist
      # (since we've seen it appear in /etc/default/grub.ucf-dist)
      "sudo sed -i 's/autoinstall ds=nocloud//g' /etc/default/grub || true",
      "sudo sed -i 's/autoinstall ds=nocloud//g' /etc/default/grub.ucf-dist || true",

      # Optional: remove the .ucf-dist file if it's not needed
      "sudo rm -f /etc/default/grub.ucf-dist || true",

      # Update the final grub config
      "sudo update-grub || true",

      # Also remove leftover references from /boot/grub/grub.cfg
      "sudo sed -i 's/autoinstall ds=nocloud//g' /boot/grub/grub.cfg || true",

      # Remove leftover NoCloud seeds (if any)
      "sudo rm -rf /var/lib/cloud/seed/nocloud",
      "sudo rm -rf /var/lib/cloud/seed/nocloud-net",

      # Clean Cloud-Init so next boot sees a fresh instance
      "sudo cloud-init clean",
      "sudo rm -rf /var/lib/cloud/ /var/log/cloud-init.log /var/log/cloud-init-output.log",

      # Force new instance-id
      "echo \"instance-id: $(uuidgen)\" | sudo tee /etc/cloud/cloud.cfg.d/99-fresh.cfg"
    ]
  }
}