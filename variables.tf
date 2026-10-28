variable "name_prefix" {
  description = "Prefix for this isolated LXD experiment. Keep names below 15 characters for Linux bridges."
  type        = string
  default     = "nbgp"
}

variable "image_alias" {
  description = "Ubuntu 26.04 cloud image alias on the Ubuntu simplestreams remote."
  type        = string
  default     = "ubuntu:26.04"
}

variable "storage_pool" {
  description = "Existing LXD storage pool."
  type        = string
  default     = "default"
}

variable "ssh_public_key" {
  description = "Public key for the ubuntu account on the three hyperconverged VMs."
  type        = string
  default     = ""
}

variable "neutron_package_version" {
  description = "Neutron package version pinned on the hyperconverged VMs."
  type        = string
  default     = "2:28.0.2-0ubuntu1"
}

variable "regress_stack_package" {
  description = "Path to the prebuilt regress-stack package with multinode and local provider bridge support."
  type        = string
  default     = "regress-stack.deb"

  validation {
    condition     = fileexists(var.regress_stack_package)
    error_message = "Set regress_stack_package to an existing prebuilt .deb file."
  }
}

variable "bgp_peering_mode" {
  description = "Chassis-to-ToR peering: unnumbered (IPv6 link-local) or ipv4-numbered. Changing mode replaces the lab instances."
  type        = string
  default     = "unnumbered"

  validation {
    condition     = contains(["unnumbered", "ipv4-numbered"], var.bgp_peering_mode)
    error_message = "bgp_peering_mode must be unnumbered or ipv4-numbered."
  }
}
