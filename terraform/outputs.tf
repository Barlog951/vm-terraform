output "vm_details" {
  description = "Details of all created VMs"
  value       = module.vms.vm_details
}

output "vm_ips" {
  description = "IP addresses of created VMs"
  value       = module.vms.vm_default_ips
}

output "template_info" {
  description = "Information about the source template"
  value       = module.vms.template_info
}

output "infrastructure_info" {
  description = "Information about the vSphere infrastructure"
  value = {
    datacenter = var.vcenter_datacenter
    cluster    = var.vcenter_cluster
    datastores = module.vms.datastore_details
    networks   = module.vms.network_details
  }
}