#Requires -Version 5.1
<#
.SYNOPSIS
    Install or uninstall Decky Loader on Windows.

.DESCRIPTION
    Sets up Decky Loader for Steam Big Picture Mode on Windows. Records what
    it did in %USERPROFILE%\homebrew\.install-manifest.json so -Uninstall
    reverses exactly the changes that were made.

    Decky Loader is unofficial on Windows. The Decky team does not support
    Windows installations.

    Administrator privileges are required only when Steam is installed in a
    location the current user cannot write to (typically Program Files (x86)).
    The script detects this at runtime and exits with a clear message if so.

.PARAMETER Uninstall
    Reverse a previous installation using the manifest.

.PARAMETER Source
    Local zip path or HTTP(S) URL of PluginLoader Win.zip. Defaults to the
    upstream Decky nightly via nightly.link. To install a known-good fork
    build, pass that URL or a local file.

.PARAMETER ExpectedSha256
    Verify the download matches this SHA256 hash before extracting. Aborts
    on mismatch. Required when -Source is a URL unless -AllowUnpinned is
    also specified. Local zip sources do not need this.

.PARAMETER AllowUnpinned
    Permit URL downloads without SHA256 verification. Discouraged - you
    are then trusting the source URL and TLS chain to have served the
    intended bytes.

.PARAMETER NoAutoStart
    Skip the Startup folder shortcut.

.PARAMETER NoLaunch
    Don't start PluginLoader at the end of installation.

.PARAMETER PurgeUserData
    On uninstall, also delete %USERPROFILE%\homebrew (plugins, settings,
    themes). Default uninstall preserves user data. Refuses to recurse
    across reparse points (junctions / symlinks).

.PARAMETER Force
    Skip the "Steam is running" guard.

.EXAMPLE
    .\Install-DeckyLoader.ps1 -Source 'C:\Downloads\PluginLoader Win.zip'
    Install from a local zip (no SHA256 needed for local files).

.EXAMPLE
    .\Install-DeckyLoader.ps1 -ExpectedSha256 'A1B2C3...'
    Install from default URL with integrity verification.

.EXAMPLE
    .\Install-DeckyLoader.ps1 -AllowUnpinned
    Install from default URL with no integrity check (not recommended).

.EXAMPLE
    .\Install-DeckyLoader.ps1 -Uninstall -WhatIf
    Show exactly what an uninstall would remove, without removing it.

.EXAMPLE
    .\Install-DeckyLoader.ps1 -Uninstall -PurgeUserData
    Reverse the install and delete the entire homebrew directory.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
param(
    [switch]$Uninstall,
    [string]$Source = 'https://nightly.link/SteamDeckHomebrew/decky-loader/workflows/build-win/main/PluginLoader%20Win.zip',
    [string]$ExpectedSha256,
    [switch]$AllowUnpinned,
    [switch]$NoAutoStart,
    [switch]$NoLaunch,
    [switch]$PurgeUserData,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# --- paths
$HomebrewDir   = Join-Path $env:USERPROFILE 'homebrew'
$ServicesDir   = Join-Path $HomebrewDir 'services'
$LogDir        = Join-Path $env:LOCALAPPDATA 'decky-installer'
$LogPath       = Join-Path $LogDir 'install.log'
# Manifest lives outside homebrew\ because Decky's settings.py migrates
# dotfiles in homebrew\ into homebrew\settings\ on startup, which collides
# with our manifest and crashes Decky.
$ManifestPath  = Join-Path $LogDir 'install-manifest.json'
$DesktopPath   = [Environment]::GetFolderPath('Desktop')
$StartupPath   = [Environment]::GetFolderPath('Startup')
$ShortcutDecky = Join-Path $DesktopPath 'Steam (Decky).lnk'
$ShortcutAuto  = Join-Path $StartupPath 'Decky Loader.lnk'

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

# --- helpers

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','DEBUG')][string]$Level = 'INFO'
    )
    $ts = Get-Date -Format 'o'
    $line = "[$ts] [$Level] $Message"
    switch ($Level) {
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'DEBUG' { Write-Verbose $line }
        default { Write-Host $line }
    }
    Add-Content -Path $LogPath -Value $line
}

