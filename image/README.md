# Golden image

Windows 11 24H2 Enterprise, Trusted Launch, published to an Azure Compute Gallery by Packer.

| Included | How |
|---|---|
| Git, Node.js LTS, GitHub CLI, PowerShell 7 | `../scripts/setup-vm.ps1` |
| **Python 3** (all users, on `PATH`, `py` launcher) | python.org installer |
| **VS Code** (system installer) | update.code.visualstudio.com |
| **GitHub Copilot app** (machine-wide MSI) | github/app releases |
| **GitHub Copilot CLI** | `npm install -g @github/copilot` into `C:\Program Files\nodejs` |
| **Azure CLI**, **Az PowerShell** (Windows Terminal has the *Azure Cloud Shell* profile built in) | Microsoft MSIs |
| **Blender** (latest release) | download.blender.org MSI |
| **Epic Games Launcher** | Epic MSI |
| **Unreal Engine** *(optional)* | `unreal_engine_zip_url` |
| **DaVinci Resolve** *(optional)* | `davinci_resolve_installer_url` |
| Power: never sleep; no Windows Update auto-reboot while signed in | `../scripts/setup-vm.ps1` |

**Not** in the image, on purpose: Entra join and the AVD agent (added per VM by Terraform at deploy time), and the NVIDIA driver (the build VM has no GPU; the `NvidiaGpuDriverWindows` extension installs it at deploy time).

### Why Unreal Engine and DaVinci Resolve are optional inputs

- **Unreal Engine** can only be downloaded through the Epic Games Launcher with an Epic account. The image always has the launcher.
  To bake an engine in, install it once (launcher or source build), zip the engine folder (e.g. `UE_5.6`), upload it to a private
  blob and pass a SAS URL. The script extracts it to `C:\Program Files\Epic Games\` and runs `UEPrereqSetup_x64.exe`.
- **DaVinci Resolve** (free version) is behind a registration form on blackmagicdesign.com, so there's no stable public URL.
  Download the Windows zip once, upload it to a private blob and pass a SAS URL (a time-limited link from the Blackmagic site also works).

Both URL variables are `sensitive` in Packer and never logged.

Both apps need a GPU at runtime: deploy the image to `Standard_NV36ads_A10_v5` with `install_nvidia_gpu_driver = true` (needs NVadsA10v5 quota).

## Build

Requirements: Packer ≥ 1.10, Terraform ≥ 1.6, Azure CLI logged in (`az login --tenant <id>`). Building takes about 45–90 minutes.

```powershell
# 1. Gallery + image definition (once)
cd image/gallery
terraform init
terraform apply -var subscription_id=<sub-id>

# 2. Image version
cd ..
packer init .
$myIp = (Invoke-RestMethod https://api.ipify.org)
packer build -var subscription_id=<sub-id> -var "allowed_inbound_ip_addresses=[\"$myIp\"]" .

# optional creative apps: put them in a git-ignored *.pkrvars.hcl instead of the command line
#   davinci_resolve_installer_url = "https://<account>.blob.core.windows.net/installers/DaVinci_Resolve_20_Windows.zip?<sas>"
#   unreal_engine_zip_url         = "https://<account>.blob.core.windows.net/installers/UE_5.6.zip?<sas>"
packer build -var-file=secrets.pkrvars.hcl -var subscription_id=<sub-id> -var "allowed_inbound_ip_addresses=[\"$myIp\"]" .
```

Image versions are named `YYYY.MDD.hmm` (UTC build time). Rebuild monthly to pick up Windows and app updates.

## Use it

In `../terraform/terraform.tfvars`:

```hcl
gallery_image_version_id = "<image_definition_id output of image/gallery>"  # definition ID = always latest version
run_setup_script         = false                                            # tools are already in the image
```

Changing the image of an existing VM **replaces** the VM (and its OS disk). Back up anything under `C:\Users` first.

## Notes

- The image keeps `HKLM\SOFTWARE\Policies\Microsoft\WindowsStore\AutoDownload = 2` (Store auto-updates off). It's needed during the build,
  because Store app updates create per-user packages that make sysprep fail. Remove it, or manage it via Intune/GPO, if you want auto-updates.
- `build_vm_size` defaults to `Standard_D8ads_v5` (SCSI). The image definition supports SCSI **and** NVMe, so it deploys to NVMe-only
  sizes such as `Standard_D8ads_v7`.
- WinRM on the temporary build VM is only reachable from `allowed_inbound_ip_addresses`. Packer deletes the build resource group afterwards.
