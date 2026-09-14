#Requires -Version 5.1
# agy-terminal-bridge.ps1 -- AGY Terminal MCP bridge v0.4.1
# Registers this session in %TEMP%\codex-agy-sessions.json so the MCP server
# can route agy_run calls to the correct terminal per cwd.
#
# Registry entry shape:
#   sessionId     : GUID (no dashes)
#   cwd           : absolute path of the project directory
#   bridgePid     : PID of THIS bridge process (for liveness check)
#   agyPid        : PID of the agy.exe process visible in the same terminal window
#                   (populated after agy starts; updated every 5 s while running)
#   pipeName      : CodexAgySession_<8hex> derived from cwd
#   pluginVersion : "0.4.1"
#   startedAt     : ISO-8601
#
[CmdletBinding()]
param(
    [string]$PipeName = '',
    [int]$AgyPid = 0
)

$ErrorActionPreference = 'Continue'

$PLUGIN_VERSION   = '0.4.1'
$SESSION_REGISTRY = Join-Path $env:TEMP 'codex-agy-sessions.json'
$REGISTRY_LOCK    = Join-Path $env:TEMP 'codex-agy-sessions.lock'

# ── Hash helper ───────────────────────────────────────────────────────────────

function Get-CwdHash {
    param([string]$Path)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant())
    $hash  = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    [BitConverter]::ToString($hash, 0, 4).Replace('-', '').ToLower()
}

# ── Atomic registry helpers ───────────────────────────────────────────────────
# Uses a .lock file + retry loop so two concurrent bridge instances
# do not corrupt the shared JSON file.

function Invoke-RegistryEdit {
    param([scriptblock]$Transform)
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        $lockStream = $null
        try {
            $lockStream = [System.IO.File]::Open(
                $REGISTRY_LOCK,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None)

            # Read current sessions
            $sessions = [System.Collections.ArrayList]@()
            if (Test-Path -LiteralPath $SESSION_REGISTRY) {
                try {
                    $raw   = [System.IO.File]::ReadAllText($SESSION_REGISTRY, [System.Text.Encoding]::UTF8)
                    $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
                    if ($null -ne $parsed) {
                        $arr = if ($parsed -is [array]) { $parsed } else { @($parsed) }
                        foreach ($e in $arr) { [void]$sessions.Add($e) }
                    }
                } catch { }
            }

            # Apply the transform (receives ArrayList, returns ArrayList)
            $sessions = & $Transform $sessions

            # Write back atomically via temp file + move
            $tmp = $SESSION_REGISTRY + '.tmp'
            $json = if ($sessions.Count -eq 0) { '[]' } else { $sessions | ConvertTo-Json -Compress -Depth 5 }
            [System.IO.File]::WriteAllText($tmp, $json, [System.Text.Encoding]::UTF8)
            Move-Item -LiteralPath $tmp -Destination $SESSION_REGISTRY -Force
            return
        } catch [System.IO.IOException] {
            # Lock busy -- another process holds it; wait and retry
            Start-Sleep -Milliseconds 80
        } catch {
            Write-Host "[agy bridge] Registry warning: $($_.Exception.Message)" -ForegroundColor Yellow
            return
        } finally {
            if ($null -ne $lockStream) { $lockStream.Close(); $lockStream.Dispose() }
        }
    }
    Write-Host '[agy bridge] Warning: could not acquire registry lock within 10 s.' -ForegroundColor Yellow
}

