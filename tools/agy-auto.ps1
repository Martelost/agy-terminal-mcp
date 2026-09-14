$ErrorActionPreference = 'Stop'

# ── Per-cwd pipe name (matches agy-terminal-bridge.ps1 v0.4.1) ───────────────
function Get-PerCwdPipeName {
    param([string]$Cwd)
    if ($env:AGY_TERMINAL_PIPE_NAME) { return $env:AGY_TERMINAL_PIPE_NAME }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Cwd.ToLowerInvariant())
    $hash  = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    $hex   = [BitConverter]::ToString($hash, 0, 4).Replace('-', '').ToLower()
    return "CodexAgySession_$hex"
}

$currentCwd = (Get-Location).Path
$pipeName   = Get-PerCwdPipeName -Cwd $currentCwd
$pipePath   = "\\.\pipe\$pipeName"

$SESSION_REGISTRY = Join-Path $env:TEMP 'codex-agy-sessions.json'
$REGISTRY_LOCK    = Join-Path $env:TEMP 'codex-agy-sessions.lock'

function Update-RegistryAgyPid {
    param([string]$TargetPipeName, [int]$NewAgyPid)
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        $lockStream = $null
        try {
            $lockStream = [System.IO.File]::Open(
                $REGISTRY_LOCK,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None)

            $sessions = [System.Collections.ArrayList]@()
            if (Test-Path -LiteralPath $SESSION_REGISTRY) {
                try {
                    $raw = [System.IO.File]::ReadAllText($SESSION_REGISTRY, [System.Text.Encoding]::UTF8)
                    $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
                    if ($null -ne $parsed) {
                        $arr = if ($parsed -is [array]) { $parsed } else { @($parsed) }
                        foreach ($e in $arr) { [void]$sessions.Add($e) }
                    }
                } catch { }
            }

            $out = [System.Collections.ArrayList]@()
            foreach ($e in $sessions) {
                if ([string]$e.pipeName -eq $TargetPipeName) {
                    $updated = [ordered]@{}
                    $e.PSObject.Properties | ForEach-Object { $updated[$_.Name] = $_.Value }
                    $updated['agyPid'] = $NewAgyPid
                    [void]$out.Add($updated)
                } else {
                    [void]$out.Add($e)
                }
            }

            $tmp = $SESSION_REGISTRY + '.tmp'
            $json = if ($out.Count -eq 0) { '[]' } else { $out | ConvertTo-Json -Compress -Depth 5 }
            [System.IO.File]::WriteAllText($tmp, $json, [System.Text.Encoding]::UTF8)
            Move-Item -LiteralPath $tmp -Destination $SESSION_REGISTRY -Force
            return
        } catch [System.IO.IOException] {
            Start-Sleep -Milliseconds 80
        } catch {
            return
        } finally {
            if ($null -ne $lockStream) { $lockStream.Close(); $lockStream.Dispose() }
        }
    }
}

# Locate the bridge script from the newest installed plugin version
$pluginRoot = Join-Path $env:USERPROFILE '.codex\plugins\cache\agy-terminal-mcp\agy-terminal'
$bridgeLauncher = $null
if (Test-Path -LiteralPath $pluginRoot -PathType Container) {
    $newest = Get-ChildItem -LiteralPath $pluginRoot -Directory |
              Where-Object { $_.Name -match '^\d+\.\d+\.\d+' } |
              Sort-Object { try { [version]($_.Name -replace '[-+].*$','') } catch { [version]'0.0.0' } } -Descending |
              Select-Object -First 1
    if ($null -ne $newest) {
        $candidate = Join-Path $newest.FullName 'mcp\agy-terminal-bridge.ps1'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $bridgeLauncher = $candidate
        }
    }
}

$realAgy = Join-Path $env:LOCALAPPDATA 'agy\bin\agy.exe'
if (-not (Test-Path -LiteralPath $realAgy -PathType Leaf)) {
    $cmd = Get-Command agy.exe -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -ne $MyInvocation.MyCommand.Path) {
        $realAgy = $cmd.Source
    } else {
        throw "The real agy executable was not found at '$realAgy'."
    }
}

# Normalize incoming arguments safely so $null or empty elements don't cause binding issues
$rawArgs = if ($null -eq $args) { @() } else { @($args) }
$nonEmptyArgs = @($rawArgs | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace("$_") })

# Keep the normal agy command fast for informational flags (--version, -h, etc.)
$isInfoFlag = ($nonEmptyArgs.Count -gt 0) -and
    (($nonEmptyArgs | Where-Object { $_ -notin @('--version', '-V', '--help', '-h') }).Count -eq 0)

$startsInteractiveSession = -not $isInfoFlag

if ($startsInteractiveSession -and $null -ne $bridgeLauncher) {
    $cleanCwdName = ($currentCwd.ToLower() -replace '[^a-z0-9]','_')
    $mutexName    = "Local\CodexAgyBridgeLauncher_$cleanCwdName"
    $mutex        = [System.Threading.Mutex]::new($false, $mutexName)
    $ownsMutex    = $false
    try {
        $ownsMutex = $mutex.WaitOne(0)
        if ($ownsMutex -and -not (Test-Path -LiteralPath $pipePath)) {
            Start-Process -FilePath 'powershell.exe' `
                -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                                '-File', $bridgeLauncher, '-PipeName', $pipeName) `
                -WorkingDirectory $currentCwd `
                -WindowStyle Normal | Out-Null
        }
    } finally {
        if ($ownsMutex) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }

    # Give the bridge time to create its named pipe before agy takes over the terminal.
    for ($attempt = 0; $attempt -lt 30 -and -not (Test-Path -LiteralPath $pipePath); $attempt++) {
        Start-Sleep -Milliseconds 100
    }
}

if ($startsInteractiveSession) {
    # PowerShell 5.1 rejects an empty -ArgumentList.
    # Omitting -ArgumentList completely when there are no arguments prevents
    # "Cannot bind argument to parameter 'ArgumentList' because it is an empty array."
    $startParams = @{
        FilePath    = $realAgy
        NoNewWindow = $true
        PassThru    = $true
    }
    if ($nonEmptyArgs.Count -gt 0) {
        $startParams['ArgumentList'] = $nonEmptyArgs
    }

    $proc = Start-Process @startParams
    if ($null -ne $proc -and $proc.Id -gt 0) {
        Update-RegistryAgyPid -TargetPipeName $pipeName -NewAgyPid $proc.Id
        try {
            $proc.WaitForExit()
            exit $proc.ExitCode
        } finally {
            Update-RegistryAgyPid -TargetPipeName $pipeName -NewAgyPid 0
        }
    }
}

if ($nonEmptyArgs.Count -gt 0) {
    & $realAgy @nonEmptyArgs
} else {
    & $realAgy
}
exit $LASTEXITCODE
