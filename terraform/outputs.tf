output "host_pool_name" {
  value = azurerm_virtual_desktop_host_pool.this.name
}

output "custom_rdp_properties" {
  description = "Must contain targetisaadjoined:i:1 and enablerdsaadauth:i:1."
  value       = azurerm_virtual_desktop_host_pool.this.custom_rdp_properties
}

output "workspace_name" {
  value = azurerm_virtual_desktop_workspace.this.name
}

output "vm_id" {
  value = azurerm_windows_virtual_machine.host.id
}

output "admin_username" {
  description = "Break-glass local admin only. Sign in to AVD with your Entra UPN."
  value       = var.admin_username
}

output "admin_password" {
  description = "terraform output -raw admin_password"
  value       = random_password.admin.result
  sensitive   = true
}

output "connect" {
  value = "Windows App or https://windows.cloud.microsoft/ -> sign in with your Entra UPN -> 'Copilot VM'"
}
