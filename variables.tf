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

variable "regress_stack_commit" {
  description = "Immutable regress-stack PR 96 source revision used by the lab deployer."
  type        = string
  default     = "a37016f35b4fc67701a9c9edee44baa500c33d99"
}
