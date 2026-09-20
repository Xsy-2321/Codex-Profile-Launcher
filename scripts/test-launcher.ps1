$ErrorActionPreference='Stop'
$script=Join-Path $PSScriptRoot '..\Codex-Profile.ps1'
$tokens=$null; $parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($script,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw ($parseErrors | Out-String)}
# Load only pure/config functions, never the launcher's entry point.
$ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in @('Initialize-IsolatedWindowsSandbox','Initialize-IsolatedProfileConfig')},$false) | ForEach-Object {Invoke-Expression $_.Extent.Text}
$root=Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) ('config-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$cases=@('',"model = 'test'`r`n", "[windows]`r`nsandbox = 'elevated'`r`n[other]`r`nx = 1`r`n", "[windows] # comment`r`nfoo = 1`r`n[other]`r`nx = 1`r`n", "[windows]`nsandbox = 'elevated' # keep`n[other]`nx = 1`n", '[windows]')
foreach($case in $cases){
    [IO.File]::WriteAllText((Join-Path $root 'config.toml'),$case)
    Initialize-IsolatedWindowsSandbox $root 'unelevated'
    Initialize-IsolatedProfileConfig $root
    $once=[IO.File]::ReadAllText((Join-Path $root 'config.toml'))
    Initialize-IsolatedWindowsSandbox $root 'unelevated'
    Initialize-IsolatedProfileConfig $root
    $twice=[IO.File]::ReadAllText((Join-Path $root 'config.toml'))
    if($once -cne $twice){throw 'Not idempotent'}
    if(([regex]::Matches($once,'(?m)^\[windows\]')).Count -ne 1){throw 'Duplicate windows section'}
    if($once -notmatch 'sandbox = "unelevated"'){throw 'Missing sandbox setting'}
    if($case.Contains('[other]') -and $once -notmatch '\[other\]\r?\nx = 1'){throw 'Other section corrupted'}
    if($case.Contains('# keep') -and !$once.Contains('# keep')){throw 'Comment lost'}
}
Write-Output 'PASS: launcher parses; six config cases preserve unrelated sections and are idempotent.'
Write-Output "Fixtures: $root"
