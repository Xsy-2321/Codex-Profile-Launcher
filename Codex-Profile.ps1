[CmdletBinding(DefaultParameterSetName = 'Launch')]
param(
    [Parameter(Position = 0, ParameterSetName = 'Launch')]
    [string]$Profile,

    [Parameter(ParameterSetName = 'Launch')]
    [string]$ProfilesRoot = (Join-Path $env:LOCALAPPDATA 'CodexProfiles'),

    [Parameter(ParameterSetName = 'Launch')]
    [switch]$PassThru,

    [Parameter(ParameterSetName = 'Launch')]
    [switch]$TestNotification,

    [Parameter(Mandatory, ParameterSetName = 'Install')]
    [switch]$InstallShortcuts,

    [Parameter(ParameterSetName = 'Install')]
    [string]$ShortcutProfilesRoot = (Join-Path $env:LOCALAPPDATA 'CodexProfiles'),

    [Parameter(Mandatory, ParameterSetName = 'Status')]
    [switch]$Status,

    [Parameter(Mandatory, ParameterSetName = 'Help')]
    [Alias('h', '?')]
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

# Edit this small block to change the default or add profiles. Native launches
# Codex normally. Isolated assigns separate backend and Chromium state paths.
$DefaultProfile = 'Work'
$Profiles = [ordered]@{
    Work     = @{ Mode = 'Native'; Description = 'Normal Codex app state; no profile overrides' }
    Personal = @{ Mode = 'Isolated'; WindowsSandbox = 'unelevated'; Description = 'Separate personal account, runtime and notification activation' }
}

function Get-ExistingProfileRuntime([string]$Name, [string]$ProfileRoot) {
    $runtimeBase = Join-Path (Split-Path $PSScriptRoot -Parent) 'profile-runtime'
    $runtimeDirectories = Get-ChildItem -LiteralPath $runtimeBase -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    foreach ($runtimeDirectory in $runtimeDirectories) {
        $manifest = Join-Path $runtimeDirectory.FullName 'profile-runtime.json'
        $runtimeExecutable = Join-Path $runtimeDirectory.FullName 'ChatGPT.exe'
        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf) -or
            -not (Test-Path -LiteralPath $runtimeExecutable -PathType Leaf)) {
            continue
        }

        try {
            $metadata = Get-Content -Raw -LiteralPath $manifest | ConvertFrom-Json
        }
        catch {
            continue
        }

        if ($metadata.label -ne $Name) { continue }
        if ($ProfileRoot -and $metadata.profileRoot -ine $ProfileRoot) { continue }
        return [pscustomobject]@{
            Executable = $runtimeExecutable
            Root       = $runtimeDirectory.FullName
            Metadata   = $metadata
        }
    }
}

function Register-ProfileNotificationsSafe([string]$Runtime) {
    try {
        & (Join-Path $PSScriptRoot 'scripts\Register-ProfileNotifications.ps1') -Runtime $Runtime | Out-Null
    }
    catch {
        $identity = Get-Content -Raw -LiteralPath (Join-Path $Runtime 'resources\profile-identity.json') | ConvertFrom-Json
        $shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) ('Codex - ' + $identity.label + '.lnk')
        if (-not (Test-Path -LiteralPath $shortcut -PathType Leaf)) { throw }
        Write-Warning 'Could not refresh notification registration in this session; continuing with the existing Personal shortcut registration.'
    }
}

