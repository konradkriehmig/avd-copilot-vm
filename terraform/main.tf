locals {
  # REQUIRED for Entra ID-joined session hosts. Do not remove.
  #
  # Without enablerdsaadauth:i:1 the client uses the legacy "Windows Security" username/password box,
  # which cannot satisfy MFA / Conditional Access, so the user gets an endless
  # "Your credentials did not work" even with the right password. Resetting passwords or editing
  # Conditional Access does NOT fix it (and causes damage). See README "Pitfalls".
  required_rdp_properties = ["targetisaadjoined:i:1", "enablerdsaadauth:i:1"]
  custom_rdp_properties   = "${join(";", concat(local.required_rdp_properties, var.extra_rdp_properties))};"

  use_gallery_image = var.gallery_image_version_id != ""
}

data "azuread_user" "avd" {
  for_each            = toset(var.avd_user_upns)
  user_principal_name = each.value
}

# ---------------------------------------------------------------------------
# Resource group + network (no inbound rules / no public IP: AVD uses reverse connect)
# ---------------------------------------------------------------------------
resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "this" {
  name                = "vnet-avd-copilot"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = [var.address_space]
  tags                = var.tags
}

resource "azurerm_subnet" "hosts" {
  name                 = "subnet-hosts"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.subnet_prefix]
}

