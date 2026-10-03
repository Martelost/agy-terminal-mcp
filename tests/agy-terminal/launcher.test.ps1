#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$powershellPath = (Get-Command powershell.exe).Source
$nodeDirectory = Split-Path -Parent (Get-Command node.exe -CommandType Application | Select-Object -First 1).Source
$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('agy-launcher-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
. (Join-Path $repoRoot 'tools\agy-launcher-common.ps1')
$script:passed = 0
$script:failed = 0
$script:commandCandidates = @()
$script:signatureStatus = 'NotSigned'

# Discovery is tested against simulated PATH results, never by launching AGY.
function Get-Command {
    [CmdletBinding()]
    param([string]$Name, [string]$CommandType, [switch]$All)
    if ($Name -eq 'agy.exe') {
        foreach ($candidate in $script:commandCandidates) {
            [pscustomobject]@{ Source = $candidate }
        }
    } else {
        Microsoft.PowerShell.Core\Get-Command @PSBoundParameters
    }
}
function Get-AuthenticodeSignature {
    [CmdletBinding()]
    param([string]$LiteralPath)
    [pscustomobject]@{ Status = $script:signatureStatus }
}
function New-FixtureFile {
    param([string]$RelativePath, [string]$Content = 'fixture')
    $path = Join-Path $fixtureRoot $RelativePath
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    [System.IO.File]::WriteAllText($path, $Content)
    return $path
}
function Assert-Equal {
    param($Actual, $Expected)
    if ($Actual -ne $Expected) { throw "Expected '$Expected', got '$Actual'." }
}
function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:passed++
        Write-Host "[PASS] $Name"
    } catch {
        $script:failed++
        Write-Host "[FAIL] $Name : $($_.Exception.Message)"
    }
}
function Get-FixtureSnapshot {
    param([string]$Root)
    # Windows PowerShell may create its own AppData startup caches in a new
    # profile. Exclude that OS-managed subtree; installer destinations are
    # .codex, local (the simulated CLI directory), and the registry at Root.
    $runtimeAppData = Join-Path $Root 'AppData'
    return (@(Get-ChildItem -LiteralPath $Root -Recurse -Force | Where-Object {
        $_.FullName -ne $runtimeAppData -and
        -not $_.FullName.StartsWith($runtimeAppData + '\', [StringComparison]::OrdinalIgnoreCase)
    } | ForEach-Object {
        $relative = $_.FullName.Substring($Root.Length)
        if ($_.PSIsContainer) { "directory:$relative" }
        else { "$relative=$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" }
    } | Sort-Object) -join '|')
}
function Invoke-IsolatedInstaller {
    param([string]$Profile, [switch]$Check, [switch]$RepairLauncher)
    $installer = Join-Path $repoRoot 'tools\agy-terminal-install.ps1'
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powershellPath
    $startInfo.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $installer + '"'
    if ($Check) { $startInfo.Arguments += ' -Check' }
    if ($RepairLauncher) { $startInfo.Arguments += ' -RepairLauncher' }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['USERPROFILE'] = $Profile
    $startInfo.EnvironmentVariables['LOCALAPPDATA'] = Join-Path $Profile 'local'
    $startInfo.EnvironmentVariables['TEMP'] = $Profile
    $startInfo.EnvironmentVariables['TMP'] = $Profile
    $startInfo.EnvironmentVariables['PATH'] = (Join-Path $Profile '.codex\bin') + ';' + $nodeDirectory + ';' + (Join-Path $env:SystemRoot 'System32')
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(15000)) {
            $process.Kill()
            throw 'Installer test timed out.'
        }
        [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $stdout.Result + $stderr.Result }
    } finally { $process.Dispose() }
}