function Get-CodexExecutable([switch]$AllowRuntimeFallback) {
    $package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if ($package) {
        $executable = Join-Path $package.InstallLocation 'app\ChatGPT.exe'
        if (Test-Path -LiteralPath $executable -PathType Leaf) {
            return $executable
        }
    }

    # In some Windows sessions (notably after a Store update or when the
    # launcher is started from a different user context), Get-AppxPackage can
    # return nothing even though the installed app is running. Reuse the
    # executable path exposed by the running native Codex process.
    $runningExecutable = Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue |
        ForEach-Object {
            try { $_.Path } catch { $null }
        } |
        Where-Object {
            $_ -and
            (Test-Path -LiteralPath $_ -PathType Leaf) -and
            $_ -match '\\WindowsApps\\OpenAI\.Codex_[^\\]+\\app\\ChatGPT\.exe$'
        } |
        Sort-Object -Unique |
        Select-Object -First 1

    if ($runningExecutable) {
        return $runningExecutable
    }

    if ($AllowRuntimeFallback) {
        # A previously prepared Personal runtime is self-contained and can
        # still be launched while the native package is closed or temporarily
        # missing from the AppX registration visible to this session.
        $existingRuntime = Get-ExistingProfileRuntime -Name 'Personal'
        if ($existingRuntime) {
            Write-Host "  Native AppX path was not discoverable; using existing Personal runtime: $($existingRuntime.Executable)"
            return $existingRuntime.Executable
        }
    }

    throw 'The OpenAI Codex Windows app is not installed for this user, and no usable Codex runtime was found.'
}

function Resolve-ProfileName([string]$Name) {
    foreach ($configuredName in $Profiles.Keys) {
        if ($configuredName -ieq $Name) {
            return $configuredName
        }
    }

    $available = $Profiles.Keys -join ', '
    throw "Unknown profile '$Name'. Configured profiles: $available"
}

function Get-ProfilePaths([string]$Name, [string]$Root) {
    $profileRoot = Join-Path $Root $Name.ToLowerInvariant()
    [pscustomobject]@{
        Root        = $profileRoot
        CodexHome   = Join-Path $profileRoot 'codex-home'
        WebData     = Join-Path $profileRoot 'web-data'
    }
}

