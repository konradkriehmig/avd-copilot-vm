packer {
  required_plugins {
    azure = {
      source  = "github.com/hashicorp/azure"
      version = "~> 2"
    }
  }
}

variable "subscription_id" {
  type        = string
  description = "Subscription that holds the gallery (the build VM is created there too)."
}

variable "location" {
  type    = string
  default = "northeurope"
}

variable "gallery_resource_group" {
  type    = string
  default = "rg-avd-copilot-images"
}

variable "gallery_name" {
  type    = string
  default = "galavdcopilot"
}

variable "image_definition" {
  type    = string
  default = "win11-avd-copilot"
}

variable "replication_regions" {
  type        = list(string)
  default     = []
  description = "Extra regions to replicate the image version to (the build region is always included)."
}

variable "build_vm_size" {
  type = string
  # SCSI-capable size on purpose: Packer can't pick NVMe for v6/v7 sizes. The image definition supports
  # SCSI + NVMe, so the image still deploys to NVMe-only sizes like Standard_D8ads_v7.
  default = "Standard_D8ads_v5"
}

variable "allowed_inbound_ip_addresses" {
  type        = list(string)
  description = "Public IP(s) of the machine running Packer. WinRM on the temporary build VM is only opened to these."
}

variable "davinci_resolve_installer_url" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Optional. DaVinci Resolve installer (.zip or .exe), e.g. a private blob SAS URL. Empty = skip."
}

variable "unreal_engine_zip_url" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Optional. Zip of an installed Unreal Engine folder. Empty = Epic Games Launcher only."
}

locals {
  now = timestamp()
  # Gallery versions are Major.Minor.Patch integers, e.g. 2026.1007.1530 (parseint strips leading zeros).
  image_version = "${formatdate("YYYY", local.now)}.${parseint(formatdate("MMDD", local.now), 10)}.${parseint(formatdate("hhmm", local.now), 10)}"
}

source "azure-arm" "win11" {
  use_azure_cli_auth = true
  subscription_id    = var.subscription_id

  os_type         = "Windows"
  image_publisher = "MicrosoftWindowsDesktop"
  image_offer     = "windows-11"
  image_sku       = "win11-24h2-ent"
  image_version   = "latest"

  location        = var.location
  vm_size         = var.build_vm_size
  os_disk_size_gb = 256
  license_type    = "Windows_Client"

  # Must match the gallery image definition (security type TrustedLaunch).
  security_type       = "TrustedLaunch"
  secure_boot_enabled = true
  vtpm_enabled        = true

  allowed_inbound_ip_addresses = var.allowed_inbound_ip_addresses

  communicator   = "winrm"
  winrm_use_ssl  = true
  winrm_insecure = true
  winrm_timeout  = "15m"
  winrm_username = "packer"

  # Trusted Launch images can only live in an Azure Compute Gallery (no managed image).
  shared_image_gallery_destination {
    subscription         = var.subscription_id
    resource_group       = var.gallery_resource_group
    gallery_name         = var.gallery_name
    image_name           = var.image_definition
    image_version        = local.image_version
    replication_regions  = distinct(concat([var.location], var.replication_regions))
    storage_account_type = "Standard_LRS"
  }
  shared_image_gallery_timeout = "2h"

  azure_tags = {
    workload = "avd-copilot"
    purpose  = "golden-image-build"
  }
}

build {
  sources = ["source.azure-arm.win11"]

  # Store app updates during the build create per-user AppX packages, which makes sysprep fail.
  # The policy stays in the image; remove it (or manage it via Intune/GPO) if you want Store auto-updates.
  provisioner "powershell" {
    inline = [
      "New-Item -Path 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\WindowsStore' -Force | Out-Null",
      "Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\WindowsStore' -Name AutoDownload -Value 2 -Type DWord",
    ]
  }

  # Dev tools: Git, Node.js, gh, PowerShell 7, Python, VS Code, Azure CLI, Az PowerShell,
  # GitHub Copilot app, GitHub Copilot CLI. Same script the Terraform run command uses.
  provisioner "powershell" {
    elevated_user     = build.User
    elevated_password = build.Password
    script            = "${path.root}/../scripts/setup-vm.ps1"
  }

  provisioner "windows-restart" {
    restart_timeout = "30m"
  }

  # Blender, Epic Games Launcher (+ optional Unreal Engine zip), optional DaVinci Resolve.
  provisioner "powershell" {
    elevated_user     = build.User
    elevated_password = build.Password
    environment_vars = [
      "DAVINCI_RESOLVE_INSTALLER_URL=${var.davinci_resolve_installer_url}",
      "UNREAL_ENGINE_ZIP_URL=${var.unreal_engine_zip_url}",
    ]
    script = "${path.root}/install-creative-apps.ps1"
  }

  provisioner "windows-restart" {
    restart_timeout = "30m"
  }

  # Generalize. No Entra join and no AVD agent in the image: those are added per VM at deploy time.
  provisioner "powershell" {
    inline = [
      "Remove-Item -Recurse -Force \"$env:TEMP\\avd-setup\", 'D:\\avd-setup' -ErrorAction SilentlyContinue",
      "while ((Get-Service RdAgent).Status -ne 'Running') { Start-Sleep -Seconds 5 }",
      "while ((Get-Service WindowsAzureGuestAgent).Status -ne 'Running') { Start-Sleep -Seconds 5 }",
      "& $env:SystemRoot\\System32\\Sysprep\\Sysprep.exe /oobe /generalize /quiet /quit /mode:vm",
      "while ($true) { $s = (Get-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Setup\\State').ImageState; if ($s -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { Write-Output $s; Start-Sleep -Seconds 10 } else { break } }",
    ]
  }
}
