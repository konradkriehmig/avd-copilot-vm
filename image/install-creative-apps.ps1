<#
.SYNOPSIS
    Golden image only: creative apps (Blender, Epic Games Launcher / Unreal Engine, DaVinci Resolve).
    Run by Packer after ../scripts/setup-vm.ps1.

.DESCRIPTION
    Inputs (environment variables, set from Packer variables):
      DAVINCI_RESOLVE_INSTALLER_URL  URL of the DaVinci Resolve Windows installer (.zip or .exe).
                                     Blackmagic requires a registration form, so there's no public
                                     direct link: download it once and host it privately (blob + SAS),
                                     or paste the time-limited link from the Blackmagic site. Empty = skip.
      UNREAL_ENGINE_ZIP_URL          URL of a .zip of an installed engine folder (e.g. UE_5.6).
                                     Unreal can only be downloaded via the Epic Games Launcher with an
                                     Epic login. Empty = launcher only, install the engine after first sign-in.

    DaVinci Resolve and the Unreal Editor need a GPU at runtime (NVadsA10_v5); the image itself can
    be built on a CPU VM.

.PARAMETER ResolveOnly
    Resolve and HEAD-check the public download URLs without installing anything.
#>
[CmdletBinding()]
param([switch]$ResolveOnly)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ([Net.ServicePointManager]::SecurityProtocol -ne 'SystemDefault') {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

# Use the VM's local temp disk (D:) for big downloads when there is one; it isn't captured in the image.
$Tmp = if (Test-Path 'D:\') { 'D:\avd-setup' } else { Join-Path $env:TEMP 'avd-setup' }
New-Item -ItemType Directory -Force -Path $Tmp | Out-Null
$Headers = @{ 'User-Agent' = 'avd-copilot-setup' }

function Write-Step([string]$Message) { Write-Output "[$(Get-Date -Format HH:mm:ss)] $Message" }

function Test-Url([string]$Url) {
    try { Invoke-WebRequest $Url -Method Head -Headers $Headers -UseBasicParsing -MaximumRedirection 10 | Out-Null; $true }
    catch { $false }
}

function Invoke-Installer([string]$Name, [string]$File, [string[]]$Arguments) {
    if ($File -like '*.msi') {
        $p = Start-Process msiexec.exe -ArgumentList (@('/i', "`"$File`"", '/qn', '/norestart') + $Arguments) -Wait -PassThru
    } else {
        $p = Start-Process $File -ArgumentList $Arguments -Wait -PassThru
    }
    if ($p.ExitCode -notin 0, 3010) { throw "$Name installer exited with code $($p.ExitCode)" }
}

function Get-BlenderUrl {
    $root = 'https://download.blender.org/release/'
    $series = [regex]::Matches((Invoke-WebRequest $root -Headers $Headers -UseBasicParsing).Content, 'href="Blender(\d+\.\d+)/"') |
        ForEach-Object { [version]$_.Groups[1].Value } | Sort-Object -Descending -Unique
    foreach ($s in $series) {
        $page = (Invoke-WebRequest "${root}Blender$s/" -Headers $Headers -UseBasicParsing).Content
        $msi = [regex]::Matches($page, 'href="(blender-(\d+\.\d+\.\d+)-windows-x64\.msi)"') |
            Sort-Object { [version]$_.Groups[2].Value } -Descending | Select-Object -First 1
        if ($msi) { return "${root}Blender$s/$($msi.Groups[1].Value)" }
    }
    throw 'No Blender Windows MSI found'
}

$EpicLauncherUrl = 'https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/EpicGamesLauncherInstaller.msi'

if ($ResolveOnly) {
    foreach ($u in @((Get-BlenderUrl), $EpicLauncherUrl)) {
        if (-not (Test-Url $u)) { throw "URL not reachable: $u" }
        Write-Step "OK <- $u"
    }
    return
}

# --- Blender ------------------------------------------------------------------------------------
if (Test-Path 'C:\Program Files\Blender Foundation\Blender*\blender.exe') {
    Write-Step 'Blender: already installed'
} else {
    $url = Get-BlenderUrl
    Write-Step "Blender <- $url"
    Invoke-WebRequest $url -OutFile "$Tmp\blender.msi" -Headers $Headers -UseBasicParsing
    Invoke-Installer 'Blender' "$Tmp\blender.msi" @('ALLUSERS=1')
    Write-Step 'Blender: installed'
}

# --- Epic Games Launcher (+ optional pre-installed Unreal Engine) -------------------------------
if (Test-Path 'C:\Program Files (x86)\Epic Games\Launcher') {
    Write-Step 'Epic Games Launcher: already installed'
} else {
    Write-Step "Epic Games Launcher <- $EpicLauncherUrl"
    Invoke-WebRequest $EpicLauncherUrl -OutFile "$Tmp\epic.msi" -Headers $Headers -UseBasicParsing
    Invoke-Installer 'Epic Games Launcher' "$Tmp\epic.msi" @()
    Write-Step 'Epic Games Launcher: installed'
}

if ($env:UNREAL_ENGINE_ZIP_URL) {
    $dest = 'C:\Program Files\Epic Games'
    Write-Step 'Unreal Engine <- UNREAL_ENGINE_ZIP_URL (this can take a while)'
    Invoke-WebRequest $env:UNREAL_ENGINE_ZIP_URL -OutFile "$Tmp\ue.zip" -Headers $Headers -UseBasicParsing
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    tar -xf "$Tmp\ue.zip" -C $dest   # bsdtar: much faster than Expand-Archive and handles zip64
    if ($LASTEXITCODE -ne 0) { throw "Extracting Unreal Engine failed ($LASTEXITCODE)" }
    Remove-Item "$Tmp\ue.zip" -Force
    $prereq = Get-ChildItem $dest -Recurse -Filter 'UEPrereqSetup_x64.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($prereq) { Invoke-Installer 'UE prerequisites' $prereq.FullName @('/quiet', '/norestart') }
    Write-Step "Unreal Engine: extracted to $dest"
} else {
    Write-Step 'Unreal Engine: UNREAL_ENGINE_ZIP_URL not set, install the engine from the Epic Games Launcher after sign-in'
}

# --- DaVinci Resolve (optional) -----------------------------------------------------------------
if (Test-Path 'C:\Program Files\Blackmagic Design\DaVinci Resolve\Resolve.exe') {
    Write-Step 'DaVinci Resolve: already installed'
} elseif ($env:DAVINCI_RESOLVE_INSTALLER_URL) {
    Write-Step 'DaVinci Resolve <- DAVINCI_RESOLVE_INSTALLER_URL'
    $isZip = ([uri]$env:DAVINCI_RESOLVE_INSTALLER_URL).AbsolutePath -like '*.zip'
    $download = if ($isZip) { "$Tmp\resolve.zip" } else { "$Tmp\resolve-setup.exe" }
    Invoke-WebRequest $env:DAVINCI_RESOLVE_INSTALLER_URL -OutFile $download -Headers $Headers -UseBasicParsing
    if ($isZip) {
        New-Item -ItemType Directory -Force -Path "$Tmp\resolve" | Out-Null
        tar -xf $download -C "$Tmp\resolve"
        $exe = Get-ChildItem "$Tmp\resolve" -Recurse -Filter 'DaVinci_Resolve*.exe' | Sort-Object Length -Descending | Select-Object -First 1
        if (-not $exe) { throw 'No DaVinci_Resolve*.exe found in the zip' }
        $download = $exe.FullName
    }
    # Silent switches as documented by the community (Blackmagic doesn't publish them).
    Invoke-Installer 'DaVinci Resolve' $download @('/i', '/q', '/noreboot')
    Write-Step 'DaVinci Resolve: installed'
} else {
    Write-Step 'DaVinci Resolve: DAVINCI_RESOLVE_INSTALLER_URL not set, skipped'
}

Write-Step 'Done.'