function Get-IsolatedRuntime([string]$InstalledExe, [string]$Name, [string]$ProfileRoot) {
    $runtimeBase = Join-Path (Split-Path $PSScriptRoot -Parent) 'profile-runtime'

    # When the native package is unavailable, Get-CodexExecutable may return
    # an already prepared profile runtime. Validate and reuse it instead of
    # trying to parse its directory name as an installed AppX package.
    $runtimePrefix = $runtimeBase.TrimEnd('\') + '\'
    if ($InstalledExe.StartsWith($runtimePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        $runtime = Split-Path $InstalledExe -Parent
        $manifest = Join-Path $runtime 'profile-runtime.json'
        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
            throw "Incomplete runtime at $runtime. Inspect it before retrying; nothing was overwritten."
        }
        $metadata = Get-Content -Raw -LiteralPath $manifest | ConvertFrom-Json
        if ($metadata.profileRoot -ine $ProfileRoot -or $metadata.label -ne $Name) {
            throw 'Runtime belongs to a different profile root.'
        }
        Register-ProfileNotificationsSafe -Runtime $runtime
        return $InstalledExe
    }

    $source = Split-Path $InstalledExe -Parent
    $packageName = Split-Path (Split-Path $source -Parent) -Leaf
    if ($packageName -notmatch '^OpenAI\.Codex_([\d.]+)_') { throw 'Cannot identify installed Codex version.' }
    $version = $Matches[1]
    $suffix = if ($Name -eq 'Personal') { '-v1' } else { "-$Name-v1" }
    $runtime = Join-Path $runtimeBase ($version + $suffix)
    $manifest = Join-Path $runtime 'profile-runtime.json'
    if (-not (Test-Path -LiteralPath $manifest)) {
        if (Test-Path -LiteralPath $runtime) { throw "Incomplete runtime at $runtime. Inspect it before retrying; nothing was overwritten." }
        $node = (Get-Command node.exe -ErrorAction Stop).Source
        & $node (Join-Path $PSScriptRoot 'scripts\prepare-runtime.cjs') $source $runtime $ProfileRoot $Name | Write-Host
        if ($LASTEXITCODE -ne 0) {
            $existingRuntime = Get-ExistingProfileRuntime -Name $Name -ProfileRoot $ProfileRoot
            if ($existingRuntime) {
                Write-Host "  Installed app version is not compatible with the profile patch; reusing existing isolated runtime: $($existingRuntime.Executable)"
                Register-ProfileNotificationsSafe -Runtime $existingRuntime.Root
                return $existingRuntime.Executable
            }
            throw 'Could not prepare the isolated runtime; installed Codex was not modified.'
        }
    }
    $metadata = Get-Content -Raw -LiteralPath $manifest | ConvertFrom-Json
    if ($metadata.profileRoot -ine $ProfileRoot -or $metadata.label -ne $Name) { throw 'Runtime belongs to a different profile root.' }
    Register-ProfileNotificationsSafe -Runtime $runtime
    return Join-Path $runtime 'ChatGPT.exe'
}

function Show-IsolatedWindow([int[]]$ProcessIds) {
    if (-not ('CodexProfileWindowApi' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class CodexProfileWindowApi {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
  [DllImport("user32.dll")] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool ShowWindowAsync(IntPtr h, int cmd);
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  public static bool Show(int[] ids) {
    IntPtr found=IntPtr.Zero;
    EnumWindows((h,l)=>{
      uint pid; GetWindowThreadProcessId(h,out pid);
      bool match=false; foreach(int id in ids) if(pid==(uint)id){match=true;break;}
      if(!match)return true;
      var title=new StringBuilder(256); GetWindowText(h,title,title.Capacity);
      if(title.ToString().StartsWith("Codex",StringComparison.OrdinalIgnoreCase)){found=h;return false;}
      return true;
    },IntPtr.Zero);
    if(found==IntPtr.Zero)return false;
    ShowWindowAsync(found,9); SetForegroundWindow(found); return true;
  }
}
'@
    }
    return [CodexProfileWindowApi]::Show($ProcessIds)
}

function Get-RunningIsolatedProcesses([string]$WebData) {
    try {
        return @(
            Get-CimInstance Win32_Process -Filter "Name = 'ChatGPT.exe'" -ErrorAction Stop |
                Where-Object {
                    $_.CommandLine -notmatch '--type=' -and
                    $_.CommandLine -and
                    $_.CommandLine.IndexOf($WebData, [StringComparison]::OrdinalIgnoreCase) -ge 0
                }
        )
    }
    catch [Microsoft.Management.Infrastructure.CimException] {
        # Some launcher contexts can enumerate processes but cannot read WMI
        # command lines. The isolated runtime has its own executable path, so
        # use that stable identity as a permission-safe fallback.
        $runtimeBase = Join-Path (Split-Path $PSScriptRoot -Parent) 'profile-runtime'
        $runtimeExecutables = @(
            Get-ChildItem -LiteralPath $runtimeBase -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { Join-Path $_.FullName 'ChatGPT.exe' } |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
        )
        return @(
            Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue |
                Where-Object {
                    $path = $null
                    try { $path = $_.Path } catch { }
                    $path -and ($runtimeExecutables -contains $path)
                }
        )
    }
}

function Reset-IsolatedStartupPage([string]$WebData) {
    $statePath = Join-Path $WebData 'browser-sidebar-page-states.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return }

    # Keep the previous view as a recoverable backup. This file contains page
    # selection state only; conversation history remains in Codex state files.
    $backupPath = $statePath + '.before-fresh-start.json'
    if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
        Copy-Item -LiteralPath $statePath -Destination $backupPath
    }
    [System.IO.File]::WriteAllText(
        $statePath,
        "{`"version`":1,`"pages`":{}}`n",
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Initialize-IsolatedProfileConfig([string]$CodexHome) {
    $configPath = Join-Path $CodexHome 'config.toml'
    $contents = if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        [System.IO.File]::ReadAllText($configPath)
    }
    else {
        ''
    }

    $assignmentPattern = '(?m)^[ \t]*cli_auth_credentials_store[ \t]*=[ \t]*(?<value>[^#\r\n]+)'
    $assignments = [regex]::Matches($contents, $assignmentPattern)

    if ($assignments.Count -gt 1) {
        throw "Isolated profile config contains multiple cli_auth_credentials_store settings: $configPath"
    }

    if ($assignments.Count -eq 1) {
        $configuredValue = $assignments[0].Groups['value'].Value.Trim()
        if ($configuredValue -notin @('"file"', "'file'")) {
            throw "Isolated profiles require cli_auth_credentials_store = `"file`", but $configPath contains: $configuredValue"
        }
        return
    }

    $newline = [Environment]::NewLine
    $setting = 'cli_auth_credentials_store = "file"'
    $updatedContents = if ([string]::IsNullOrEmpty($contents)) {
        $setting + $newline
    }
    else {
        $setting + $newline + $newline + $contents
    }

    [System.IO.File]::WriteAllText(
        $configPath,
        $updatedContents,
        [System.Text.UTF8Encoding]::new($false)
    )
    Write-Host "  Added file-based credential isolation to: $configPath"
}