try {
    $profile = Join-Path $fixtureRoot 'profile'
    $local = Join-Path $fixtureRoot 'local'
    $wrapper = Join-Path $fixtureRoot 'wrapper'
    $shim = New-FixtureFile 'profile\.codex\bin\agy.exe'
    $adjacentShim = New-FixtureFile 'wrapper\agy.exe'
    $real = New-FixtureFile 'real cli\agy.exe'
    $script:commandCandidates = @($shim, $adjacentShim, $real)

    Test-Case 'PATH fallback skips both launcher shims and finds the real CLI' {
        Assert-Equal (Get-AgyExecutable -UserProfile $profile -LocalAppData $local -WrapperDirectory $wrapper) $real
    }
    Test-Case 'PATH containing only shims does not recurse into the launcher' {
        $script:commandCandidates = @($shim.ToUpperInvariant(), $adjacentShim)
        Assert-Equal (Get-AgyExecutable -UserProfile $profile -LocalAppData $local -WrapperDirectory $wrapper) $null
    }
    Test-Case 'Default AGY installation takes precedence over PATH' {
        $default = New-FixtureFile 'local\agy\bin\agy.exe'
        $script:commandCandidates = @($shim, $real)
        Assert-Equal (Get-AgyExecutable -UserProfile $profile -LocalAppData $local -WrapperDirectory $wrapper) $default
    }
    Test-Case 'Bridge discovery supports the legacy plugin namespace' {
        $legacy = New-FixtureFile 'profile\.codex\plugins\cache\banklist-local\agy-terminal\0.4.1\mcp\agy-terminal-bridge.ps1'
        Assert-Equal (Get-AgyBridgeLauncher -UserProfile $profile) $legacy
    }
    Test-Case 'Bridge discovery chooses the newest complete installation across namespaces' {
        $newest = New-FixtureFile 'profile\.codex\plugins\cache\agy-terminal-mcp\agy-terminal\0.5.0\mcp\agy-terminal-bridge.ps1'
        [void](New-FixtureFile 'profile\.codex\plugins\cache\banklist-local\agy-terminal\0.6.0\incomplete.txt')
        [void](New-FixtureFile 'profile\.codex\plugins\cache\agy-terminal-mcp\agy-terminal\latest\mcp\agy-terminal-bridge.ps1')
        Assert-Equal (Get-AgyBridgeLauncher -UserProfile $profile) $newest
    }
    Test-Case 'Missing bridge is reported as null' {
        Assert-Equal (Get-AgyBridgeLauncher -UserProfile (Join-Path $fixtureRoot 'no-plugin')) $null
    }
    Test-Case 'Unsigned shim repair backs up the contents and preserves the real CLI' {
        $realHash = (Get-FileHash -LiteralPath $real).Hash
        $backup = Backup-AgyLauncherShim -UserProfile $profile
        Assert-Equal $backup ($shim + '.disabled')
        Assert-Equal (Test-Path -LiteralPath $shim) $false
        Assert-Equal (Get-Content -Raw -LiteralPath $backup) 'fixture'
        Assert-Equal (Get-FileHash -LiteralPath $real).Hash $realHash
    }
    Test-Case 'Repeated repair preserves an existing backup' {
        [void](New-FixtureFile 'profile\.codex\bin\agy.exe' 'second shim')
        $backup = Backup-AgyLauncherShim -UserProfile $profile
        Assert-Equal (Get-Content -Raw -LiteralPath ($shim + '.disabled')) 'fixture'
        Assert-Equal (Get-Content -Raw -LiteralPath $backup) 'second shim'
    }
    Test-Case 'Signed executable is not renamed by repair' {
        [void](New-FixtureFile 'profile\.codex\bin\agy.exe' 'signed fixture')
        $script:signatureStatus = 'Valid'
        $rejected = $false
        try { Backup-AgyLauncherShim -UserProfile $profile } catch { $rejected = $true }
        Assert-Equal $rejected $true
        Assert-Equal (Get-Content -Raw -LiteralPath $shim) 'signed fixture'
        $script:signatureStatus = 'NotSigned'
    }
    Test-Case 'Repair is a no-op when there is no conflicting shim' {
        Assert-Equal (Backup-AgyLauncherShim -UserProfile (Join-Path $fixtureRoot 'no-plugin')) $null
    }
    Test-Case 'Unverifiable executable is not renamed by repair' {
        $script:signatureStatus = 'UnknownError'
        $rejected = $false
        try { Backup-AgyLauncherShim -UserProfile $profile } catch { $rejected = $true }
        Assert-Equal $rejected $true
        Assert-Equal (Get-Content -Raw -LiteralPath $shim) 'signed fixture'
        $script:signatureStatus = 'NotSigned'
    }

    $installProfile = Join-Path $fixtureRoot 'installed profile'
    [void](New-FixtureFile 'installed profile\local\agy\bin\agy.exe')
    New-Item -ItemType Directory -Path (Join-Path $installProfile '.codex\skills') -Force | Out-Null
    Test-Case 'Installer copies hidden plugin metadata and all launcher dependencies' {
        $result = Invoke-IsolatedInstaller -Profile $installProfile
        if ($result.ExitCode -ne 0) { throw $result.Output }
        foreach ($file in @(
            '.codex\bin\agy.cmd', '.codex\bin\agy-auto.ps1', '.codex\bin\agy-launcher-common.ps1',
            '.codex\plugins\cache\agy-terminal-mcp\agy-terminal\0.5.0\.mcp.json',
            '.codex\plugins\cache\agy-terminal-mcp\agy-terminal\0.5.0\.codex-plugin\plugin.json'
        )) {
            Assert-Equal (Test-Path -LiteralPath (Join-Path $installProfile $file) -PathType Leaf) $true
        }
    }
    Test-Case 'Doctor succeeds on a complete installation without changing any files' {
        $before = Get-FixtureSnapshot $installProfile
        $result = Invoke-IsolatedInstaller -Profile $installProfile -Check
        if ($result.ExitCode -ne 0) { throw $result.Output }
        Assert-Equal (Get-FixtureSnapshot $installProfile) $before
    }
    Test-Case 'Doctor recognizes a complete legacy cache installation' {
        $cacheRoot = Join-Path $installProfile '.codex\plugins\cache\agy-terminal-mcp'
        if (-not $cacheRoot.StartsWith($fixtureRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Unexpected cache fixture path.'
        }
        Rename-Item -LiteralPath $cacheRoot -NewName 'banklist-local'
        $before = Get-FixtureSnapshot $installProfile
        $result = Invoke-IsolatedInstaller -Profile $installProfile -Check
        if ($result.ExitCode -ne 0) { throw $result.Output }
        Assert-Equal ($result.Output -match 'banklist-local') $true
        Assert-Equal (Get-FixtureSnapshot $installProfile) $before
    }
    Test-Case 'Doctor detects a shadowing shim and remains read-only' {
        [void](New-FixtureFile 'installed profile\.codex\bin\agy.exe')
        $before = Get-FixtureSnapshot $installProfile
        $result = Invoke-IsolatedInstaller -Profile $installProfile -Check
        Assert-Equal $result.ExitCode 1
        Assert-Equal ($result.Output -match 'shadows agy.cmd') $true
        Assert-Equal (Get-FixtureSnapshot $installProfile) $before
    }
    Test-Case 'Doctor cannot be combined with a repair operation' {
        $before = Get-FixtureSnapshot $installProfile
        $result = Invoke-IsolatedInstaller -Profile $installProfile -Check -RepairLauncher
        Assert-Equal $result.ExitCode 1
        Assert-Equal ($result.Output -match 'read-only') $true
        Assert-Equal (Get-FixtureSnapshot $installProfile) $before
    }
    $missingCliProfile = Join-Path $fixtureRoot 'missing cli'
    [void](New-FixtureFile 'missing cli\.codex\bin\agy.exe')
    Test-Case 'Doctor does not mistake a launcher shim for the real CLI' {
        $before = Get-FixtureSnapshot $missingCliProfile
        $result = Invoke-IsolatedInstaller -Profile $missingCliProfile -Check
        Assert-Equal $result.ExitCode 1
        Assert-Equal ($result.Output -match 'Real AGY executable not found') $true
        Assert-Equal (Get-FixtureSnapshot $missingCliProfile) $before
    }
    Test-Case 'Repair requires a separate real CLI before modifying the installation' {
        $before = Get-FixtureSnapshot $missingCliProfile
        $result = Invoke-IsolatedInstaller -Profile $missingCliProfile -RepairLauncher
        Assert-Equal $result.ExitCode 1
        Assert-Equal ($result.Output -match 'Cannot repair the launcher without a separate real AGY') $true
        Assert-Equal (Get-FixtureSnapshot $missingCliProfile) $before
    }
} finally {
    # Validate the exact generated fixture path before recursive cleanup.
    $resolvedFixture = [System.IO.Path]::GetFullPath($fixtureRoot)
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolvedFixture.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [System.IO.Path]::GetFileName($resolvedFixture) -match '^agy-launcher-tests-[0-9a-f]{32}$') {
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    } else { throw "Refusing to remove an unexpected fixture path: $resolvedFixture" }
}
Write-Host "$script:passed passed, $script:failed failed"
if ($script:failed -gt 0) { exit 1 }
