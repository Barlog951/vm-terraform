variable "vcenter_datacenter" {
  description = "vSphere datacenter name"
  type        = string
}

variable "vcenter_cluster" {
  description = "vSphere cluster name"
  type        = string
}

variable "template_name" {
  description = "Name of the VM template"
  type        = string
  default     = "ubuntu-template"
}

# Network configurations
variable "networks" {
  description = "Map of available networks"
  type = map(object({
    name = string
    type = string
    ip_pool = object({
      network  = string
      prefix   = number
      gateway  = string
      dns      = list(string)
      start_ip = string
      end_ip   = string
    })
  }))
}

# Datastore configurations
variable "datastores" {
  description = "Map of available datastores"
  type = map(object({
    name    = string
    type    = string
    cluster = string
  }))
}

# VM definitions
variable "vm_definitions" {
  description = "Map of VM definitions"
  type = map(object({
    name        = string
    hostname    = string
    cpu         = number
    memory      = number
    datastore   = string
    environment = optional(string, "testing")
    network_interfaces = list(object({
      network    = string
      ip_address = optional(string)
      netmask    = number
    }))
    disks = map(object({
      size             = number
      thin_provisioned = bool
    }))
  }))
}