function Initialize-IsolatedWindowsSandbox([string]$CodexHome, [string]$SandboxMode) {
    if ([string]::IsNullOrWhiteSpace($SandboxMode)) { return }
    if ($SandboxMode -notin @('elevated', 'unelevated')) {
        throw "Isolated profile has unsupported Windows sandbox mode '$SandboxMode'. Use elevated or unelevated."
    }

    $configPath = Join-Path $CodexHome 'config.toml'
    $contents = if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        [System.IO.File]::ReadAllText($configPath)
    }
    else {
        ''
    }

    $newline = [Environment]::NewLine
    $windowsHeaderPattern = '(?m)^[ \t]*\[windows\][ \t]*(?:#[^\r\n]*)?\r?$'
    $windowsHeaders = [regex]::Matches($contents, $windowsHeaderPattern)

    if ($windowsHeaders.Count -gt 1) {
        throw "Isolated profile config contains multiple [windows] sections: $configPath"
    }

    $setting = "sandbox = `"$SandboxMode`""
    if ($windowsHeaders.Count -eq 0) {
        $separator = if ([string]::IsNullOrEmpty($contents) -or $contents.EndsWith("`n") -or $contents.EndsWith("`r")) { '' } else { $newline }
        $updatedContents = $contents + $separator + $newline + '[windows]' + $newline + $setting + $newline
    }
    else {
        $header = $windowsHeaders[0]
        $sectionStart = $header.Index
        $nextSection = [regex]::Match($contents.Substring($sectionStart + $header.Length), '(?m)^[ \t]*\[')
        $sectionEnd = if ($nextSection.Success) {
            $sectionStart + $header.Length + $nextSection.Index
        }
        else {
            $contents.Length
        }

        $section = $contents.Substring($sectionStart, $sectionEnd - $sectionStart)
        $sandboxPattern = '(?m)^[ \t]*sandbox[ \t]*=[ \t]*[^#\r\n]+'
        $sandboxAssignments = [regex]::Matches($section, $sandboxPattern)
        if ($sandboxAssignments.Count -gt 1) {
            throw "Isolated profile config contains multiple windows.sandbox settings: $configPath"
        }

        if ($sandboxAssignments.Count -eq 1) {
            $replacement = $sandboxAssignments[0].Value -replace 'sandbox[ \t]*=[ \t]*[^#\r\n]+', $setting
            $updatedSection = $section.Remove($sandboxAssignments[0].Index, $sandboxAssignments[0].Length).Insert($sandboxAssignments[0].Index, $replacement)
        }
        else {
            $headerEnd = $section.IndexOf("`n")
            if ($headerEnd -lt 0) {
                $updatedSection = $section + $newline + $setting + $newline
            }
            else {
                $insertAt = $headerEnd + 1
                $updatedSection = $section.Insert($insertAt, $setting + $newline)
            }
        }

        $updatedContents = $contents.Substring(0, $sectionStart) + $updatedSection + $contents.Substring($sectionEnd)
    }

    if ($updatedContents -ne $contents) {
        [System.IO.File]::WriteAllText(
            $configPath,
            $updatedContents,
            [System.Text.UTF8Encoding]::new($false)
        )
        Write-Host "  Set Windows sandbox mode to '$SandboxMode' in: $configPath"
    }
}

