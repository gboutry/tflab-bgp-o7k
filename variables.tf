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
  default     = "2:29.0.0-0ubuntu1~cloud0"
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

variable "cloud_archive" {
  description = "Signed Ubuntu Cloud Archive pocket on Resolute."
  type        = string
  default     = "hibiscus"

  validation {
    condition     = var.cloud_archive == "hibiscus"
    error_message = "This fixture uses resolute-updates/hibiscus."
  }
}

variable "ovn_runtime_archive" {
  description = "Native make-install archive of the complete source OVN runtime."
  type        = string

  validation {
    condition     = fileexists(var.ovn_runtime_archive)
    error_message = "Provide the built OVN runtime archive before planning."
  }
}

variable "ovn_runtime_manifest" {
  description = "Build provenance and file manifest for ovn_runtime_archive."
  type        = string

  validation {
    condition     = fileexists(var.ovn_runtime_manifest)
    error_message = "Provide the OVN runtime build manifest before planning."
  }
}

variable "ovn_source_revision" {
  description = "Exact OVN source commit required by the runtime manifest."
  type        = string
  default     = "a298c1347d39aa4f277701b98fb18a3679574a39"
}