resource "azurerm_network_security_group" "this" {
  name                = "nsg-avd-copilot"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

resource "azurerm_subnet_network_security_group_association" "hosts" {
  subnet_id                 = azurerm_subnet.hosts.id
  network_security_group_id = azurerm_network_security_group.this.id
}

# ---------------------------------------------------------------------------
# AVD control plane
# ---------------------------------------------------------------------------
resource "azurerm_virtual_desktop_host_pool" "this" {
  name                             = var.host_pool_name
  location                         = azurerm_resource_group.this.location
  resource_group_name              = azurerm_resource_group.this.name
  type                             = "Personal"
  load_balancer_type               = "Persistent"
  personal_desktop_assignment_type = "Automatic"
  preferred_app_group_type         = "Desktop"
  start_vm_on_connect              = false
  validate_environment             = false
  custom_rdp_properties            = local.custom_rdp_properties
  tags                             = var.tags

  lifecycle {
    precondition {
      condition = alltrue([
        for p in local.required_rdp_properties : strcontains(local.custom_rdp_properties, p)
      ])
      error_message = "custom_rdp_properties must contain targetisaadjoined:i:1 and enablerdsaadauth:i:1."
    }
  }
}

# Registration tokens are valid for max ~27 days; only needed while the DSC extension registers the host.
resource "time_rotating" "registration" {
  rotation_days = 7
}

resource "azurerm_virtual_desktop_host_pool_registration_info" "this" {
  hostpool_id     = azurerm_virtual_desktop_host_pool.this.id
  expiration_date = time_rotating.registration.rotation_rfc3339
}

resource "azurerm_virtual_desktop_application_group" "desktop" {
  name                         = var.app_group_name
  location                     = azurerm_resource_group.this.location
  resource_group_name          = azurerm_resource_group.this.name
  type                         = "Desktop"
  host_pool_id                 = azurerm_virtual_desktop_host_pool.this.id
  default_desktop_display_name = "Copilot VM"
  tags                         = var.tags
}

resource "azurerm_virtual_desktop_workspace" "this" {
  name                = var.workspace_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  friendly_name       = "Copilot VM"
  tags                = var.tags
}

resource "azurerm_virtual_desktop_workspace_application_group_association" "this" {
  workspace_id         = azurerm_virtual_desktop_workspace.this.id
  application_group_id = azurerm_virtual_desktop_application_group.desktop.id
}

# ---------------------------------------------------------------------------
# Session host VM
# ---------------------------------------------------------------------------
resource "random_password" "admin" {
  length           = 24
  special          = true
  override_special = "#%*-=@" # az.cmd/cmd.exe-safe in case it's ever passed on a command line
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "azurerm_network_interface" "host" {
  name                           = "${var.vm_name}-nic"
  location                       = azurerm_resource_group.this.location
  resource_group_name            = azurerm_resource_group.this.name
  accelerated_networking_enabled = true
  tags                           = var.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.hosts.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_windows_virtual_machine" "host" {
  name                  = var.vm_name
  computer_name         = var.computer_name
  location              = azurerm_resource_group.this.location
  resource_group_name   = azurerm_resource_group.this.name
  size                  = var.vm_size
  admin_username        = var.admin_username
  admin_password        = random_password.admin.result
  network_interface_ids = [azurerm_network_interface.host.id]
  license_type          = "Windows_Client" # AVD per-user Windows entitlement
  secure_boot_enabled   = true
  vtpm_enabled          = true
  tags                  = var.tags

  # REQUIRED: AADLoginForWindows (Entra join) fails without a managed identity.
  identity {
    type = "SystemAssigned"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_id = local.use_gallery_image ? var.gallery_image_version_id : null

  dynamic "source_image_reference" {
    for_each = local.use_gallery_image ? [] : [var.marketplace_image]
    content {
      publisher = source_image_reference.value.publisher
      offer     = source_image_reference.value.offer
      sku       = source_image_reference.value.sku
      version   = source_image_reference.value.version
    }
  }
}

resource "azurerm_virtual_machine_extension" "nvidia" {
  count                      = var.install_nvidia_gpu_driver ? 1 : 0
  name                       = "NvidiaGpuDriverWindows"
  virtual_machine_id         = azurerm_windows_virtual_machine.host.id
  publisher                  = "Microsoft.HpcCompute"
  type                       = "NvidiaGpuDriverWindows"
  type_handler_version       = "1.11"
  auto_upgrade_minor_version = true
  tags                       = var.tags
}

resource "azurerm_virtual_machine_extension" "aad_login" {
  name                       = "AADLoginForWindows"
  virtual_machine_id         = azurerm_windows_virtual_machine.host.id
  publisher                  = "Microsoft.Azure.ActiveDirectory"
  type                       = "AADLoginForWindows"
  type_handler_version       = "2.2"
  auto_upgrade_minor_version = true
  tags                       = var.tags

  depends_on = [azurerm_virtual_machine_extension.nvidia]
}

resource "azurerm_virtual_machine_extension" "avd_agent" {
  name                       = "DSC"
  virtual_machine_id         = azurerm_windows_virtual_machine.host.id
  publisher                  = "Microsoft.Powershell"
  type                       = "DSC"
  type_handler_version       = "2.83"
  auto_upgrade_minor_version = true
  tags                       = var.tags

  settings = jsonencode({
    modulesUrl            = var.avd_dsc_configuration_url
    configurationFunction = "Configuration.ps1\\AddSessionHost"
    properties = {
      HostPoolName = azurerm_virtual_desktop_host_pool.this.name
      aadJoin      = true
    }
  })

  protected_settings = jsonencode({
    properties = {
      registrationInfoToken = azurerm_virtual_desktop_host_pool_registration_info.this.token
    }
  })

  # The token rotates weekly; the host stays registered, so don't redeploy the extension for it.
  lifecycle {
    ignore_changes = [protected_settings]
  }

  depends_on = [azurerm_virtual_machine_extension.aad_login]
}

resource "azurerm_virtual_machine_run_command" "setup" {
  count              = var.run_setup_script ? 1 : 0
  name               = "copilot-setup"
  location           = azurerm_resource_group.this.location
  virtual_machine_id = azurerm_windows_virtual_machine.host.id
  tags               = var.tags

  source {
    script = file("${path.module}/../scripts/setup-vm.ps1")
  }

  timeouts {
    create = "90m"
  }

  depends_on = [azurerm_virtual_machine_extension.avd_agent]
}

# ---------------------------------------------------------------------------
# RBAC: BOTH roles are required for Entra ID sign-in to an AVD host.
# ---------------------------------------------------------------------------
resource "azurerm_role_assignment" "desktop_user" {
  for_each             = data.azuread_user.avd
  scope                = azurerm_virtual_desktop_application_group.desktop.id
  role_definition_name = "Desktop Virtualization User"
  principal_id         = each.value.object_id
  principal_type       = "User"
}

resource "azurerm_role_assignment" "vm_login" {
  for_each             = data.azuread_user.avd
  scope                = azurerm_windows_virtual_machine.host.id
  role_definition_name = var.grant_vm_admin_login ? "Virtual Machine Administrator Login" : "Virtual Machine User Login"
  principal_id         = each.value.object_id
  principal_type       = "User"
}
