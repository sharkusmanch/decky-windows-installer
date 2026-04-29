# decky-windows-installer

A PowerShell installer for [Decky Loader](https://github.com/SteamDeckHomebrew/decky-loader) on Windows. Single script, no compilation, fully auditable, with a working uninstall.

## Disclaimer

**Decky Loader on Windows is unofficial.** The Decky Loader team does not support Windows installations and will not help with issues caused by this installer or any Windows-specific behavior. Use at your own risk.

## Requirements

- Windows 10 or 11
- Steam installed
- PowerShell 5.1+ (built into Windows) or PowerShell 7+
- Administrator privileges (to write `.cef-enable-remote-debugging` into Steam's install dir)
- Python 3.x on PATH (required by Decky plugins themselves, not the installer)

## Install

Open an **elevated** PowerShell (Run as Administrator), then:

```powershell
C:\Users\theme\projects\decky-windows-installer\Install-DeckyLoader.ps1
```

Default behavior downloads the upstream Decky nightly via `nightly.link`. Note that this nightly is currently broken on Windows; you'll likely want to pass `-Source` pointing at a working fork build (see below).

After install:

1. Close Steam if running.
2. Launch Steam via the new **Steam (Decky)** desktop shortcut (it adds `-dev`).
3. Enter Big Picture Mode.
4. Press **Ctrl + 2** (or Steam button + A on a controller) to open the Quick Access Menu — Decky's tab appears there.

## Parameters

| Parameter | Type | Description |
|---|---|---|
| `-Uninstall` | switch | Reverse the install using the manifest |
| `-Source` | string | Local zip path or HTTP(S) URL. Default: upstream nightly via nightly.link |
| `-ExpectedSha256` | string | Verify download SHA256 before extracting; abort on mismatch |
| `-NoAutoStart` | switch | Skip the Startup folder shortcut |
| `-NoLaunch` | switch | Don't launch PluginLoader after install |
| `-PurgeUserData` | switch | On uninstall, also delete `%USERPROFILE%\homebrew` |
| `-Force` | switch | Skip the "Steam is running" guard |

`Get-Help .\Install-DeckyLoader.ps1 -Detailed` shows the full comment-based help.

## Examples

**Default install:**
```powershell
.\Install-DeckyLoader.ps1
```

**Install from a local zip with hash verification:**
```powershell
.\Install-DeckyLoader.ps1 -Source 'C:\Downloads\PluginLoader Win.zip' -ExpectedSha256 'A1B2C3...'
```

**Install from an alternative URL (e.g. a fork's GitHub Actions artifact via nightly.link):**
```powershell
.\Install-DeckyLoader.ps1 -Source 'https://nightly.link/suchmememanyskill/decky-loader/workflows/build-win/main/PluginLoader%20Win.zip'
```

**Install without autostart and without launching:**
```powershell
.\Install-DeckyLoader.ps1 -NoAutoStart -NoLaunch
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

1. Resolves Steam install path from registry (`HKLM\SOFTWARE\WOW6432Node\Valve\Steam\InstallPath`, with fallbacks).
2. Aborts if Steam is running (override with `-Force`).
3. Stops any running `PluginLoader.exe` / `PluginLoader_noconsole.exe`.
4. Downloads (or accepts a local) `PluginLoader Win.zip`; verifies ZIP magic bytes and optional SHA256.
5. Creates `%USERPROFILE%\homebrew\services\` if missing.
6. Creates `.cef-enable-remote-debugging` in the Steam install dir.
7. Extracts the zip into `homebrew\services`.
8. Creates **Steam (Decky).lnk** on the Desktop (target: `steam.exe -dev`).
9. Creates **Decky Loader.lnk** in the Startup folder (target: `PluginLoader_noconsole.exe`) unless `-NoAutoStart`.
10. Writes an install manifest to `%USERPROFILE%\homebrew\.install-manifest.json`.
11. Launches `PluginLoader_noconsole.exe` unless `-NoLaunch`.

On uninstall (manifest-driven):

1. Stops PluginLoader processes.
2. Removes the desktop and Startup shortcuts that were created.
3. Removes `.cef-enable-remote-debugging` only if the install created it (not if it was already there).
4. Removes the loader binaries from `homebrew\services` but preserves user data, unless `-PurgeUserData`.
5. Deletes the manifest.

## Files written

| Path | Purpose |
|---|---|
| `<SteamInstall>\.cef-enable-remote-debugging` | Required by Decky to attach to Steam's CEF |
| `%USERPROFILE%\homebrew\services\PluginLoader*.exe` | Loader binaries |
| `%USERPROFILE%\homebrew\.install-manifest.json` | Install manifest (used by `-Uninstall`) |
| `%USERPROFILE%\Desktop\Steam (Decky).lnk` | Steam launcher with `-dev` |
| `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Decky Loader.lnk` | Autostart (unless `-NoAutoStart`) |
| `%LOCALAPPDATA%\decky-installer\install.log` | Persistent log |

## Known issues

- **Upstream nightly is currently broken.** The default `-Source` points at upstream Decky's `build-win` workflow, which has been failing. Pass `-Source` with a working fork's URL or a local zip until upstream is fixed.
- **Windows Defender / SmartScreen** may flag `PluginLoader.exe`. You may need to add `homebrew\services` to your antivirus exclusions.
- **Port 1337 conflicts.** Decky listens on port 1337. Other software (notably Razer Synapse) can claim that port and prevent Decky from starting.
- **Plugin compatibility on Windows is limited.** Confirmed working: Audio Loader, CSS Loader, IsThereAnyDeal For Deck, PlayCount, PlayTime, ProtonDB Badges, SteamGridDB, TabMaster, Web Browser. Other plugins may not work or may not display correctly.

## License

No license has been chosen yet. The script is provided as-is.
