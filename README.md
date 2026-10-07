# AVD Copilot VM

A personal **Azure Virtual Desktop** (Windows 11, Entra ID-joined) for running **GitHub Copilot CLI** unattended overnight.
Terraform for the desktop, Packer for an optional **golden image** with dev and creative tools.

> **TL;DR: if sign-in to the desktop fails, check this first.**
> The host pool's custom RDP properties must contain **`enablerdsaadauth:i:1`** (plus `targetisaadjoined:i:1`).
> Without it the client falls back to the legacy *Windows Security* password box, which can't do MFA/Conditional
> Access, and you get an endless *"Your credentials did not work"*, **even with the correct password**.
> Resetting the password or editing Conditional Access does **not** fix it (it took 3 hours to learn that).
>
> ```powershell
> az desktopvirtualization hostpool show -g <rg> -n <hostpool> --query customRdpProperty -o tsv
> ```

## What gets deployed (`terraform/`)

| Resource | Default | Notes |
|---|---|---|
| Resource group, VNet `10.20.0.0/24`, subnet, NSG | `rg-avd-copilot-neu`, North Europe (Dublin) | No public IP, no inbound rules. AVD uses reverse connect. |
| Host pool | `hp-copilot-personal` | Personal, persistent, automatic assignment. RDP properties enforced by a precondition. |
| Desktop app group + workspace | `dag-copilot-desktop`, `ws-copilot` | Desktop shows up as **Copilot VM**. |
| Session host VM | `vm-copilot-neu01` / `copilotvm01`, `Standard_D8ads_v7`, 256 GB Premium SSD | Trusted Launch, system-assigned identity, `license_type = Windows_Client`. |
| Extensions | AADLoginForWindows 2.2, DSC 2.83 (AVD agent), optional NVIDIA GPU driver | Entra join + host pool registration at deploy time. |
| Run command | `scripts/setup-vm.ps1` | Power settings + dev tools (see below). Skip with `run_setup_script = false` when using the golden image. |
| RBAC per user | Desktop Virtualization User (app group) + Virtual Machine User Login (VM) | **Both** are required. `grant_vm_admin_login = true` gives local admin. |

`scripts/setup-vm.ps1` (idempotent, no winget):

- never sleep or hibernate, and no Windows Update auto-reboot while a user is signed in;
- installs Git, Node.js LTS, GitHub CLI, PowerShell 7, Python 3, VS Code, Azure CLI, Az PowerShell, the GitHub Copilot app (machine-wide MSI) and GitHub Copilot CLI (`npm @github/copilot`).

Windows Terminal (inbox) has a built-in **Azure Cloud Shell** profile; Azure CLI and Az PowerShell cover local Azure work.

## Deploy

Prerequisites: Terraform ≥ 1.6, Azure CLI. You need Owner (or Contributor + User Access Administrator) on the subscription and read access to Entra users.

```powershell
az login --tenant <tenant-id>
az account show --query "{tenant:tenantId, sub:id, user:user.name}"   # make sure this is the right tenant!

cd terraform
copy terraform.tfvars.example terraform.tfvars   # fill in subscription_id, tenant_id, avd_user_upns
terraform init
terraform apply
```

Check the size is actually available in the region first. **Quota is not enough**: subscriptions can have `SkuNotAvailable` capacity restrictions:

```powershell
az vm list-skus -l northeurope --size Standard_D8ads_v7 --query "[].restrictions" -o json   # [] or [[]] = OK
```

## Connect

