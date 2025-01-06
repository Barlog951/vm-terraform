# Wait for IP assignment
resource "null_resource" "wait_for_ips" {
  for_each = var.vm_instances

  triggers = {
    vm_id = vsphere_virtual_machine.vm[each.key].id
  }

  provisioner "local-exec" {
    command = "sleep 60"  # Wait for cloud-init to complete network setup
  }

  depends_on = [vsphere_virtual_machine.vm]
}

# Trigger refresh of the data source
resource "null_resource" "trigger_refresh" {
  for_each = var.vm_instances

  triggers = {
    wait_completed = null_resource.wait_for_ips[each.key].id
  }
}

# Data source for VM information including IP addresses
data "vsphere_virtual_machine" "vm_info" {
  for_each = vsphere_virtual_machine.vm

  name          = each.value.name
  datacenter_id = data.vsphere_datacenter.dc.id

  depends_on = [null_resource.trigger_refresh]
}

output "vm_ids" {
  description = "Map of VM names and their IDs"
  value       = { for k, v in vsphere_virtual_machine.vm : k => v.id }
}

output "vm_default_ips" {
  description = "Map of VM names and their primary IP addresses"
  value       = { for k, v in data.vsphere_virtual_machine.vm_info : k => (
    try(length(v.guest_ip_addresses) > 0 ? v.guest_ip_addresses[0] : null, null)
  )}
}

output "vm_guest_ids" {
  description = "Map of VM names and their guest IDs"
  value       = { for k, v in vsphere_virtual_machine.vm : k => v.guest_id }
}

output "vm_names" {
  description = "List of VM names"
  value       = keys(vsphere_virtual_machine.vm)
}

output "vm_details" {
  description = "Map of VM details including hardware configuration"
  value = {
    for k, v in vsphere_virtual_machine.vm : k => {
      id          = v.id
      name        = v.name
      num_cpus    = v.num_cpus
      memory      = v.memory
      ip_address  = try(
        length(data.vsphere_virtual_machine.vm_info[k].guest_ip_addresses) > 0 ?
        data.vsphere_virtual_machine.vm_info[k].guest_ip_addresses[0] : null,
        null
      )
      power_state = v.power_state
      guest_id    = v.guest_id
      uuid        = v.uuid
    }
  }
}

output "template_info" {
  description = "Information about the source template"
  value = {
    id       = data.vsphere_virtual_machine.template.id
    name     = var.template_name
    guest_id = data.vsphere_virtual_machine.template.guest_id
  }
}

output "network_details" {
  description = "Information about configured networks"
  value = {
    for network_name, network_data in data.vsphere_network.networks : network_name => {
      id   = network_data.id
      name = network_data.name
      type = var.networks[network_name].type
    }
  }
}

output "datastore_details" {
  description = "Information about configured datastores"
  value = {
    for ds_name, ds_data in data.vsphere_datastore.datastores : ds_name => {
      id   = ds_data.id
      name = ds_data.name
      type = var.datastores[ds_name].type
    }
  }
}