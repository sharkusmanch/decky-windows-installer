#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Install or uninstall Decky Loader on Windows.

.DESCRIPTION
    Sets up Decky Loader for Steam Big Picture Mode on Windows:
      1. Enables CEF remote debugging in Steam (.cef-enable-remote-debugging)
      2. Creates %USERPROFILE%\homebrew directory layout
      3. Downloads (or uses local) PluginLoader Win.zip
      4. Verifies the zip (magic bytes, optional SHA256)
      5. Extracts loader binaries into homebrew\services
      6. Creates a "Steam (Decky)" desktop shortcut with -dev
      7. Optionally registers PluginLoader_noconsole.exe in Startup

    Records what it did in %USERPROFILE%\homebrew\.install-manifest.json
    so -Uninstall can reverse exactly the changes that were made.

    Decky Loader is unofficial on Windows. The Decky team does not support
    Windows installations.

.PARAMETER Uninstall
    Reverse a previous installation using the manifest.

.PARAMETER Source
    Local zip path or HTTP(S) URL of PluginLoader Win.zip. Defaults to the
    upstream Decky nightly via nightly.link. To install a known-good fork
    build (e.g. suchmememanyskill's), pass that URL or a local file.

.PARAMETER ExpectedSha256
    Verify the download matches this SHA256 hash before extracting.
    Aborts on mismatch. Recommended when pinning to a specific build.

.PARAMETER NoAutoStart
    Skip the Startup folder shortcut. PluginLoader will not auto-launch
    on login; you'll start it manually from homebrew\services.

.PARAMETER NoLaunch
    Don't start PluginLoader at the end of installation.

.PARAMETER PurgeUserData
    On uninstall, also delete %USERPROFILE%\homebrew (plugins, settings,
    themes). Default uninstall preserves user data.

.PARAMETER Force
    Skip the "Steam is running" guard.

.EXAMPLE
    .\Install-DeckyLoader.ps1
    Install with defaults (downloads upstream nightly).

.EXAMPLE
    .\Install-DeckyLoader.ps1 -Source 'C:\Downloads\PluginLoader_Win.zip' -ExpectedSha256 'A1B2...'
    Install from a local zip with hash verification.

.EXAMPLE
    .\Install-DeckyLoader.ps1 -Uninstall
    Reverse the install. Plugin data in homebrew\plugins is preserved.

.EXAMPLE
    .\Install-DeckyLoader.ps1 -Uninstall -PurgeUserData
    Reverse the install and delete the entire homebrew directory.
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [string]$Source = 'https://nightly.link/SteamDeckHomebrew/decky-loader/workflows/build-win/main/PluginLoader%20Win.zip',
    [string]$ExpectedSha256,
    [switch]$NoAutoStart,
    [switch]$NoLaunch,
    [switch]$PurgeUserData,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# --- paths
$HomebrewDir   = Join-Path $env:USERPROFILE 'homebrew'
$ServicesDir   = Join-Path $HomebrewDir 'services'
$ManifestPath  = Join-Path $HomebrewDir '.install-manifest.json'
$LogDir        = Join-Path $env:LOCALAPPDATA 'decky-installer'
$LogPath       = Join-Path $LogDir 'install.log'
$DesktopPath   = [Environment]::GetFolderPath('Desktop')
$StartupPath   = [Environment]::GetFolderPath('Startup')
$ShortcutDecky = Join-Path $DesktopPath 'Steam (Decky).lnk'
$ShortcutAuto  = Join-Path $StartupPath 'Decky Loader.lnk'

# --- helpers
function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    switch ($Level) {
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line }
    }
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    Add-Content -Path $LogPath -Value $line
}

function Get-SteamPath {
    foreach ($p in @(
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam',
        'HKCU:\SOFTWARE\Valve\Steam'
    )) {
        $v = (Get-ItemProperty -Path $p -Name 'InstallPath' -ErrorAction SilentlyContinue).InstallPath
        if ($v -and (Test-Path $v)) { return $v }
    }
    $default = Join-Path ${env:ProgramFiles(x86)} 'Steam'
    if (Test-Path $default) { return $default }
    throw 'Could not find Steam installation. Is Steam installed?'
}

function Test-SteamRunning {
    [bool](Get-Process -Name 'steam' -ErrorAction SilentlyContinue)
}

