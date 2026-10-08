# Instructions for AI agents (GitHub Copilot CLI etc.)

Read [README.md](README.md) first, including **Pitfalls**. If an `ENVIRONMENT.local.md` exists next to this file, read it too
(tenant, subscription and resource names of the real deployment).

## Hard rules

1. **Never reset a user's password, and never create or edit Conditional Access policies, without the user's explicit OK.**
   Neither fixes AVD sign-in problems, and a password reset revokes the agent's own tokens.
2. **Verify the tenant and account before any write**: `az account show --query "{tenant:tenantId, sub:id, user:user.name}"`.
3. **Don't recreate or rebuild** the session host or host pool to fix a sign-in problem. Diagnose first (checklist below).
4. Don't change `targetisaadjoined:i:1;enablerdsaadauth:i:1` in the host pool RDP properties. Terraform enforces them.
5. Don't commit secrets, tenant IDs, subscription IDs or UPNs. Put them in `*.local.md` or `local/` (git-ignored).
6. Use REST (`az rest`) for session hosts and user sessions; there are no `az desktopvirtualization` commands for them.

## "I can't sign in to the desktop": checklist, in this order

1. Host pool RDP properties contain `enablerdsaadauth:i:1` and `targetisaadjoined:i:1`:
   `az desktopvirtualization hostpool show -g <rg> -n <hp> --query customRdpProperty -o tsv`
2. Session host is `Available` and the VM is running:
   `az rest --method get --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.DesktopVirtualization/hostPools/<hp>/sessionHosts?api-version=2023-09-05"`
3. The user has **Desktop Virtualization User** on the app group **and** **Virtual Machine User Login** (or Administrator Login) on the VM/RG.
4. The user signs in with their **Entra UPN** in Windows App or the web client, not the local admin.
   A grey *Windows Security* password box means step 1 is wrong.
5. Read the Entra sign-in logs for the user (apps *Azure Virtual Desktop*, *Microsoft Remote Desktop*, *Windows Cloud Login*)
   and report the actual error code. **Ask the user** before changing anything identity-related.

## "The VM shut down overnight / Copilot stopped"

1. Activity log of the VM's resource group: who called `virtualMachines/deallocate` or `powerOff`? A service principal
   (no `@` in `caller`) means subscription governance automation (README Pitfall 16), not Copilot or Windows.
2. Inside the VM (Run Command): System log events 1074/6006/6008/41 and `Get-CimInstance Win32_OperatingSystem` boot time.
3. Copilot session state: `C:\Users\<user>\.copilot\session-state\<id>\events.jsonl`; the last event time shows whether it was
   still working. Resume with `copilot --resume <id>`.
4. Check the OS disk SKU (governance may have switched it to `Standard_LRS`). Changing it back needs a deallocate: only do
   it when `userSessions` is empty, and never work around or disable the governance automation itself; tell the user.

## Validation before committing

```powershell
terraform -chdir=terraform fmt -check; terraform -chdir=terraform validate
terraform -chdir=image/gallery validate
packer validate -var subscription_id=x -var 'allowed_inbound_ip_addresses=["203.0.113.10"]' image
powershell.exe -File scripts/setup-vm.ps1 -ResolveOnly         # checks every download URL, installs nothing
powershell.exe -File image/install-creative-apps.ps1 -ResolveOnly
```

Terraform providers and Packer have no `windows_arm64` builds: on ARM Windows use the `windows_amd64` binaries.
