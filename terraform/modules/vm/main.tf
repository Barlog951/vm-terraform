################################################################################
# Data Sources
################################################################################

data "vsphere_datacenter" "dc" {
  name = var.datacenter
}

data "vsphere_compute_cluster" "cluster" {
  name          = var.cluster
  datacenter_id = data.vsphere_datacenter.dc.id
}

# Get all networks
data "vsphere_network" "networks" {
  for_each      = var.networks
  name          = each.value.name
  datacenter_id = data.vsphere_datacenter.dc.id
}

# Get all datastores
data "vsphere_datastore" "datastores" {
  for_each      = var.datastores
  name          = each.value.name
  datacenter_id = data.vsphere_datacenter.dc.id
}

# Get template
data "vsphere_virtual_machine" "template" {
  name          = var.template_name
  datacenter_id = data.vsphere_datacenter.dc.id
}

################################################################################
# VM Resource with Cloud-Init Configuration
################################################################################

resource "vsphere_virtual_machine" "vm" {
  for_each = var.vm_instances

  # Basic VM settings
  name             = each.value.name
  resource_pool_id = data.vsphere_compute_cluster.cluster.resource_pool_id
  datastore_id     = data.vsphere_datastore.datastores[each.value.datastore].id
  folder           = each.value.environment  # Now using per-VM environment

  # CPU, memory, and guest OS
  num_cpus             = each.value.cpus
  num_cores_per_socket = each.value.cores_per_socket
  memory               = each.value.memory
  guest_id             = data.vsphere_virtual_machine.template.guest_id

  # VM settings
  sync_time_with_host = true
  wait_for_guest_net_timeout = 0
  wait_for_guest_ip_timeout = 0

  # Network interfaces
  dynamic "network_interface" {
    for_each = each.value.network_interfaces
    content {
      network_id   = data.vsphere_network.networks[network_interface.value.network].id
      adapter_type = "vmxnet3"
    }
  }

  # Disks
  dynamic "disk" {
    for_each = each.value.disks
    content {
      label            = "disk${disk.key}"
      size             = disk.value.size
      thin_provisioned = disk.value.thin_provisioned
      unit_number      = tonumber(disk.key)
    }
  }

  # Simple clone without customization
  clone {
    template_uuid = data.vsphere_virtual_machine.template.id
  }

  # Cloud-init config through extra_config
  extra_config = {
    "guestinfo.metadata" = base64encode(jsonencode({
      "local-hostname" = each.value.hostname
      "instance-id"    = each.value.name
    }))
    "guestinfo.metadata.encoding" = "base64"
    "guestinfo.userdata" = base64encode(templatefile("${path.module}/files/cloud-init.yaml", {
      hostname = each.value.hostname
      network_config = [
        for interface in each.value.network_interfaces : {
          name   = "ens192"
          dhcp4  = interface.ip_address == null
          static = interface.ip_address != null ? {
            address = interface.ip_address
            netmask = interface.netmask
            gateway = var.networks[interface.network].ip_pool.gateway
            dns     = coalescelist(var.networks[interface.network].ip_pool.dns, [var.networks[interface.network].ip_pool.gateway])
          } : null
        }
      ]
    }))
    "guestinfo.userdata.encoding" = "base64"
  }

  # Lifecycle settings
  lifecycle {
    ignore_changes = [
      annotation,
      clone[0].template_uuid,
      extra_config,
      disk
    ]
  }
}