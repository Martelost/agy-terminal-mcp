#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Cwd,
    [Parameter(Mandatory = $true)][string]$PipeName,
    [Parameter(Mandatory = $true)][string]$ResultFile
)
$ErrorActionPreference = 'Stop'
$launcher = Join-Path $env:USERPROFILE '.codex\bin\agy-auto.ps1'
if (-not (Test-Path -LiteralPath $Cwd -PathType Container)) { throw 'cwd must be an existing directory.' }
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw 'The AGY launcher is not installed. Run the repository installer first.' }
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
# A classic console keeps the same screen readable through AttachConsole while
# the user can type directly. Never use a headless host or redirect AGY's stdin.
$env:AGY_TERMINAL_PIPE_NAME = $PipeName
$arguments = @(
    ('"{0}"' -f $powershell), '-NoLogo', '-NoProfile', '-NoExit',
    '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $launcher)
)
$hostProcess = Start-Process -FilePath $conhost -ArgumentList $arguments -WorkingDirectory $Cwd -WindowStyle Normal -PassThru
[ordered]@{ status = 'opened'; hostPid = $hostProcess.Id; cwd = $Cwd } |
    ConvertTo-Json -Compress | Set-Content -LiteralPath $ResultFile -Encoding UTF8
