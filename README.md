# Codex Profile Launcher for Windows

`Codex-Profile.ps1` launches the normal Codex desktop profile alongside separately isolated profiles.

The current configuration is:

| Profile | Mode | Behavior |
| --- | --- | --- |
| `Work` | Native, default | Launches Codex normally, with no special arguments or environment override. |
| `Personal` | Isolated | Uses separate Codex backend state and Chromium web state. |

Run `Codex-Profile.ps1 -h` or `Codex-Profile.ps1 --help` to see the active configuration.

## Usage

With no arguments, the launcher starts the configured default (`Work`):

```powershell
.\Codex-Profile.ps1
```

These are equivalent:

```powershell
.\Codex-Profile.ps1 Work
.\Codex-Profile.ps1 -Profile Work
```

Launch the isolated personal profile:

```powershell
.\Codex-Profile.ps1 Personal
```

If execution policy blocks the script, use:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Codex-Profile.ps1 Personal
```

The isolated profile defaults to:

```text
%LOCALAPPDATA%\CodexProfiles\personal\codex-home
%LOCALAPPDATA%\CodexProfiles\personal\web-data
```

`CODEX_HOME` separates Codex authentication, configuration, sessions, databases, skills, and plugins. Chromium `--user-data-dir` separates cookies, local storage, cache, crash data, and desktop web state.

For every `Isolated` profile, the launcher also ensures its `codex-home\config.toml` contains:

```toml
cli_auth_credentials_store = "file"
```

This forces Codex to use the profile-local `auth.json` instead of a shared Windows credential store. Existing configuration is preserved. If an isolated profile explicitly selects another credential store, the launcher stops with an error instead of silently overriding it. Native profiles are not changed.

## Change the profiles

Edit the configuration block near the beginning of `Codex-Profile.ps1`:

```powershell
$DefaultProfile = 'Work'
$Profiles = [ordered]@{
    Work     = @{ Mode = 'Native'; Description = 'Normal Codex app state; no profile overrides' }
    Personal = @{ Mode = 'Isolated'; Description = 'Separate personal account and application state' }
}
```

Exactly one profile should normally use `Native` mode because every native entry resolves to the same normal Codex state. Additional accounts should use `Isolated`.

## Create desktop shortcuts

Create one shortcut for every configured profile:

```powershell
.\Codex-Profile.ps1 -InstallShortcuts
```

Do not move or rename the script after creating shortcuts; recreate them if you do.

## Diagnostics

Show running isolated top-level Codex processes:

```powershell
.\Codex-Profile.ps1 -Status
```

The native/default process is deliberately not shown because it has no explicit `--user-data-dir` argument.

## Important caveats

- This was verified with Windows package `OpenAI.Codex_26.707.3748.0_x64` but is not a documented, supported multi-profile feature. A future update could change argument handling, environment handling, authentication, or storage layout.
- Windows still sees every process as the same installed package. Package-scoped settings, notifications, `codex://` protocol activation, shell integration, and OS credential storage may remain shared or route to the wrong profile.
- Isolated profiles force Codex authentication into their profile-local `auth.json`; keep that file private and never commit it.
- If browser sign-in returns to the wrong window, temporarily close the other profile, finish sign-in, and reopen both.
- Do not copy credentials between profile folders or place profile data in Git, OneDrive, Dropbox, shared folders, or network drives.
- Do not run the same isolated profile concurrently against the same files. Chromium and SQLite expect single-profile ownership.

## What was verified

On July 10, 2026, a probe launched the packaged `app\ChatGPT.exe` with `CODEX_HOME` and `--user-data-dir` overrides while the normal Codex app was running. Windows created a second top-level process. Its Chromium children used the isolated web-data directory, and its Codex backend initialized config, databases, plugins, and skills under the isolated `CODEX_HOME`.

OpenAI's public documentation does not currently document `--user-data-dir` as a supported Codex desktop profile feature. Treat this launcher as an update-sensitive workaround.
