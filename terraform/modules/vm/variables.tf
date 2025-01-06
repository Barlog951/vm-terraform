variable "datacenter" {
  description = "The name of the vSphere datacenter"
  type        = string
}

variable "cluster" {
  description = "The name of the vSphere cluster"
  type        = string
}

variable "networks" {
  description = "Map of available networks"
  type = map(object({
    name = string
    type = string  # Can be HOMELAB, LAN, WAN, etc.
    ip_pool = object({
      network    = string
      prefix     = number
      gateway    = string
      dns       = list(string)
      start_ip   = string
      end_ip     = string
    })
  }))
}

variable "datastores" {
  description = "Map of available datastores"
  type = map(object({
    name = string
    type = string  # Can be SSD, HDD, etc.
    cluster = string
  }))
}

variable "template_name" {
  description = "The name of the VM template to clone from"
  type        = string
}

variable "vm_instances" {
  description = "Map of VM instances to create"
  type = map(object({
    name             = string
    hostname         = string
    cpus             = number
    cores_per_socket = number
    memory           = number
    datastore        = string  # Reference to datastores map
    environment      = optional(string, "testing")  # Added environment with default
    network_interfaces = list(object({
      network     = string  # Reference to networks map
      ip_address  = optional(string)
      netmask    = number
    }))
    disks = map(object({
      size             = number
      thin_provisioned = bool
    }))
  }))
}

# Common variables
variable "dns_servers" {
  description = "List of DNS servers"
  type        = list(string)
  default     = ["8.8.8.8", "8.8.4.4"]
}

variable "timezone" {
  description = "Timezone for VMs"
  type        = string
  default     = "Europe/Bratislava"
}