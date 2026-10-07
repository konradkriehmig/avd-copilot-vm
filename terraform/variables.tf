variable "subscription_id" {
  description = "Azure subscription to deploy into."
  type        = string
}

variable "tenant_id" {
  description = "Entra ID tenant that owns the subscription AND the AVD users. Check with `az account show` before applying."
  type        = string
}

variable "avd_user_upns" {
  description = "Entra UPNs that may sign in to the desktop (e.g. [\"me@contoso.onmicrosoft.com\"])."
  type        = list(string)
}

variable "grant_vm_admin_login" {
  description = "true = 'Virtual Machine Administrator Login' (local admin on the host), false = 'Virtual Machine User Login'."
  type        = bool
  default     = false
}

variable "location" {
  description = "Azure region. northeurope = Dublin."
  type        = string
  default     = "northeurope"
}

variable "resource_group_name" {
  type    = string
  default = "rg-avd-copilot-neu"
}

variable "address_space" {
  type    = string
  default = "10.20.0.0/24"
}

variable "subnet_prefix" {
  type    = string
  default = "10.20.0.0/26"
}

variable "host_pool_name" {
  type    = string
  default = "hp-copilot-personal"
}

variable "workspace_name" {
  type    = string
  default = "ws-copilot"
}

variable "app_group_name" {
  type    = string
  default = "dag-copilot-desktop"
}

variable "extra_rdp_properties" {
  description = "Additional RDP properties. targetisaadjoined:i:1 and enablerdsaadauth:i:1 are always added; see main.tf."
  type        = list(string)
  default = [
    "audiocapturemode:i:1",
    "audiomode:i:0",
    "drivestoredirect:s:",
    "redirectclipboard:i:1",
    "redirectprinters:i:0",
    "autoreconnection enabled:i:1",
    "bandwidthautodetect:i:1",
    "networkautodetect:i:1",
    "compression:i:1",
  ]

  validation {
    condition = alltrue([
      for p in var.extra_rdp_properties :
      !can(regex("^(targetisaadjoined|enablerdsaadauth):", lower(p)))
    ])
    error_message = "Do not set targetisaadjoined/enablerdsaadauth here. They are enforced in main.tf because removing them breaks Entra ID sign-in."
  }
}

variable "vm_name" {
  type    = string
  default = "vm-copilot-neu01"
}

variable "computer_name" {
  description = "Windows computer name (max 15 chars, which is why it's separate from vm_name)."
  type        = string
  default     = "copilotvm01"

  validation {
    condition     = length(var.computer_name) <= 15 && can(regex("^[A-Za-z0-9-]+$", var.computer_name))
    error_message = "computer_name must be at most 15 characters, using letters, digits and hyphens only."
  }
}

variable "vm_size" {
  description = "Use an NVadsA10_v5 size (e.g. Standard_NV36ads_A10_v5) for GPU apps (DaVinci Resolve, Unreal). Needs GPU quota. SkuNotAvailable = regional capacity, try another size or region."
  type        = string
  default     = "Standard_D8ads_v7"
}

variable "install_nvidia_gpu_driver" {
  description = "Install the NVIDIA GRID driver extension. Set true when vm_size is an NV/NC GPU size."
  type        = bool
  default     = false
}

variable "os_disk_size_gb" {
  type    = number
  default = 256
}

variable "gallery_image_version_id" {
  description = "Optional golden image (Azure Compute Gallery image version or image definition ID, see ../image). Empty = marketplace Windows 11 image + scripts/setup-vm.ps1."
  type        = string
  default     = ""
}

variable "marketplace_image" {
  description = "Used when gallery_image_version_id is empty."
  type = object({
    publisher = string
    offer     = string
    sku       = string
    version   = string
  })
  default = {
    publisher = "MicrosoftWindowsDesktop"
    offer     = "windows-11"
    sku       = "win11-24h2-ent"
    version   = "latest"
  }
}

variable "admin_username" {
  description = "Break-glass local admin. AVD users sign in with their Entra account, not this one."
  type        = string
  default     = "copilotadmin"
}

variable "avd_dsc_configuration_url" {
  description = "AVD agent registration package. There is no 'latest' alias; update the version if it 404s."
  type        = string
  default     = "https://wvdportalstorageblob.blob.core.windows.net/galleryartifacts/Configuration_1.0.03362.1223.zip"
}

variable "run_setup_script" {
  description = "Run scripts/setup-vm.ps1 (power settings + Git/Node/gh/Copilot CLI) after deployment. Leave on; it is idempotent and also fixes power settings on golden images."
  type        = bool
  default     = true
}

variable "tags" {
  type    = map(string)
  default = { workload = "avd-copilot" }
}