1. [Windows App](https://aka.ms/windowsapp) (or the web client `https://windows.cloud.microsoft/`).
2. Sign in with your **Entra UPN** (not the local admin), open **Copilot VM**.
3. You should get a modern Entra sign-in / SSO prompt. If you see the old grey *Windows Security* box, the RDP properties are wrong (see TL;DR).

The local admin (`terraform output -raw admin_password`) is break-glass only, e.g. for Run Command or serial console.

## Running Copilot overnight

- **Disconnect, don't sign out**: close the AVD window. Processes keep running in a disconnected session.
- Sign in once with `copilot` and then `/login` (or `gh auth login`) and trust your repo folders before leaving it alone.
- Unattended run: `copilot --autopilot --allow-all --max-ai-credits <n>`, or `-p "<task>"` for one-shot prompts.
  Only use `--allow-all` / `--yolo` on this isolated VM.
- `/remote` in Copilot CLI lets you watch or steer the session from GitHub web/mobile, so you don't need to open AVD.
- The VM has no auto-shutdown and *Start VM on connect* is off: it stays on (and billed) until you stop it.

## Golden image (`image/`)

Packer builds a Windows 11 24H2 Enterprise image (Trusted Launch) into an Azure Compute Gallery with everything above **plus Blender, the Epic Games Launcher, and optionally Unreal Engine and DaVinci Resolve**. See [image/README.md](image/README.md).

Deploy from it with `gallery_image_version_id = "<image definition id>"` and `run_setup_script = false`.

**GPU**: DaVinci Resolve and the Unreal Editor need a GPU. Use `vm_size = "Standard_NV36ads_A10_v5"` + `install_nvidia_gpu_driver = true`.
NVadsA10v5 quota defaults to **0** in many subscriptions: request it first (Portal → Quotas → Compute).
Blender, VS Code, Python and Copilot run fine on the default CPU size.

## Pitfalls (each of these cost real time)

1. **`enablerdsaadauth:i:1` missing**: endless *"credentials did not work"* on an Entra-joined host. See TL;DR. Don't reset passwords or touch Conditional Access to "fix" it.
2. **Both roles needed**: *Desktop Virtualization User* on the app group **and** *Virtual Machine User/Administrator Login* on the VM (or RG). With only the first, the desktop shows up but sign-in fails.
3. **AADLoginForWindows needs a managed identity** on the VM (system-assigned).
4. **Computer name ≤ 15 characters** (NetBIOS). `vm_name` can be longer, `computer_name` can't.
5. **Wrong tenant**: with several tenants/subscriptions, always check `az account show` before changing anything.
6. **Resetting your own admin password revokes your CLI tokens** (`AADSTS50173`). You'll need `az login --tenant <id> --use-device-code` again.
7. **CAE**: Graph calls can fail with `TokenCreatedWithOutdatedPolicies` while ARM still works. Re-login to the tenant.
8. **`az.cmd` mangles arguments** through cmd.exe: passwords with `^ & | < > % !`, empty strings (`--nsg ""`), and JMESPath filters (`[?...]`). Use files/`@file`, `-o json | ConvertFrom-Json`, or `az rest`.
9. **No `az` commands for session hosts / user sessions**: use REST, e.g.
   `az rest --method get --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.DesktopVirtualization/hostPools/<hp>/sessionHosts?api-version=2023-09-05"`.
10. **Registration token**: `GET` never returns it. Read it from the update/PATCH response (Terraform handles this). With the CLI, set `AZURE_CORE_OUTPUT_DISABLE_CONFIDENTIAL_DATA_MASKING=1`.
11. **`SkuNotAvailable` with free quota**: capacity restrictions are per subscription and region. Check `az vm list-skus --size <size>` (always pass `--size`, otherwise it's extremely slow).
12. **v6/v7 VM sizes are NVMe-only**: gallery image definitions must enable NVMe (`disk_controller_type_nvme_enabled`); Packer builds on a SCSI-capable v5 size.
13. **Run Command has a stale PATH**: tools installed in the same run aren't on `PATH`. Use full paths.
14. **Windows PowerShell 5.1** (Run Command / Packer): `Invoke-RestMethod` returns JSON arrays as one object (wrap in parentheses), native stderr + `$ErrorActionPreference='Stop'` aborts scripts, and SChannel may fail TLS to `registry.npmjs.org` (npm itself is fine).
15. **winget** isn't available under SYSTEM/WinRM: the scripts use direct downloads.

## Repo layout

```
terraform/            AVD host pool, workspace, session host VM, RBAC
scripts/setup-vm.ps1  power settings + dev tools (Run Command and Packer)
image/                Packer golden image + creative apps script
image/gallery/        Azure Compute Gallery + image definition (Terraform)
AGENTS.md             rules for AI coding agents working on this setup
```

Environment-specific notes (tenant/subscription IDs, incident log) belong in `*.local.md` / `local/`, which are git-ignored.
