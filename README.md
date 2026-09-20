# Codex Profile Launcher for Windows

This is a personal fork of [phoem/Codex-Profile-Launcher](https://github.com/phoem/Codex-Profile-Launcher), extended to run a normal Codex account alongside an isolated Personal account on Windows.

[中文说明 / Chinese documentation](README.zh-CN.md)

> This is an unofficial, update-sensitive workaround that relies on the internal structure of the Codex Windows app. It is not an official multi-account feature.

## Features in this fork

- Keeps `Work` on the normal installed Codex state.
- Runs `Personal` with separate Codex, Chromium, and Electron data directories.
- Builds a profile-owned copy of the installed app without modifying the original WindowsApps installation.
- Uses file-based credentials and an isolated unelevated Windows sandbox configuration.
- Gives Personal its own notification identity, Start Menu entry, and activation registration.
- Reuses an existing Personal window instead of launching duplicate instances.
- Handles missing AppX discovery, restricted WMI process inspection, and incompatible app updates with safe fallbacks.
- Includes runtime integrity, launcher configuration, and sandbox permission tests.

## Requirements

- Windows with the Codex desktop app installed.
- PowerShell.
- `node.exe` available on `PATH` for the first Personal runtime build.

The launcher does not copy or commit account data. Personal data remains under:

```text
%LOCALAPPDATA%\CodexProfiles\personal\codex-home
%LOCALAPPDATA%\CodexProfiles\personal\web-data
```

Prepared application copies are stored in a `profile-runtime` directory next to this repository. They are local build artifacts and are intentionally ignored by Git.

## Usage

Run these commands from the directory containing `Codex-Profile.ps1`:

```powershell
# Launch the default Work profile
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Codex-Profile.ps1 Work

# Launch the isolated Personal profile
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Codex-Profile.ps1 Personal

# Show isolated instances
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Codex-Profile.ps1 -Status

# Install desktop shortcuts for the configured profiles
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Codex-Profile.ps1 -InstallShortcuts

# Send a harmless notification routing test while Personal is closed
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Codex-Profile.ps1 Personal -TestNotification
```

The launcher also accepts `-ProfilesRoot` when a different local profile root is required.

## Update behavior

When Codex is updated, the launcher attempts to prepare a matching isolated runtime. If the new app structure is incompatible with the profile patch, it reuses the newest valid isolated runtime instead of modifying the installed app or silently falling back to the shared account. If no valid runtime exists, it stops with an error.

The launcher also falls back to the executable path of a running native Codex process when AppX registration is temporarily unavailable. These fallbacks keep the two profile data directories separate.

## Privacy and safety

- Never commit `auth.json`, `CodexProfiles`, `codex-home`, `web-data`, notification logs, or prepared runtimes.
- Do not place profile data in Git, OneDrive, Dropbox, shared folders, or network drives.
- Do not run two Personal processes against the same profile directory at the same time.
- The notification journal records routing events and process metadata, not notification bodies.
- The launcher does not modify the original installed Codex files; it patches only a copied runtime.

## Tests

The `scripts` directory contains tests for:

- launcher configuration parsing and idempotent updates;
- runtime archive copying and integrity;
- Windows sandbox read/write boundaries.

The tests create temporary local fixtures and do not call the model.

## Fork relationship

This repository uses the original project as `upstream` and this personal fork as `origin`. Changes intended for the original project should be proposed through a pull request rather than pushed to the upstream repository.