function Stop-PluginLoaders {
    foreach ($name in 'PluginLoader','PluginLoader_noconsole') {
        Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Log "Stopping $($_.ProcessName) (pid $($_.Id))"
            try { $_ | Stop-Process -Force -ErrorAction Stop }
            catch { Write-Log "Could not stop $($_.ProcessName): $($_.Exception.Message)" 'WARN' }
        }
    }
}

function New-Shortcut {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$TargetPath,
        [string]$Arguments,
        [string]$WorkingDirectory,
        [string]$Description
    )
    $ws = New-Object -ComObject WScript.Shell
    try {
        $sc = $ws.CreateShortcut($Path)
        $sc.TargetPath = $TargetPath
        if ($Arguments)        { $sc.Arguments = $Arguments }
        if ($WorkingDirectory) { $sc.WorkingDirectory = $WorkingDirectory }
        if ($Description)      { $sc.Description = $Description }
        $sc.Save()
    } finally {
        [Runtime.InteropServices.Marshal]::ReleaseComObject($ws) | Out-Null
    }
}

function Get-PluginLoaderZip {
    param([string]$Source)
    if (Test-Path -LiteralPath $Source -PathType Leaf) {
        Write-Log "Using local zip: $Source"
        return (Resolve-Path $Source).Path
    }
    $tmp = Join-Path $env:TEMP "PluginLoader-$(Get-Date -Format yyyyMMddHHmmss).zip"
    Write-Log "Downloading: $Source"
    $progressBackup = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $Source -OutFile $tmp -UseBasicParsing -UserAgent 'decky-installer-ps/1.0'
    } finally {
        $ProgressPreference = $progressBackup
    }
    if (-not (Test-Path $tmp)) { throw "Download failed: $Source" }
    $size = (Get-Item $tmp).Length
    if ($size -lt 100KB) { throw "Download too small ($size bytes) - likely an error page, not a zip." }
    return $tmp
}

