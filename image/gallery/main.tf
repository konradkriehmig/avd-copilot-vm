terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

variable "subscription_id" {
  type = string
}

variable "location" {
  type    = string
  default = "northeurope"
}

variable "resource_group_name" {
  type    = string
  default = "rg-avd-copilot-images"
}

variable "gallery_name" {
  type    = string
  default = "galavdcopilot"
}

variable "image_definition_name" {
  type    = string
  default = "win11-avd-copilot"
}

variable "tags" {
  type    = map(string)
  default = { workload = "avd-copilot" }
}

resource "azurerm_resource_group" "images" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_shared_image_gallery" "this" {
  name                = var.gallery_name
  resource_group_name = azurerm_resource_group.images.name
  location            = azurerm_resource_group.images.location
  description         = "Golden images for the AVD Copilot desktop"
  tags                = var.tags
}

resource "azurerm_shared_image" "win11" {
  name                = var.image_definition_name
  gallery_name        = azurerm_shared_image_gallery.this.name
  resource_group_name = azurerm_resource_group.images.name
  location            = azurerm_resource_group.images.location
  os_type             = "Windows"
  hyper_v_generation  = "V2"

  # Must match the Packer build (Trusted Launch) and the session host VM.
  trusted_launch_enabled = true
  # v6/v7 sizes (e.g. Standard_D8ads_v7) are NVMe-only; without this the image can't be deployed to them.
  disk_controller_type_nvme_enabled   = true
  accelerated_network_support_enabled = true

  identifier {
    publisher = "avd-copilot"
    offer     = "windows-11-avd-copilot"
    sku       = "win11-24h2-ent"
  }

  tags = var.tags
}

output "image_definition_id" {
  description = "Set as gallery_image_version_id in ../../terraform to always deploy the latest image version."
  value       = azurerm_shared_image.win11.id
}

output "packer_vars" {
  value = "-var subscription_id=${var.subscription_id} -var gallery_resource_group=${azurerm_resource_group.images.name} -var gallery_name=${azurerm_shared_image_gallery.this.name} -var image_definition=${azurerm_shared_image.win11.name} -var location=${var.location}"
}