function Register-Session {
    param([string]$SessionId, [string]$Cwd, [string]$PipeName, [int]$BridgePid, [int]$InitialAgyPid = 0)
    Invoke-RegistryEdit {
        param([System.Collections.ArrayList]$sessions)
        # Remove stale: same cwd or dead bridge process
        $live = [System.Collections.ArrayList]@()
        $normCwd = try { [System.IO.Path]::GetFullPath($Cwd).TrimEnd('\','/').ToLowerInvariant() } catch { [string]$Cwd.ToLowerInvariant() }
        foreach ($e in $sessions) {
            $epid = if ($e.bridgePid) { [int]$e.bridgePid } else { [int]$e.pid }
            if ($epid -eq 0) { continue }
            try {
                Get-Process -Id $epid -ErrorAction Stop | Out-Null
                $eNormCwd = try { [System.IO.Path]::GetFullPath($e.cwd).TrimEnd('\','/').ToLowerInvariant() } catch { [string]$e.cwd.ToLowerInvariant() }
                if ($eNormCwd -ne $normCwd) { [void]$live.Add($e) }
            } catch { } # dead -- drop it
        }
        [void]$live.Add([ordered]@{
            sessionId     = $SessionId
            cwd           = $Cwd
            bridgePid     = $BridgePid
            agyPid        = $InitialAgyPid
            pipeName      = $PipeName
            pluginVersion = $PLUGIN_VERSION
            startedAt     = (Get-Date -Format 'o')
        })
        $live
    }
}

function Update-AgyPid {
    param([string]$SessionId, [int]$AgyPid)
    Invoke-RegistryEdit {
        param([System.Collections.ArrayList]$sessions)
        $out = [System.Collections.ArrayList]@()
        foreach ($e in $sessions) {
            if ([string]$e.sessionId -eq $SessionId) {
                $updated = [ordered]@{}
                $e.PSObject.Properties | ForEach-Object { $updated[$_.Name] = $_.Value }
                $updated['agyPid'] = $AgyPid
                [void]$out.Add($updated)
            } else {
                [void]$out.Add($e)
            }
        }
        $out
    }
}

function Unregister-Session {
    param([string]$SessionId)
    Invoke-RegistryEdit {
        param([System.Collections.ArrayList]$sessions)
        $out = [System.Collections.ArrayList]@()
        foreach ($e in $sessions) {
            if ([string]$e.sessionId -ne $SessionId) { [void]$out.Add($e) }
        }
        $out
    }
}

# ── Pipe factory ──────────────────────────────────────────────────────────────

function New-AgyPipe {
    param([string]$Name)
    $pipeSecurity  = [System.IO.Pipes.PipeSecurity]::new()
    $pipeIdentities = [System.Collections.ArrayList]@(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    )
    try {
        $sandboxSid = ([System.Security.Principal.NTAccount]::new(
            "$env:COMPUTERNAME\CodexSandboxOffline"
        )).Translate([System.Security.Principal.SecurityIdentifier])
        [void]$pipeIdentities.Add($sandboxSid)
    } catch { }

    foreach ($id in $pipeIdentities) {
        $pipeSecurity.AddAccessRule([System.IO.Pipes.PipeAccessRule]::new(
            $id,
            [System.IO.Pipes.PipeAccessRights]::FullControl,
            [System.Security.AccessControl.AccessControlType]::Allow
        ))
    }

    $ctorArgs = @(
        $Name,
        [System.IO.Pipes.PipeDirection]::InOut,
        [int]1,
        [System.IO.Pipes.PipeTransmissionMode]::Byte,
        [System.IO.Pipes.PipeOptions]::None,
        [int]8192,
        [int]8192,
        $pipeSecurity
    )
    try {
        # Windows PowerShell 5.x
        [System.IO.Pipes.NamedPipeServerStream]::new.Invoke($ctorArgs)
    } catch {
        # PowerShell 7
        [System.IO.Pipes.NamedPipeServerStreamAcl]::Create(
            $Name,
            [System.IO.Pipes.PipeDirection]::InOut,
            1,
            [System.IO.Pipes.PipeTransmissionMode]::Byte,
            [System.IO.Pipes.PipeOptions]::None,
            8192, 8192,
            $pipeSecurity,
            [System.IO.HandleInheritability]::None,
            [System.IO.Pipes.PipeAccessRights]::FullControl
        )
    }
}

# ── Send bridge response ──────────────────────────────────────────────────────

function Send-BridgeResponse {
    param([System.IO.StreamWriter]$Writer, $Response)
    $Writer.WriteLine(($Response | ConvertTo-Json -Compress -Depth 8))
    $Writer.Flush()
}

# ── Main ──────────────────────────────────────────────────────────────────────

$cwd       = (Get-Location).Path
$sessionId = [System.Guid]::NewGuid().ToString('N')
$cwdHash   = Get-CwdHash -Path $cwd

if ([string]::IsNullOrWhiteSpace($PipeName)) {
    $PipeName = "CodexAgySession_$cwdHash"
}

Write-Host ''
Write-Host "+-- AGY Terminal Bridge v$PLUGIN_VERSION --------------------------------+" -ForegroundColor Cyan
Write-Host "|  cwd:    $cwd" -ForegroundColor Cyan
Write-Host "|  session: $sessionId" -ForegroundColor Cyan
Write-Host "|  pipe:    $PipeName" -ForegroundColor Cyan
Write-Host '|  Keep this terminal open. Press Ctrl+C to stop.' -ForegroundColor Cyan
Write-Host '+----------------------------------------------------------------------+' -ForegroundColor Cyan
Write-Host ''

Register-Session -SessionId $sessionId -Cwd $cwd -PipeName $PipeName -BridgePid $PID -InitialAgyPid $AgyPid

# Unregister on exit
$null = Register-EngineEvent -SourceIdentifier ([System.Management.Automation.PsEngineEvent]::Exiting) -Action {
    Unregister-Session -SessionId $sessionId
    Write-Host "[agy bridge] Session $sessionId unregistered." -ForegroundColor DarkGray
}

# ── Connection loop ───────────────────────────────────────────────────────────

while ($true) {
    $pipe   = $null
    $reader = $null
    $writer = $null

    try {
        $pipe = New-AgyPipe -Name $PipeName
        Write-Host "[agy bridge] Waiting for connection on '$PipeName'..." -ForegroundColor DarkGray

        $pipe.WaitForConnection()
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        $reader = [System.IO.StreamReader]::new($pipe, $utf8, $false, 8192, $true)
        $writer = [System.IO.StreamWriter]::new($pipe, $utf8, 8192, $true)
        $writer.AutoFlush = $true
        Write-Host '[agy bridge] MCP connected.' -ForegroundColor Green

        while ($pipe.IsConnected) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { break }

            $request = $null
            try {
                $request = $line | ConvertFrom-Json -ErrorAction Stop
            } catch {
                Send-BridgeResponse -Writer $writer -Response ([ordered]@{
                    ok            = $false
                    status        = 'invalid_request'
                    exitCode      = 1
                    output        = ''
                    error         = $_.Exception.Message
                    sessionId     = $sessionId
                    pluginVersion = $PLUGIN_VERSION
                    cwd           = $cwd
                })
                continue
            }

            # -- Set agyPid request --------------------------------------------
            if ($request.type -eq 'set_agy_pid' -and $request.agyPid) {
                $currentAgyPid = [int]$request.agyPid
                Update-AgyPid -SessionId $sessionId -AgyPid $currentAgyPid
                Send-BridgeResponse -Writer $writer -Response ([ordered]@{
                    ok            = $true
                    status        = 'updated'
                    sessionId     = $sessionId
                    pluginVersion = $PLUGIN_VERSION
                    cwd           = $cwd
                    pipeName      = $PipeName
                    bridgePid     = $PID
                    agyPid        = $currentAgyPid
                })
                continue
            }

            # -- Health probe --------------------------------------------------
            if ($request.type -eq 'health') {
                $currentAgyPid = 0
                try {
                    $reg = [System.IO.File]::ReadAllText($SESSION_REGISTRY, [System.Text.Encoding]::UTF8) |
                           ConvertFrom-Json -ErrorAction Stop
                    if ($reg -isnot [array]) { $reg = @($reg) }
                    $entry = $reg | Where-Object { $_.sessionId -eq $sessionId } | Select-Object -First 1
                    if ($null -ne $entry -and $entry.agyPid -gt 0) {
                        $currentAgyPid = [int]$entry.agyPid
                    }
                } catch { }

                # Verify process is still alive; if dead, reset to 0
                if ($currentAgyPid -gt 0 -and -not (Get-Process -Id $currentAgyPid -ErrorAction SilentlyContinue)) {
                    $currentAgyPid = 0
                    Update-AgyPid -SessionId $sessionId -AgyPid 0
                }

                Send-BridgeResponse -Writer $writer -Response ([ordered]@{
                    ok            = $true
                    status        = 'healthy'
                    sessionId     = $sessionId
                    pluginVersion = $PLUGIN_VERSION
                    cwd           = $cwd
                    pipeName      = $PipeName
                    bridgePid     = $PID
                    agyPid        = $currentAgyPid
                })
                continue
            }

            # -- Run command ---------------------------------------------------
            if ($request.type -ne 'run' -or [string]::IsNullOrWhiteSpace([string]$request.command)) {
                Send-BridgeResponse -Writer $writer -Response ([ordered]@{
                    ok            = $false
                    status        = 'invalid_request'
                    exitCode      = 1
                    output        = ''
                    error         = 'Expected { type: "run", command: "..." } or { type: "health" }.'
                    sessionId     = $sessionId
                    pluginVersion = $PLUGIN_VERSION
                    cwd           = $cwd
                })
                continue
            }

            $command          = [string]$request.command
            $originalLocation = (Get-Location).Path
            $targetLocation   = if ([string]::IsNullOrWhiteSpace([string]$request.cwd)) {
                $originalLocation
            } else {
                [string]$request.cwd
            }

            $outputBuilder = [System.Text.StringBuilder]::new()
            $exitCode      = 0
            $ok            = $true
            $errorText     = ''

            Write-Host ''
            Write-Host "[Codex -> terminal] $command" -ForegroundColor Cyan
            Write-Host "[agy bridge] cwd: $targetLocation" -ForegroundColor DarkGray

            try {
                if (-not (Test-Path -LiteralPath $targetLocation -PathType Container)) {
                    throw "cwd is not an existing directory: $targetLocation"
                }
                Set-Location -LiteralPath $targetLocation
                $global:LASTEXITCODE = 0

                & { Invoke-Expression $command } 2>&1 | ForEach-Object {
                    $text = ($_ | Out-String -Width 4096).TrimEnd()
                    if (-not [string]::IsNullOrWhiteSpace($text)) {
                        Write-Host $text
                        [void]$outputBuilder.AppendLine($text)
                    }
                }

                if ($null -ne $global:LASTEXITCODE) { $exitCode = [int]$global:LASTEXITCODE }
                $ok = ($exitCode -eq 0)
            } catch {
                $ok        = $false
                $exitCode  = 1
                $errorText = $_.Exception.Message
                Write-Host "[agy bridge error] $errorText" -ForegroundColor Red
                [void]$outputBuilder.AppendLine($errorText)
            } finally {
                Set-Location -LiteralPath $originalLocation
            }

            Write-Host "[agy bridge] finished exitCode=$exitCode" -ForegroundColor DarkGray
            Send-BridgeResponse -Writer $writer -Response ([ordered]@{
                ok            = $ok
                status        = if ($ok) { 'completed' } else { 'failed' }
                exitCode      = $exitCode
                cwd           = $targetLocation
                output        = $outputBuilder.ToString()
                error         = $errorText
                sessionId     = $sessionId
                pluginVersion = $PLUGIN_VERSION
            })
        }
    } catch {
        Write-Host "[agy bridge connection error] $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        if ($null -ne $reader) { try { $reader.Dispose() } catch { } }
        if ($null -ne $writer) { try { $writer.Dispose() } catch { } }
        if ($null -ne $pipe)   { try { $pipe.Dispose()  } catch { } }
    }
}
