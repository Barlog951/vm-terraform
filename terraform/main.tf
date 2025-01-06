terraform {
  required_version = ">= 1.0.0"
}

module "vms" {
  source = "./modules/vm"

  # Required infrastructure settings
  datacenter = var.vcenter_datacenter
  cluster    = var.vcenter_cluster

  # Pass the networks and datastores configuration
  networks   = var.networks
  datastores = var.datastores

  # Template information
  template_name = var.template_name

  # VM configurations
  vm_instances = {
    for name, vm in var.vm_definitions : name => {
      name               = vm.name
      hostname           = vm.hostname
      cpus               = vm.cpu
      cores_per_socket   = 1
      memory             = vm.memory
      datastore          = vm.datastore
      environment        = vm.environment
      network_interfaces = vm.network_interfaces
      disks              = vm.disks
    }
  }

  timezone    = "Europe/Bratislava"
}