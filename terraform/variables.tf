variable "resource_group_name" {
  description = "Name of the existing resource group for the ArcGIS Lab"
  type        = string
  default     = "rg-arcgis-enterprise-lab"
}

variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "East US"
}

variable "vnet_name" {
  description = "Name of the virtual network"
  type        = string
  default     = "vnet-arcgis-lab"
}

variable "vnet_address_space" {
  description = "Address space for the VNet"
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

variable "admin_ip" {
  description = "Your admin IP address for scoped RDP/HTTPS access (as CIDR /32)"
  type        = string
  # No default on purpose - set this in terraform.tfvars, not committed to Git
}