function Test-IsZip {
    param([string]$Path)
    $bytes = [byte[]]::new(4)
    $fs = [IO.File]::OpenRead($Path)
    try { $null = $fs.Read($bytes, 0, 4) } finally { $fs.Dispose() }
    # ZIP magic: PK\x03\x04
    if (-not ($bytes[0] -eq 0x50 -and $bytes[1] -eq 0x4B -and $bytes[2] -eq 0x03 -and $bytes[3] -eq 0x04)) {
        throw "Not a valid zip file (bad magic bytes)"
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try { if ($z.Entries.Count -lt 1) { throw "Zip archive is empty" } }
    finally { $z.Dispose() }
}

function Invoke-Install {
    Write-Log '== Decky Loader install =='

    $steamPath = Get-SteamPath
    Write-Log "Steam path: $steamPath"
    $steamExe = Join-Path $steamPath 'steam.exe'
    if (-not (Test-Path $steamExe)) { throw "steam.exe not found at $steamExe" }

    if ((Test-SteamRunning) -and -not $Force) {
        throw 'Steam is running. Close Steam first, or re-run with -Force.'
    }

    Stop-PluginLoaders

    $zipPath = Get-PluginLoaderZip -Source $Source
    Test-IsZip -Path $zipPath
    $sha = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash
    Write-Log "SHA256: $sha"
    if ($ExpectedSha256 -and ($sha -ne $ExpectedSha256.ToUpper())) {
        throw "SHA256 mismatch. Expected $($ExpectedSha256.ToUpper()), got $sha"
    }

    foreach ($d in $HomebrewDir, $ServicesDir) {
        if (-not (Test-Path $d)) {
            Write-Log "Creating $d"
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
    }

    $cefFlag = Join-Path $steamPath '.cef-enable-remote-debugging'
    $createdCef = -not (Test-Path $cefFlag)
    if ($createdCef) {
        Write-Log "Creating $cefFlag"
        New-Item -ItemType File -Path $cefFlag -Force | Out-Null
    } else {
        Write-Log "$cefFlag already exists"
    }

    Write-Log "Extracting to $ServicesDir"
    Expand-Archive -Path $zipPath -DestinationPath $ServicesDir -Force

    if ($zipPath.StartsWith($env:TEMP)) {
        Remove-Item $zipPath -ErrorAction SilentlyContinue
    }

    $pluginLoaderNoConsole = Join-Path $ServicesDir 'PluginLoader_noconsole.exe'
    if (-not (Test-Path $pluginLoaderNoConsole)) {
        throw "Expected PluginLoader_noconsole.exe at $pluginLoaderNoConsole - extraction may have failed."
    }

    Write-Log "Creating $ShortcutDecky"
    New-Shortcut -Path $ShortcutDecky -TargetPath $steamExe `
        -Arguments '-dev' -WorkingDirectory $steamPath `
        -Description 'Launch Steam with Decky Loader'

    if (-not $NoAutoStart) {
        Write-Log "Creating $ShortcutAuto"
        New-Shortcut -Path $ShortcutAuto -TargetPath $pluginLoaderNoConsole `
            -WorkingDirectory $ServicesDir `
            -Description 'Decky Loader Autostart'
    } else {
        Write-Log 'Skipping Startup folder shortcut (-NoAutoStart)'
    }

    $manifest = [ordered]@{
        version           = 1
        installedAt       = (Get-Date).ToString('o')
        source            = $Source
        sha256            = $sha
        steamPath         = $steamPath
        servicesDir       = $ServicesDir
        deckyShortcut     = $ShortcutDecky
        autoStartShortcut = if ($NoAutoStart) { $null } else { $ShortcutAuto }
        cefDebugFile      = $cefFlag
        createdCefFile    = $createdCef
    }
    $manifest | ConvertTo-Json -Depth 4 | Set-Content -Path $ManifestPath -Encoding UTF8
    Write-Log "Manifest written: $ManifestPath"

    if (-not $NoLaunch) {
        Write-Log "Launching $pluginLoaderNoConsole"
        Start-Process -FilePath $pluginLoaderNoConsole -WorkingDirectory $ServicesDir
    }

    Write-Log '== Install complete =='
    Write-Host ''
    Write-Host 'Next steps:' -ForegroundColor Cyan
    Write-Host '  1. Make sure Steam is closed.'
    Write-Host '  2. Launch Steam via the new "Steam (Decky)" desktop shortcut.'
    Write-Host '  3. In Big Picture Mode: STEAM button + A to open the Decky menu.'
    Write-Host ''
    Write-Host 'Note: Windows Defender / SmartScreen may flag PluginLoader.exe.' -ForegroundColor Yellow
    Write-Host '      You may need to add an exclusion for homebrew\services.' -ForegroundColor Yellow
}

function Invoke-Uninstall {
    Write-Log '== Decky Loader uninstall =='

    if (Test-Path $ManifestPath) {
        $manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
    } else {
        Write-Log "No manifest at $ManifestPath. Best-effort removal of known artifacts." 'WARN'
        $manifest = [pscustomobject]@{
            servicesDir       = $ServicesDir
            deckyShortcut     = $ShortcutDecky
            autoStartShortcut = $ShortcutAuto
            cefDebugFile      = $null
            createdCefFile    = $false
        }
    }

    Stop-PluginLoaders

    foreach ($prop in 'deckyShortcut','autoStartShortcut') {
        $p = $manifest.$prop
        if ($p -and (Test-Path $p)) {
            Write-Log "Removing $p"
            Remove-Item $p -Force -ErrorAction SilentlyContinue
        }
    }

    if ($manifest.createdCefFile -and $manifest.cefDebugFile -and (Test-Path $manifest.cefDebugFile)) {
        Write-Log "Removing $($manifest.cefDebugFile)"
        Remove-Item $manifest.cefDebugFile -Force -ErrorAction SilentlyContinue
    }

    if ($PurgeUserData) {
        if (Test-Path $HomebrewDir) {
            Write-Log "Purging $HomebrewDir (user data included)" 'WARN'
            Remove-Item $HomebrewDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    } else {
        $svc = $manifest.servicesDir
        if ($svc -and (Test-Path $svc)) {
            Write-Log "Removing PluginLoader binaries from $svc (plugin data preserved)"
            foreach ($exe in 'PluginLoader.exe','PluginLoader_noconsole.exe') {
                $f = Join-Path $svc $exe
                if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
            }
        }
        if (Test-Path $ManifestPath) { Remove-Item $ManifestPath -Force -ErrorAction SilentlyContinue }
    }

    Write-Log '== Uninstall complete =='
    Write-Host ''
    Write-Host 'To remove the -dev flag from your Steam launch, just use Steam normally -' -ForegroundColor Cyan
    Write-Host 'the desktop shortcut has been removed but your other Steam shortcuts are unchanged.' -ForegroundColor Cyan
}

# --- main
try {
    if ($Uninstall) { Invoke-Uninstall } else { Invoke-Install }
} catch {
    Write-Log $_.Exception.Message 'ERROR'
    exit 1
}
