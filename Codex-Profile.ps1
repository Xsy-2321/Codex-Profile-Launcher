[CmdletBinding(DefaultParameterSetName = 'Launch')]
param(
    [Parameter(Position = 0, ParameterSetName = 'Launch')]
    [string]$Profile,

    [Parameter(ParameterSetName = 'Launch')]
    [string]$ProfilesRoot = (Join-Path $env:LOCALAPPDATA 'CodexProfiles'),

    [Parameter(ParameterSetName = 'Launch')]
    [switch]$PassThru,

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
    Personal = @{ Mode = 'Isolated'; Description = 'Separate personal account and application state' }
}

function Get-CodexExecutable {
    $package = Get-AppxPackage -Name 'OpenAI.Codex' |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if (-not $package) {
        throw 'The OpenAI Codex Windows app is not installed for this user.'
    }

    $executable = Join-Path $package.InstallLocation 'app\ChatGPT.exe'
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw "Codex executable was not found at: $executable"
    }

    return $executable
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
        Root      = $profileRoot
        CodexHome = Join-Path $profileRoot 'codex-home'
        WebData   = Join-Path $profileRoot 'web-data'
    }
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

function Show-LauncherHelp {
    @"
Codex profile launcher

Usage:
  .\Codex-Profile.ps1                       Launch the default profile
  .\Codex-Profile.ps1 <profile>             Launch a configured profile
  .\Codex-Profile.ps1 -Profile <profile>    Launch a configured profile
  .\Codex-Profile.ps1 -Status               Show running isolated instances
  .\Codex-Profile.ps1 -InstallShortcuts     Create a shortcut for every profile
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
Isolated mode stores data below: $((Join-Path $env:LOCALAPPDATA 'CodexProfiles'))
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
    $exe = Get-CodexExecutable
    $instances = Get-CimInstance Win32_Process |
        Where-Object {
            $_.ExecutablePath -eq $exe -and
            $_.CommandLine -match '--user-data-dir=' -and
            $_.CommandLine -notmatch '--type='
        } |
        Select-Object ProcessId, CommandLine

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
$exe = Get-CodexExecutable

if ($profileConfig.Mode -eq 'Native') {
    $process = Start-Process -FilePath $exe -PassThru
    Write-Host "Launched Codex profile '$Profile' in Native mode (PID $($process.Id))"
    Write-Host '  No CODEX_HOME or --user-data-dir override was applied.'
}
elseif ($profileConfig.Mode -eq 'Isolated') {
    $paths = Get-ProfilePaths -Name $Profile -Root $ProfilesRoot
    New-Item -ItemType Directory -Force -Path $paths.CodexHome, $paths.WebData | Out-Null
    Initialize-IsolatedProfileConfig -CodexHome $paths.CodexHome

    $oldCodexHome = $env:CODEX_HOME
    try {
        $env:CODEX_HOME = $paths.CodexHome
        $process = Start-Process -FilePath $exe -ArgumentList @(
            "--user-data-dir=`"$($paths.WebData)`""
        ) -PassThru
    }
    finally {
        if ($null -eq $oldCodexHome) {
            Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue
        }
        else {
            $env:CODEX_HOME = $oldCodexHome
        }
    }

    Write-Host "Launched Codex profile '$Profile' in Isolated mode (PID $($process.Id))"
    Write-Host "  CODEX_HOME: $($paths.CodexHome)"
    Write-Host "  Web data:   $($paths.WebData)"
}
else {
    throw "Profile '$Profile' has unsupported mode '$($profileConfig.Mode)'. Use Native or Isolated."
}

if ($PassThru) {
    $process
}
