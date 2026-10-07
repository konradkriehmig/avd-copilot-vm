<#
.SYNOPSIS
    Prepares an AVD session host for long-running GitHub Copilot sessions.

.DESCRIPTION
    - Power: never sleep / hibernate, no Windows Update auto-reboot while signed in
      (overnight runs must not be interrupted)
    - Dev tools: Git, Node.js LTS, GitHub CLI, PowerShell 7, Python 3, VS Code,
      Azure CLI, Az PowerShell, GitHub Copilot app, GitHub Copilot CLI

    Idempotent: already-installed tools are skipped. Runs as SYSTEM (Azure run command,
    see ../terraform/main.tf) or as admin over WinRM (Packer, see ../image).
    winget is deliberately NOT used: it isn't available under SYSTEM / WinRM.

    Windows Terminal (inbox on Windows 11) has a built-in "Azure Cloud Shell" profile;
    Azure CLI + Az PowerShell cover local Azure work.

.PARAMETER ResolveOnly
    Resolve and HEAD-check every download URL without installing anything.
    Use it to check the script still works:  .\setup-vm.ps1 -ResolveOnly
#>
[CmdletBinding()]
param([switch]$ResolveOnly)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is much slower with the progress bar
if ([Net.ServicePointManager]::SecurityProtocol -ne 'SystemDefault') {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

$Tmp = Join-Path $env:TEMP 'avd-setup'
New-Item -ItemType Directory -Force -Path $Tmp | Out-Null
$Headers = @{ 'User-Agent' = 'avd-copilot-setup' }

function Write-Step([string]$Message) { Write-Output "[$(Get-Date -Format HH:mm:ss)] $Message" }

function Test-Url([string]$Url) {
    try { Invoke-WebRequest $Url -Method Head -Headers $Headers -UseBasicParsing -MaximumRedirection 10 | Out-Null; $true }
    catch { $false }
}

function Get-GitHubAssetUrl([string]$Repo, [string]$Pattern) {
    $rel = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" -Headers $Headers
    $asset = $rel.assets | Where-Object { $_.name -match $Pattern } | Select-Object -First 1
    if (-not $asset) { throw "No asset matching '$Pattern' in $Repo $($rel.tag_name)" }
    $asset.browser_download_url
}

function Get-PythonUrl {
    # Newest 3.x with a Windows x64 installer (pre-release folders have no final installer and are skipped).
    # Pin a minor version with $env:PYTHON_VERSION = '3.13'.
    $listing = Invoke-WebRequest 'https://www.python.org/ftp/python/' -Headers $Headers -UseBasicParsing
    $versions = [regex]::Matches($listing.Content, 'href="(3\.\d+\.\d+)/"') |
        ForEach-Object { [version]$_.Groups[1].Value } | Sort-Object -Descending -Unique
    if ($env:PYTHON_VERSION) { $versions = $versions | Where-Object { "$_".StartsWith("$($env:PYTHON_VERSION).") } }
    foreach ($v in $versions) {
        $url = "https://www.python.org/ftp/python/$v/python-$v-amd64.exe"
        if (Test-Url $url) { return $url }
    }
    throw 'No Python Windows installer found'
}

function Install-App {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$InstalledPath,   # wildcards allowed
        [Parameter(Mandatory)] [scriptblock]$ResolveUrl,
        [Parameter(Mandatory)] [string]$FileName,
        [string[]]$Arguments = @()
    )
    if (-not $ResolveOnly -and (Test-Path $InstalledPath)) { Write-Step "${Name}: already installed"; return }

    $url = & $ResolveUrl
    Write-Step "$Name <- $url"
    if ($ResolveOnly) {
        if (-not (Test-Url $url)) { throw "${Name}: URL not reachable: $url" }
        return
    }

    $file = Join-Path $Tmp $FileName
    Invoke-WebRequest $url -OutFile $file -Headers $Headers -UseBasicParsing
    if ($file -like '*.msi') {
        $p = Start-Process msiexec.exe -ArgumentList (@('/i', "`"$file`"", '/qn', '/norestart') + $Arguments) -Wait -PassThru
    } else {
        $p = Start-Process $file -ArgumentList $Arguments -Wait -PassThru
    }
    if ($p.ExitCode -notin 0, 3010) { throw "$Name installer exited with code $($p.ExitCode)" }
    if (-not (Test-Path $InstalledPath)) { throw "${Name}: installer succeeded but $InstalledPath not found" }
    Write-Step "${Name}: installed"
}

# --- Power: overnight runs must never be suspended -------------------------------------------
if (-not $ResolveOnly) {
    Write-Step 'Power: disabling sleep, hibernate and display timeout'
    powercfg /change standby-timeout-ac 0
    powercfg /change hibernate-timeout-ac 0
    powercfg /change monitor-timeout-ac 0
    powercfg /hibernate off

    # Windows Update must not reboot the VM while someone is signed in (a disconnected session counts).
    Write-Step 'Windows Update: no automatic reboot while a user is signed in'
    $au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    New-Item -Path $au -Force | Out-Null
    Set-ItemProperty -Path $au -Name NoAutoRebootWithLoggedOnUsers -Value 1 -Type DWord
}

# --- Dev tools ----------------------------------------------------------------------------------
Install-App -Name 'Git' -InstalledPath 'C:\Program Files\Git\cmd\git.exe' -FileName 'git.exe' `
    -ResolveUrl { Get-GitHubAssetUrl 'git-for-windows/git' '^Git-[\d\.]+-64-bit\.exe$' } `
    -Arguments '/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-', '/SUPPRESSMSGBOXES'

Install-App -Name 'Node.js LTS' -InstalledPath 'C:\Program Files\nodejs\node.exe' -FileName 'node.msi' `
    -ResolveUrl {
        # Parentheses force enumeration: Windows PowerShell 5.1 emits a JSON array as one object.
        $v = ((Invoke-RestMethod 'https://nodejs.org/dist/index.json' -Headers $Headers) | Where-Object { $_.lts } | Select-Object -First 1).version
        "https://nodejs.org/dist/$v/node-$v-x64.msi"
    }

Install-App -Name 'GitHub CLI' -InstalledPath 'C:\Program Files\GitHub CLI\gh.exe' -FileName 'gh.msi' `
    -ResolveUrl { Get-GitHubAssetUrl 'cli/cli' '_windows_amd64\.msi$' }

# Copilot CLI on Windows needs PowerShell 6+.
Install-App -Name 'PowerShell 7' -InstalledPath 'C:\Program Files\PowerShell\7\pwsh.exe' -FileName 'pwsh.msi' `
    -ResolveUrl { Get-GitHubAssetUrl 'PowerShell/PowerShell' '^PowerShell-[\d\.]+-win-x64\.msi$' } `
    -Arguments 'ADD_PATH=1', 'REGISTER_MANIFEST=1', 'ENABLE_PSREMOTING=0', 'USE_MU=1', 'ENABLE_MU=1'

Install-App -Name 'Python 3' -InstalledPath 'C:\Program Files\Python3*\python.exe' -FileName 'python.exe' `
    -ResolveUrl { Get-PythonUrl } `
    -Arguments '/quiet', 'InstallAllUsers=1', 'PrependPath=1', 'Include_test=0', 'Include_launcher=1', 'InstallLauncherAllUsers=1'

Install-App -Name 'VS Code' -InstalledPath 'C:\Program Files\Microsoft VS Code\Code.exe' -FileName 'vscode.exe' `
    -ResolveUrl { 'https://update.code.visualstudio.com/latest/win32-x64/stable' } `
    -Arguments '/VERYSILENT', '/NORESTART', '/MERGETASKS=!runcode,addcontextmenufiles,addcontextmenufolders,associatewithfiles,addtopath'

Install-App -Name 'Azure CLI' -InstalledPath 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd' -FileName 'azcli.msi' `
    -ResolveUrl { 'https://aka.ms/installazurecliwindowsx64' }

Install-App -Name 'Az PowerShell' -InstalledPath 'C:\Program Files\WindowsPowerShell\Modules\Az.Accounts' -FileName 'az-ps.msi' `
    -ResolveUrl { Get-GitHubAssetUrl 'Azure/azure-powershell' '^Az-Cmdlets-[\d\.]+-x64\.msi$' }

# Machine-wide MSI (the .exe variant is per-user and would break sysprep on a golden image).
Install-App -Name 'GitHub Copilot app' -InstalledPath 'C:\Program Files\GitHub Copilot' -FileName 'copilot-app.msi' `
    -ResolveUrl { 'https://github.com/github/app/releases/latest/download/GitHub-Copilot-windows-x64.msi' }

# --- GitHub Copilot CLI (npm) -------------------------------------------------------------------
# A plain `npm i -g` as SYSTEM lands in the SYSTEM profile; install next to node.exe so it's on every user's PATH.
# No Invoke-RestMethod to registry.npmjs.org here: Windows' TLS stack (SChannel) can fail the handshake with it,
# npm itself uses OpenSSL and works.
Write-Step 'GitHub Copilot CLI <- npm @github/copilot'
if ($ResolveOnly) {
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        $ErrorActionPreference = 'Continue'
        $copilotVersion = & npm view '@github/copilot' version 2>$null
        $ErrorActionPreference = 'Stop'
        if (-not $copilotVersion) { throw 'GitHub Copilot CLI: npm view @github/copilot failed' }
        Write-Step "GitHub Copilot CLI: latest is $copilotVersion"
    } else {
        Write-Step 'GitHub Copilot CLI: npm not found locally, skipped check'
    }
} else {
    if (Test-Path 'C:\Program Files\nodejs\copilot.cmd') {
        Write-Step 'GitHub Copilot CLI: already installed'
    } else {
        $env:Path = "C:\Program Files\nodejs;$env:Path"   # the run-command process PATH predates the Node install
        # npm writes warnings to stderr; under Windows PowerShell 5.1 + 'Stop' that would abort the script.
        $ErrorActionPreference = 'Continue'
        & 'C:\Program Files\nodejs\npm.cmd' install -g --prefix 'C:\Program Files\nodejs' '@github/copilot' 2>&1 | ForEach-Object { "$_" }
        $npmExit = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        if ($npmExit -ne 0) { throw "npm install @github/copilot failed with exit code $npmExit" }
        Write-Step 'GitHub Copilot CLI: installed'
    }
}

Write-Step 'Done.'