function Test-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-WriteAccess {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    $probe = Join-Path $Path ".decky-installer-write-test-$([guid]::NewGuid().Guid)"
    try {
        [IO.File]::WriteAllText($probe, '')
        Remove-Item $probe -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        return $false
    }
}

function Test-PathUnderRoot {
    param([string]$Candidate, [string[]]$Roots)
    if ([string]::IsNullOrWhiteSpace($Candidate)) { return $false }
    try { $abs = [IO.Path]::GetFullPath($Candidate) } catch { return $false }
    $sep = [IO.Path]::DirectorySeparatorChar
    foreach ($root in $Roots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        try { $absRoot = [IO.Path]::GetFullPath($root) } catch { continue }
        $absRootTrimmed = $absRoot.TrimEnd($sep)
        if (-not $absRoot.EndsWith($sep)) { $absRoot += $sep }
        if ($abs.StartsWith($absRoot, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ([string]::Equals($abs, $absRootTrimmed, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-ExpectedSha256Format {
    param([Parameter(Mandatory)][string]$Value)
    $v = $Value.Trim() -replace '^0x',''
    if ($v -notmatch '^[0-9A-Fa-f]{64}$') {
        throw "ExpectedSha256 is not a valid 64-character hex string."
    }
    return $v.ToUpper()
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
    foreach ($name in 'steam','steamwebhelper','steamservice') {
        if (Get-Process -Name $name -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}

function Stop-PluginLoader {
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

function Test-ZipFile {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $bytes = [byte[]]::new(4)
        $fs = [IO.File]::OpenRead($Path)
        try { $null = $fs.Read($bytes, 0, 4) } finally { $fs.Dispose() }
        if (-not ($bytes[0] -eq 0x50 -and $bytes[1] -eq 0x4B -and $bytes[2] -eq 0x03 -and $bytes[3] -eq 0x04)) {
            return $false
        }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $z = [IO.Compression.ZipFile]::OpenRead($Path)
        try { return ($z.Entries.Count -gt 0) } finally { $z.Dispose() }
    } catch {
        return $false
    }
}

function Expand-ZipSafe {
    # Zip-Slip-checked extraction. Validates each entry's resolved path is
    # under $Destination before extracting, so a malicious archive cannot
    # write outside the target directory via ..\ entries.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Destination
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (-not (Test-Path $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    $absDest = [IO.Path]::GetFullPath($Destination)
    $sep = [IO.Path]::DirectorySeparatorChar
    if (-not $absDest.EndsWith($sep)) { $absDest += $sep }

    $z = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($entry in $z.Entries) {
            $candidate = [IO.Path]::GetFullPath((Join-Path $Destination $entry.FullName))
            if (-not $candidate.StartsWith($absDest, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing to extract: zip entry '$($entry.FullName)' would escape $Destination"
            }
        }
        foreach ($entry in $z.Entries) {
            $target = [IO.Path]::GetFullPath((Join-Path $Destination $entry.FullName))
            $isDir  = ($entry.FullName -match '[\\/]$')
            if ($isDir) {
                if (-not (Test-Path $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
                continue
            }
            $targetDir = Split-Path -Parent $target
            if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    } finally {
        $z.Dispose()
    }
}

function Save-Manifest {
    param([Parameter(Mandatory)][object]$Manifest)
    if ($WhatIfPreference) {
        Write-Log "WhatIf: would write manifest to $ManifestPath" 'DEBUG'
        return
    }
    $json = $Manifest | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText($ManifestPath, $json, [Text.UTF8Encoding]::new($false))
}

function Read-Manifest {
    if (-not (Test-Path $ManifestPath)) { return $null }
    try {
        return Get-Content $ManifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Log "Manifest at $ManifestPath is unreadable: $($_.Exception.Message)" 'WARN'
        return $null
    }
}

function Show-BinaryProvenance {
    param([Parameter(Mandatory)][string]$Path)
    $hash = (Get-FileHash -Path $Path -Algorithm SHA256).Hash
    Write-Log "  $((Split-Path -Leaf $Path)) SHA256: $hash"
    try {
        $sig = Get-AuthenticodeSignature -FilePath $Path
        Write-Log "  Signature: $($sig.Status)"
        if ($sig.SignerCertificate) {
            Write-Log "  Signer:    $($sig.SignerCertificate.Subject)"
        } else {
            Write-Log '  Signer:    <unsigned>' 'WARN'
        }
    } catch {
        Write-Log "  Could not read Authenticode: $($_.Exception.Message)" 'WARN'
    }
}

function Resolve-PluginLoaderZip {
    param([Parameter(Mandatory)][string]$Source)
    if (Test-Path -LiteralPath $Source -PathType Leaf) {
        Write-Log "Using local zip: $Source"
        return [pscustomobject]@{
            Path   = (Resolve-Path -LiteralPath $Source).Path
            IsTemp = $false
            IsUrl  = $false
        }
    }
    $tmp = Join-Path $env:TEMP "PluginLoader-$(Get-Date -Format yyyyMMddHHmmss)-$([guid]::NewGuid().ToString().Substring(0,8)).zip"
    Write-Log "Downloading: $Source"
    Write-Log "  to: $tmp"
    $progressBackup = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $Source -OutFile $tmp -UseBasicParsing `
            -UserAgent 'decky-installer-ps/2.0' -MaximumRedirection 5
    } finally {
        $ProgressPreference = $progressBackup
    }
    if (-not (Test-Path $tmp)) { throw "Download failed: $Source" }
    $size = (Get-Item $tmp).Length
    if ($size -lt 100KB) {
        Remove-Item $tmp -ErrorAction SilentlyContinue
        throw "Download too small ($size bytes) - likely an error page, not a zip."
    }
    return [pscustomobject]@{ Path = $tmp; IsTemp = $true; IsUrl = $true }
}

function Remove-DirectorySafe {
    # Removes $Path recursively but refuses to traverse reparse points
    # (junctions / symlinks), which could redirect deletion outside the
    # intended subtree.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return }
    $root = Get-Item -Path $Path -Force
    if (($root.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to remove reparse point at $Path"
    }
    Get-ChildItem -Path $Path -Recurse -Force -ErrorAction Stop | ForEach-Object {
        if (($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to recurse: reparse point detected at $($_.FullName)"
        }
    }
    Remove-Item -Path $Path -Recurse -Force
}

# --- main flows

function Invoke-Install {
    Write-Log '== Decky Loader install =='

    $expected = $null
    if ($ExpectedSha256) { $expected = Test-ExpectedSha256Format -Value $ExpectedSha256 }

    $sourceIsLocal = Test-Path -LiteralPath $Source -PathType Leaf
    $sourceIsUrl   = -not $sourceIsLocal -and ($Source -match '^https?://')
    if (-not $sourceIsLocal -and -not $sourceIsUrl) {
        throw "-Source must be either an existing local zip path or an http(s):// URL. Got: $Source"
    }
    if ($sourceIsUrl -and -not $expected -and -not $AllowUnpinned) {
        throw @"
Refusing to download from a URL without integrity verification.
  -ExpectedSha256 <hash>  pin to a known SHA256, or
  -AllowUnpinned          skip integrity checking (not recommended).
"@
    }

    $steamPath = Get-SteamPath
    Write-Log "Steam path: $steamPath"
    $steamExe = Join-Path $steamPath 'steam.exe'
    if (-not (Test-Path $steamExe)) { throw "steam.exe not found at $steamExe" }

    if ((Test-SteamRunning) -and -not $Force) {
        throw 'Steam (or a helper like steamwebhelper) is running. Close Steam first, or re-run with -Force.'
    }

    $cefFlag = Join-Path $steamPath '.cef-enable-remote-debugging'
    $cefAlreadyExists = Test-Path $cefFlag
    if (-not $cefAlreadyExists -and -not (Test-WriteAccess -Path $steamPath)) {
        $hint = if (Test-Administrator) {
            "Even as Administrator. Check folder permissions on $steamPath."
        } else {
            'Re-run from an elevated PowerShell (right-click PowerShell -> Run as Administrator).'
        }
        throw "Cannot write to Steam install dir. $hint"
    }

    Stop-PluginLoader

    $zip = Resolve-PluginLoaderZip -Source $Source
    try {
        $sha = (Get-FileHash -Path $zip.Path -Algorithm SHA256).Hash
        Write-Log "SHA256: $sha"
        if ($expected -and ($sha -ne $expected)) {
            throw "SHA256 mismatch. Expected $expected, got $sha"
        }
        if (-not (Test-ZipFile -Path $zip.Path)) {
            throw "Not a valid zip file: $($zip.Path)"
        }

        # Preserve createdCefFile across re-installs: if a previous manifest
        # recorded that we created the CEF flag, retain that fact even if
        # this re-run sees the file already present.
        $existing = Read-Manifest
        $createdCef = -not $cefAlreadyExists
        if ($existing -and $existing.PSObject.Properties.Name -contains 'createdCefFile' -and $existing.createdCefFile) {
            $createdCef = $true
        }

        $manifest = [ordered]@{
            version           = 2
            installedAt       = (Get-Date).ToString('o')
            source            = $Source
            sha256            = $sha
            steamPath         = $steamPath
            servicesDir       = $ServicesDir
            deckyShortcut     = $null
            autoStartShortcut = $null
            cefDebugFile      = $cefFlag
            createdCefFile    = $createdCef
        }

        foreach ($d in $HomebrewDir, $ServicesDir) {
            if (-not (Test-Path $d)) {
                Write-Log "Creating $d"
                New-Item -ItemType Directory -Path $d -Force | Out-Null
            }
        }

        # Write the manifest early and after every step so a partial install
        # leaves an accurate record for -Uninstall to clean up.
        Save-Manifest -Manifest $manifest

        if (-not $cefAlreadyExists) {
            Write-Log "Creating $cefFlag"
            New-Item -ItemType File -Path $cefFlag -Force | Out-Null
        } else {
            Write-Log "$cefFlag already exists"
        }
        Save-Manifest -Manifest $manifest

        Write-Log "Extracting (zip-slip-checked) to $ServicesDir"
        Expand-ZipSafe -Path $zip.Path -Destination $ServicesDir

        $pluginLoaderNoConsole = Join-Path $ServicesDir 'PluginLoader_noconsole.exe'
        if (-not (Test-Path $pluginLoaderNoConsole)) {
            throw "Expected PluginLoader_noconsole.exe at $pluginLoaderNoConsole - extraction may have failed."
        }

        Write-Log "Creating $ShortcutDecky"
        New-Shortcut -Path $ShortcutDecky -TargetPath $steamExe `
            -Arguments '-dev' -WorkingDirectory $steamPath `
            -Description 'Launch Steam with Decky Loader'
        $manifest.deckyShortcut = $ShortcutDecky
        Save-Manifest -Manifest $manifest

        if (-not $NoAutoStart) {
            Write-Log "Creating $ShortcutAuto"
            New-Shortcut -Path $ShortcutAuto -TargetPath $pluginLoaderNoConsole `
                -WorkingDirectory $ServicesDir `
                -Description 'Decky Loader Autostart'
            $manifest.autoStartShortcut = $ShortcutAuto
            Save-Manifest -Manifest $manifest
        } else {
            Write-Log 'Skipping Startup folder shortcut (-NoAutoStart)'
        }

        Write-Log 'PluginLoader binary provenance:'
        Show-BinaryProvenance -Path $pluginLoaderNoConsole

        if (-not $NoLaunch) {
            if ($PSCmdlet.ShouldProcess($pluginLoaderNoConsole, 'Launch PluginLoader')) {
                Write-Log "Launching $pluginLoaderNoConsole"
                Start-Process -FilePath $pluginLoaderNoConsole -WorkingDirectory $ServicesDir
            }
        } else {
            Write-Log 'Not launching PluginLoader (-NoLaunch). Run it manually from homebrew\services\.'
        }

        Write-Log '== Install complete =='
        Write-Host ''
        Write-Host 'Next steps:' -ForegroundColor Cyan
        Write-Host '  1. Make sure Steam is closed.'
        Write-Host '  2. Launch Steam via the new "Steam (Decky)" desktop shortcut.'
        Write-Host '  3. In Big Picture Mode: Ctrl+2 (or Steam button + A on a controller) to open the QAM.'
        Write-Host ''
        Write-Host 'Note: Windows Defender / SmartScreen may flag PluginLoader.exe.' -ForegroundColor Yellow
        Write-Host '      You may need to add an exclusion for homebrew\services.' -ForegroundColor Yellow
    } finally {
        if ($zip -and $zip.IsTemp -and (Test-Path $zip.Path)) {
            Remove-Item $zip.Path -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-Uninstall {
    Write-Log '== Decky Loader uninstall =='

    $manifest = Read-Manifest
    if (-not $manifest) {
        Write-Log "No manifest at $ManifestPath. Best-effort removal of known artifacts." 'WARN'
        $steamPathFallback = $null
        try { $steamPathFallback = Get-SteamPath } catch { }
        $manifest = [pscustomobject]@{
            version           = 2
            steamPath         = $steamPathFallback
            servicesDir       = $ServicesDir
            deckyShortcut     = $ShortcutDecky
            autoStartShortcut = $ShortcutAuto
            cefDebugFile      = $null
            createdCefFile    = $false
        }
    }

    Stop-PluginLoader

    # Allowed roots restrict what -Uninstall can ever delete. The manifest
    # lives in a user-writable location; without this gate, a maliciously
    # crafted manifest could direct deletion of arbitrary files when the
    # script runs elevated.
    $allowedRoots = @($DesktopPath, $StartupPath, $HomebrewDir)
    if ($manifest.steamPath) { $allowedRoots += $manifest.steamPath }

    foreach ($prop in 'deckyShortcut','autoStartShortcut') {
        $p = $manifest.$prop
        if (-not $p) { continue }
        if (-not (Test-PathUnderRoot -Candidate $p -Roots $allowedRoots)) {
            Write-Log "Refusing to remove $prop = $p (outside allowed roots)" 'WARN'
            continue
        }
        if (Test-Path $p) {
            if ($PSCmdlet.ShouldProcess($p, "Remove $prop")) {
                Write-Log "Removing $p"
                Remove-Item $p -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if ($manifest.createdCefFile -and $manifest.cefDebugFile) {
        $cef = $manifest.cefDebugFile
        if (-not (Test-PathUnderRoot -Candidate $cef -Roots $allowedRoots)) {
            Write-Log "Refusing to remove cefDebugFile = $cef (outside allowed roots)" 'WARN'
        } elseif (Test-Path $cef) {
            if ($PSCmdlet.ShouldProcess($cef, 'Remove CEF debug flag')) {
                Write-Log "Removing $cef"
                Remove-Item $cef -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if ($PurgeUserData) {
        if (Test-Path $HomebrewDir) {
            if ($PSCmdlet.ShouldProcess($HomebrewDir, 'Purge homebrew directory (including user data)')) {
                Write-Log "Purging $HomebrewDir (user data included)" 'WARN'
                Remove-DirectorySafe -Path $HomebrewDir
            }
        }
    } else {
        $svc = $manifest.servicesDir
        if ($svc -and (Test-PathUnderRoot -Candidate $svc -Roots $allowedRoots) -and (Test-Path $svc)) {
            Write-Log "Removing PluginLoader binaries from $svc (plugin data preserved)"
            foreach ($exe in 'PluginLoader.exe','PluginLoader_noconsole.exe') {
                $f = Join-Path $svc $exe
                if (Test-Path $f) {
                    if ($PSCmdlet.ShouldProcess($f, 'Remove')) {
                        Remove-Item $f -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }
    }

    # Manifest lives outside homebrew\, so it is removed regardless of
    # whether -PurgeUserData was specified.
    if (Test-Path $ManifestPath) {
        if ($PSCmdlet.ShouldProcess($ManifestPath, 'Remove manifest')) {
            Remove-Item $ManifestPath -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Log '== Uninstall complete =='
}

# --- main
try {
    if ($Uninstall) { Invoke-Uninstall } else { Invoke-Install }
} catch {
    Write-Log $_.Exception.Message 'ERROR'
    exit 1
}