function Show-LauncherHelp {
    @"
Codex profile launcher

Usage:
  .\Codex-Profile.ps1                       Launch the default profile
  .\Codex-Profile.ps1 <profile>             Launch a configured profile
  .\Codex-Profile.ps1 -Profile <profile>    Launch a configured profile
  .\Codex-Profile.ps1 -Status               Show running isolated instances
  .\Codex-Profile.ps1 -InstallShortcuts     Create a shortcut for every profile
  .\Codex-Profile.ps1 Personal -TestNotification  Send a harmless click test
  .\Codex-Profile.ps1 -h | --help           Show this help

Default profile: $DefaultProfile

Configured profiles:
"@

    foreach ($name in $Profiles.Keys) {
        $marker = if ($name -eq $DefaultProfile) { ' (default)' } else { '' }
        Write-Host ("  {0,-12} {1,-8} {2}{3}" -f $name, $Profiles[$name].Mode, $Profiles[$name].Description, $marker)
    }

    @"

Native mode uses the installed app's normal state and passes no profile arguments.
Isolated mode stores Codex, Chromium, and Electron data below: $((Join-Path $env:LOCALAPPDATA 'CodexProfiles'))
Isolated profiles also receive a distinct Windows notification identity.
"@
}

function Install-CodexShortcuts([string]$Root) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $shell = New-Object -ComObject WScript.Shell
    $scriptPath = $PSCommandPath
    $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
    $icon = Get-CodexExecutable

    foreach ($name in $Profiles.Keys) {
        $linkPath = Join-Path $desktop "Codex - $name.lnk"
        $shortcut = $shell.CreateShortcut($linkPath)
        $shortcut.TargetPath = $powershell
        $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Profile `"$name`" -ProfilesRoot `"$Root`""
        $shortcut.WorkingDirectory = [Environment]::GetFolderPath('UserProfile')
        $shortcut.IconLocation = "$icon,0"
        $shortcut.Description = "Launch Codex profile: $name ($($Profiles[$name].Mode))"
        $shortcut.Save()
        Write-Host "Created $linkPath"
    }
}

if ($PSCmdlet.ParameterSetName -eq 'Help') {
    Show-LauncherHelp
    return
}

if ($PSCmdlet.ParameterSetName -eq 'Install') {
    Install-CodexShortcuts -Root $ShortcutProfilesRoot
    return
}

if ($PSCmdlet.ParameterSetName -eq 'Status') {
    try {
        $instances = Get-CimInstance Win32_Process -Filter "Name = 'ChatGPT.exe'" -ErrorAction Stop |
            Where-Object {
                $_.CommandLine -match '--user-data-dir=' -and
                $_.CommandLine -notmatch '--type='
            } |
            Select-Object ProcessId, CommandLine
    }
    catch [Microsoft.Management.Infrastructure.CimException] {
        $instances = Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue |
            Where-Object {
                $path = $null
                try { $path = $_.Path } catch { }
                $path -and $path.StartsWith((Join-Path (Split-Path $PSScriptRoot -Parent) 'profile-runtime'), [StringComparison]::OrdinalIgnoreCase)
            } |
            Select-Object @{Name='ProcessId';Expression={$_.Id}}, @{Name='CommandLine';Expression={'(command line unavailable in this session)'}}
    }

    if ($instances) {
        $instances
    }
    else {
        Write-Host 'No isolated Codex instances are running. The native/default instance is not included.'
    }
    return
}

if ($Profile -eq '--help') {
    Show-LauncherHelp
    return
}

if ([string]::IsNullOrWhiteSpace($Profile)) {
    $Profile = $DefaultProfile
}

$Profile = Resolve-ProfileName $Profile
$profileConfig = $Profiles[$Profile]
$exe = Get-CodexExecutable -AllowRuntimeFallback:($profileConfig.Mode -eq 'Isolated')

if ($profileConfig.Mode -eq 'Native') {
    $process = Start-Process -FilePath $exe -PassThru
    Write-Host "Launched Codex profile '$Profile' in Native mode (PID $($process.Id))"
    Write-Host '  No CODEX_HOME or --user-data-dir override was applied.'
}
elseif ($profileConfig.Mode -eq 'Isolated') {
    $paths = Get-ProfilePaths -Name $Profile -Root $ProfilesRoot
    $running = Get-RunningIsolatedProcesses -WebData $paths.WebData
    if ($running) {
        $processIds = @($running | ForEach-Object { if ($_.ProcessId) { $_.ProcessId } else { $_.Id } })
        $shown = Show-IsolatedWindow -ProcessIds $processIds
        $windowMessage = if ($shown) { 'The existing window was restored and focused.' } else { 'The process is running; its window is not ready yet.' }
        Write-Host "Profile '$Profile' is already running (PID $($processIds -join ', ')). $windowMessage"
        if ($TestNotification) { Write-Host 'Close this profile before running a notification startup test.' }
        return
    }
    New-Item -ItemType Directory -Force -Path $paths.CodexHome, $paths.WebData | Out-Null
    $exe = Get-IsolatedRuntime -InstalledExe $exe -Name $Profile -ProfileRoot $paths.Root
    Initialize-IsolatedProfileConfig -CodexHome $paths.CodexHome
    Initialize-IsolatedWindowsSandbox -CodexHome $paths.CodexHome -SandboxMode $profileConfig.WindowsSandbox
    Reset-IsolatedStartupPage -WebData $paths.WebData

    $oldCodexHome = $env:CODEX_HOME
    $oldElectronData = $env:CODEX_ELECTRON_USER_DATA_PATH
    $oldBuildFlavor = $env:BUILD_FLAVOR
    try {
        $env:CODEX_HOME = $paths.CodexHome
        # Owl chooses the data directory during native startup. Use the same
        # directory in both mechanisms; a later change is ignored by Owl.
        $env:CODEX_ELECTRON_USER_DATA_PATH = $paths.WebData

        Remove-Item Env:BUILD_FLAVOR -ErrorAction SilentlyContinue

        $launchArgs = @("--user-data-dir=`"$($paths.WebData)`"", '--profile-fresh-start')
        if ($TestNotification) { $launchArgs += '--profile-notification-test' }
        # Do not pass Hidden to the Electron main process. On this Owl build
        # that state is inherited by the first BrowserWindow.
        $process = Start-Process -FilePath $exe -ArgumentList $launchArgs -PassThru
    }
    finally {
        if ($null -eq $oldCodexHome) {
            Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue
        }
        else {
            $env:CODEX_HOME = $oldCodexHome
        }

        if ($null -eq $oldElectronData) {
            Remove-Item Env:CODEX_ELECTRON_USER_DATA_PATH -ErrorAction SilentlyContinue
        }
        else {
            $env:CODEX_ELECTRON_USER_DATA_PATH = $oldElectronData
        }

        if ($null -eq $oldBuildFlavor) {
            Remove-Item Env:BUILD_FLAVOR -ErrorAction SilentlyContinue
        }
        else {
            $env:BUILD_FLAVOR = $oldBuildFlavor
        }
    }

    Write-Host "Launched Codex profile '$Profile' in Isolated mode (PID $($process.Id))"
    Write-Host "  CODEX_HOME: $($paths.CodexHome)"
    Write-Host "  Web data:   $($paths.WebData)"
    Write-Host "  Independent runtime: $exe"
    Write-Host "  Notification diagnostics: $(Join-Path $paths.Root 'notification-routing.jsonl')"
}
else {
    throw "Profile '$Profile' has unsupported mode '$($profileConfig.Mode)'. Use Native or Isolated."
}

if ($PassThru) {
    $process
}
