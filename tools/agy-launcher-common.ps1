# Shared discovery used by the installer and the installed launcher.
# This file is copied alongside agy-auto.ps1.

function Get-AgyExecutable {
    [CmdletBinding()]
    param(
        [string]$UserProfile = $env:USERPROFILE,
        [string]$LocalAppData = $env:LOCALAPPDATA,
        [string]$WrapperDirectory = $PSScriptRoot
    )

    $defaultPath = Join-Path $LocalAppData 'agy\bin\agy.exe'
    if (Test-Path -LiteralPath $defaultPath -PathType Leaf) {
        return (Get-Item -LiteralPath $defaultPath).FullName
    }

    # A shim next to this script or in .codex\bin can call the launcher again.
    $excluded = @(
        [System.IO.Path]::GetFullPath((Join-Path $UserProfile '.codex\bin\agy.exe')),
        [System.IO.Path]::GetFullPath((Join-Path $WrapperDirectory 'agy.exe'))
    )
    foreach ($command in @(Get-Command agy.exe -CommandType Application -All -ErrorAction SilentlyContinue)) {
        if (-not $command.Source) { continue }
        $candidate = [System.IO.Path]::GetFullPath($command.Source)
        if ($candidate -notin $excluded -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return $candidate
        }
    }
    return $null
}

function Get-AgyBridgeLauncher {
    [CmdletBinding()]
    param([string]$UserProfile = $env:USERPROFILE)

    $candidates = @()
    foreach ($namespace in @('agy-terminal-mcp', 'banklist-local')) {
        $root = Join-Path $UserProfile ".codex\plugins\cache\$namespace\agy-terminal"
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($directory in @(Get-ChildItem -LiteralPath $root -Directory)) {
            if ($directory.Name -notmatch '^\d+\.\d+\.\d+(?:[-+].*)?$') { continue }
            try { $version = [version]($directory.Name -replace '[-+].*$', '') } catch { continue }
            $path = Join-Path $directory.FullName 'mcp\agy-terminal-bridge.ps1'
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $candidates += [pscustomobject]@{ Path = $path; Version = $version }
            }
        }
    }
    $newest = $candidates | Sort-Object Version -Descending | Select-Object -First 1
    if ($null -ne $newest) { return $newest.Path }
    return $null
}

function Backup-AgyLauncherShim {
    [CmdletBinding()]
    param([string]$UserProfile = $env:USERPROFILE)

    # Only the exact conflicting filename is eligible; never alter the real CLI.
    $shimPath = Join-Path $UserProfile '.codex\bin\agy.exe'
    if (-not (Test-Path -LiteralPath $shimPath -PathType Leaf)) { return $null }
    $signature = Get-AuthenticodeSignature -LiteralPath $shimPath
    if ($signature.Status -ne 'NotSigned') {
        throw "Refusing to rename '$shimPath': signature status is $($signature.Status). Review this file manually."
    }
    $backupPath = $shimPath + '.disabled'
    if (Test-Path -LiteralPath $backupPath) {
        $backupPath = $shimPath + '.disabled.' + [guid]::NewGuid().ToString('N')
    }
    Rename-Item -LiteralPath $shimPath -NewName ([System.IO.Path]::GetFileName($backupPath)) -ErrorAction Stop
    return $backupPath
}
