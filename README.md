# decky-windows-installer

A PowerShell installer for [Decky Loader](https://github.com/SteamDeckHomebrew/decky-loader) on Windows. Single script, no compilation, fully auditable, with a working uninstall.

## Disclaimer

**Decky Loader on Windows is unofficial.** The Decky Loader team does not support Windows installations and will not help with issues caused by this installer or any Windows-specific behavior. Use at your own risk.

## Requirements

- Windows 10 or 11
- Steam installed
- PowerShell 5.1+ (built into Windows) or PowerShell 7+
- Python 3.x on PATH (required by Decky plugins themselves, not the installer)
- Administrator privileges **only** if Steam is installed in a location the current user cannot write to (typically `C:\Program Files (x86)\Steam`). The script detects this at runtime and tells you if elevation is needed.

## Install

Pick one option.

### Option 1: One-line remote install

```powershell
$f="$env:TEMP\Install-DeckyLoader.ps1"; iwr https://raw.githubusercontent.com/sharkusmanch/decky-windows-installer/main/Install-DeckyLoader.ps1 -OutFile $f; & $f -ExpectedSha256 '<hash>'
```

For higher assurance, pin to a specific commit so you know exactly which script revision you're running. Replace `main` with a commit SHA from this repo's history:

```powershell
$f="$env:TEMP\Install-DeckyLoader.ps1"; iwr https://raw.githubusercontent.com/sharkusmanch/decky-windows-installer/<commit-sha>/Install-DeckyLoader.ps1 -OutFile $f; & $f -ExpectedSha256 '<hash>'
```

The script refuses to download from a URL without `-ExpectedSha256` unless you also pass `-AllowUnpinned`. Running a remote installer means trusting both the script and the loader binary — Option 2 lets you inspect both before running.

### Option 2: Clone and run

```powershell
git clone https://github.com/sharkusmanch/decky-windows-installer.git
cd decky-windows-installer
.\Install-DeckyLoader.ps1 -ExpectedSha256 '<hash>'
```

Lets you inspect `Install-DeckyLoader.ps1` before running, and pin to a commit by checking it out.

### After install

1. Close Steam if running.
2. Launch Steam via the new **Steam (Decky)** desktop shortcut (it adds `-dev`).
3. Enter Big Picture Mode.
4. Press **Ctrl + 2** (or Steam button + A on a controller) to open the Quick Access Menu — Decky's tab appears there.

## Parameters

| Parameter | Type | Description |
|---|---|---|
| `-Uninstall` | switch | Reverse the install using the manifest |
| `-Source` | string | Local zip path or HTTP(S) URL. Default: upstream nightly via nightly.link |
| `-ExpectedSha256` | string | Verify download SHA256 before extracting; abort on mismatch. Required for URL sources unless `-AllowUnpinned` is set |
| `-AllowUnpinned` | switch | Permit URL downloads without SHA256 verification (not recommended) |
| `-NoAutoStart` | switch | Skip the Startup folder shortcut |
| `-NoLaunch` | switch | Don't launch PluginLoader after install |
| `-PurgeUserData` | switch | On uninstall, also delete `%USERPROFILE%\homebrew` |
| `-Force` | switch | Skip the "Steam is running" guard |
| `-WhatIf`, `-Confirm` | switch | Standard PowerShell `SupportsShouldProcess` switches; especially useful with `-Uninstall` |

`Get-Help .\Install-DeckyLoader.ps1 -Detailed` shows the full comment-based help.

## Examples

**Default install (will refuse without `-ExpectedSha256` or `-AllowUnpinned`):**
```powershell
.\Install-DeckyLoader.ps1 -ExpectedSha256 'A1B2C3...'
```

**Install from a local zip (no SHA256 needed for local files):**
```powershell
.\Install-DeckyLoader.ps1 -Source 'C:\Downloads\PluginLoader Win.zip'
```

**Install from a pinned upstream GitHub Release:**
```powershell
.\Install-DeckyLoader.ps1 `
    -Source 'https://github.com/SteamDeckHomebrew/decky-loader/releases/download/<tag>/<asset>' `
    -ExpectedSha256 '<hash>'
```

> **Note:** As of v3.2.3, upstream Decky's official releases only include the Linux `PluginLoader` binary — there is no `PluginLoader Win.zip` asset. The Windows build is published only as a GitHub Actions workflow artifact. Until upstream adds a Windows release asset, your options are: (a) download the workflow artifact manually and pass it as a local `-Source`, (b) use `nightly.link` with `-AllowUnpinned`, or (c) use a fork that publishes Windows builds in its releases.

**Install without autostart and without launching:**
```powershell
.\Install-DeckyLoader.ps1 -NoAutoStart -NoLaunch -AllowUnpinned
```

**Preview an uninstall without changing anything:**
```powershell
.\Install-DeckyLoader.ps1 -Uninstall -WhatIf
```

**Uninstall (preserves plugin data in `homebrew\plugins`):**
```powershell
.\Install-DeckyLoader.ps1 -Uninstall
```

**Full purge:**
```powershell
.\Install-DeckyLoader.ps1 -Uninstall -PurgeUserData
```

## What it does

On install:

1. Validates `-ExpectedSha256` format if provided; refuses URL downloads with no integrity pin unless `-AllowUnpinned`.
2. Resolves Steam install path from registry (`HKLM\SOFTWARE\WOW6432Node\Valve\Steam\InstallPath`, with fallbacks).
3. Aborts if Steam (or `steamwebhelper` / `steamservice`) is running (override with `-Force`).
4. Probes write access to the Steam install dir; suggests elevation only if needed.
5. Stops any running `PluginLoader.exe` / `PluginLoader_noconsole.exe`.
6. Downloads (or accepts a local) `PluginLoader Win.zip`. Verifies ZIP magic bytes and SHA256 if specified.
7. Creates `%USERPROFILE%\homebrew\services\` if missing.
8. Creates `.cef-enable-remote-debugging` in the Steam install dir (only if not already present).
9. Extracts the zip with **Zip-Slip protection** — every entry's resolved path is validated to stay within the destination before extraction.
10. Creates **Steam (Decky).lnk** on the Desktop (target: `steam.exe -dev`).
11. Creates **Decky Loader.lnk** in the Startup folder (target: `PluginLoader_noconsole.exe`) unless `-NoAutoStart`.
12. Reports SHA256 and Authenticode signature status of `PluginLoader_noconsole.exe`.
13. Launches `PluginLoader_noconsole.exe` unless `-NoLaunch` (`-Confirm` will prompt before launch).
14. Writes a v2 install manifest to `%USERPROFILE%\homebrew\.install-manifest.json`. Updated incrementally after each step so a partial install still leaves an accurate record.

On uninstall (manifest-driven, with safety rails):

1. Stops PluginLoader processes.
2. Reads the manifest. Each path read from it is **validated to be under one of these allowed roots** (Desktop, Startup, `homebrew\`, the Steam install path) before any deletion — a tampered manifest cannot redirect deletion outside known locations.
3. Removes the desktop and Startup shortcuts that were created.
4. Removes `.cef-enable-remote-debugging` only if the install created it (not if it was already there).
5. Removes the loader binaries from `homebrew\services` but preserves user data, unless `-PurgeUserData`.
6. With `-PurgeUserData`: refuses to traverse reparse points (junctions / symlinks) inside `homebrew\` so a planted junction cannot redirect recursive deletion.
7. Deletes the manifest.

## Files written

| Path | Purpose |
|---|---|
| `<SteamInstall>\.cef-enable-remote-debugging` | Required by Decky to attach to Steam's CEF |
| `%USERPROFILE%\homebrew\services\PluginLoader*.exe` | Loader binaries |
| `%USERPROFILE%\homebrew\.install-manifest.json` | Install manifest (used by `-Uninstall`) |
| `%USERPROFILE%\Desktop\Steam (Decky).lnk` | Steam launcher with `-dev` |
| `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Decky Loader.lnk` | Autostart (unless `-NoAutoStart`) |
| `%LOCALAPPDATA%\decky-installer\install.log` | Persistent log |
| `%TEMP%\PluginLoader-<timestamp>-<rand>.zip` | Temporary download (deleted after install or on failure) |

## Known issues

- **No upstream Windows release asset.** Upstream Decky only publishes the Linux `PluginLoader` binary in GitHub Releases. Windows builds come from Actions artifacts. Until that changes, pinning to a release URL with SHA256 isn't possible against upstream — see the example note above.
- **Upstream nightly may be broken.** The default `-Source` points at upstream Decky's `build-win` workflow, which has had broken builds in the past. If install fails after extraction, pass `-Source` with a known-good local zip.
- **Windows Defender / SmartScreen** may flag `PluginLoader.exe`. The script logs the binary's SHA256 and Authenticode signature status so you can compare against an expected value before launch. You may need to add `homebrew\services` to your antivirus exclusions.
- **Port 1337 conflicts.** Decky listens on port 1337. Other software (notably Razer Synapse) can claim that port and prevent Decky from starting.
- **Plugin compatibility on Windows is limited.** Confirmed working: Audio Loader, CSS Loader, IsThereAnyDeal For Deck, PlayCount, PlayTime, ProtonDB Badges, SteamGridDB, TabMaster, Web Browser. Other plugins may not work or may not display correctly.

## Security notes

This script runs filesystem operations on your machine and (potentially) launches an unverified third-party binary. Treat it accordingly:

- The script downloads `PluginLoader Win.zip` over HTTPS but, by default, that download has **no integrity pin**. Use `-ExpectedSha256` whenever possible.
- The downloaded binary is **not signed by Microsoft or the Decky team**. The installer reports its SHA256 and Authenticode status before launch — compare these against a known-good reference if you have one.
- The uninstall manifest lives in a user-writable directory. The script validates every path it reads from the manifest against an allowed-roots list before deleting, so a tampered manifest cannot direct deletion outside known locations even if the script runs elevated.
- Zip extraction is Zip-Slip-checked. Each entry's resolved path must stay within the destination directory; otherwise extraction is refused.
- `-PurgeUserData` refuses to recurse across reparse points.

## License

[MIT](LICENSE)
