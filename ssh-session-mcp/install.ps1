[CmdletBinding()]
param(
    [string]$HostsFile = (Join-Path $env:USERPROFILE '.codex\ssh-sessions\hosts.json'),
    [string]$InstallDir = (Join-Path $env:USERPROFILE '.codex\mcp\ssh-sessions')
)
$ErrorActionPreference = 'Stop'
$sourceDir = $PSScriptRoot
$nodeExecutable = (Get-Command node.exe -ErrorAction Stop).Source
$npmExecutable = (Get-Command npm.cmd -ErrorAction Stop).Source
$codexExecutable = (Get-Command codex.exe -ErrorAction Stop).Source
$HostsFile = [IO.Path]::GetFullPath($HostsFile)
$InstallDir = [IO.Path]::GetFullPath($InstallDir)
if (-not (Test-Path -LiteralPath $HostsFile -PathType Leaf)) { throw 'Create the local hosts.json first.' }
if ($InstallDir -eq [IO.Path]::GetFullPath($sourceDir)) { throw 'InstallDir must differ from the source directory.' }
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
foreach ($filename in @('package.json', 'package-lock.json', 'README.md')) {
    Copy-Item -LiteralPath (Join-Path $sourceDir $filename) -Destination $InstallDir -Force
}
$installedSource = Join-Path $InstallDir 'src'
New-Item -ItemType Directory -Path $installedSource -Force | Out-Null
Get-ChildItem -LiteralPath (Join-Path $sourceDir 'src') -File | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $installedSource -Force
}
Push-Location $InstallDir
try {
    & $npmExecutable ci --omit=dev --ignore-scripts --no-audit --no-fund
    if ($LASTEXITCODE -ne 0) { throw 'npm ci failed.' }
} finally { Pop-Location }
$serverPath = Join-Path $InstallDir 'src\server.mjs'
& $codexExecutable mcp add ssh-sessions --env "SSH_SESSION_HOSTS=$HostsFile" -- $nodeExecutable $serverPath
if ($LASTEXITCODE -ne 0) { throw 'MCP registration failed.' }
Write-Host "Installed SSH Sessions MCP at $InstallDir. Reload the MCP client once to load its tools."
