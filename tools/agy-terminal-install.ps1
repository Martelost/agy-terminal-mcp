#Requires -Version 5.1
# agy-terminal-install.ps1 -- AGY Terminal plugin installer & doctor  (v0.4.1)
#
# Usage:
#   .\tools\agy-terminal-install.ps1          # Install plugin globally
#   .\tools\agy-terminal-install.ps1 -Check   # Doctor: verify installation & MCP version
#   .\tools\agy-terminal-install.ps1 -RepairLauncher # Install and back up an unsigned conflicting shim
#
[CmdletBinding()]
param(
    # When set, only check the installation state without changing anything.
    [switch]$Check,
    # Explicitly back up the unsigned .codex\bin\agy.exe that shadows agy.cmd.
    [switch]$RepairLauncher
)

$ErrorActionPreference = 'Stop'
if ($Check -and $RepairLauncher) {
    throw '-Check is read-only and cannot be combined with -RepairLauncher.'
}
. (Join-Path $PSScriptRoot 'agy-launcher-common.ps1')

$PLUGIN_VERSION   = '0.5.0'
$PLUGIN_NAME      = 'agy-terminal'
$PLUGIN_NAMESPACE = 'agy-terminal-mcp'
$SCRIPT_DIR       = Split-Path -Parent $MyInvocation.MyCommand.Path
$REPO_ROOT        = Split-Path -Parent $SCRIPT_DIR
$PLUGIN_SOURCE    = Join-Path $REPO_ROOT 'plugin'
$PLUGIN_CACHE_DIR = Join-Path $env:USERPROFILE ".codex\plugins\cache\$PLUGIN_NAMESPACE\$PLUGIN_NAME\$PLUGIN_VERSION"
$AGY_BIN_DIR      = Join-Path $env:USERPROFILE '.codex\bin'
$LAUNCHER_SOURCE  = Join-Path $SCRIPT_DIR 'agy-auto.ps1'
$LAUNCHER_TARGET  = Join-Path $AGY_BIN_DIR 'agy-auto.ps1'
$COMMON_SOURCE    = Join-Path $SCRIPT_DIR 'agy-launcher-common.ps1'
$COMMON_TARGET    = Join-Path $AGY_BIN_DIR 'agy-launcher-common.ps1'
$CMD_SOURCE       = Join-Path $SCRIPT_DIR 'agy-auto.cmd'
$CMD_TARGET       = Join-Path $AGY_BIN_DIR 'agy.cmd'
$SESSION_REGISTRY = Join-Path $env:TEMP 'codex-agy-sessions.json'
$INSPECT_CACHE_DIR = $PLUGIN_CACHE_DIR
$bridgeLauncher = Get-AgyBridgeLauncher
if ($Check -and $bridgeLauncher) {
    $INSPECT_CACHE_DIR = Split-Path -Parent (Split-Path -Parent $bridgeLauncher)
}

$ok = $true

function Write-OK   { param([string]$msg) Write-Host "  [OK]  $msg" -ForegroundColor Green }
function Write-WARN { param([string]$msg) Write-Host "  [!!]  $msg" -ForegroundColor Yellow; $script:ok = $false }
function Write-FAIL { param([string]$msg) Write-Host "  [XX]  $msg" -ForegroundColor Red;    $script:ok = $false }
function Write-INFO { param([string]$msg) Write-Host "  [--]  $msg" -ForegroundColor Cyan }

Write-Host ''
Write-Host "AGY Terminal Plugin  v$PLUGIN_VERSION  --  $(if ($Check) { 'Doctor' } else { 'Installer' })" -ForegroundColor Cyan
Write-Host '--------------------------------------------------------------------' -ForegroundColor DarkGray
Write-Host ''

# -- Check 1: Real CLI and Node.js --------------------------------------------

Write-Host '1. Real AGY executable and Node.js'
$agyPath = Get-AgyExecutable -WrapperDirectory $AGY_BIN_DIR
if ($agyPath) {
    Write-OK "Real AGY found at '$agyPath'"
    try {
        $signature = Get-AuthenticodeSignature -LiteralPath $agyPath
        Write-INFO "Authenticode signature: $($signature.Status)"
        if ($signature.SignerCertificate) {
            Write-INFO "Signer: $($signature.SignerCertificate.Subject)"
        }
    } catch {
        Write-INFO "Signature could not be read: $($_.Exception.Message)"
    }
} else {
    Write-FAIL 'Real AGY executable not found. Launcher scripts and .codex\bin shims do not count as the CLI.'
}
$nodeCommand = Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($nodeCommand) {
    try {
        $nodeVersion = & $nodeCommand.Source --version
        if ($LASTEXITCODE -ne 0 -or "$nodeVersion" -notmatch '^v(\d+)\.') {
            throw 'Could not read the Node.js version.'
        }
        if ([int]$Matches[1] -lt 18) {
            Write-FAIL "Node.js $nodeVersion is too old; version 18 or newer is required."
        } else {
            Write-OK "Node.js $nodeVersion at '$($nodeCommand.Source)'"
        }
    } catch { Write-FAIL "Node.js check failed: $($_.Exception.Message)" }
} else {
    Write-FAIL 'Node.js not found on PATH; version 18 or newer is required.'
}

# -- Check 2: Skill roots ------------------------------------------------------

Write-Host ''
Write-Host '2. Skill roots'
$skillRoots = @(
    (Join-Path $env:USERPROFILE '.codex\skills'),
    (Join-Path $env:USERPROFILE '.codex\plugins\cache')
)
foreach ($root in $skillRoots) {
    if (Test-Path -LiteralPath $root -PathType Container) {
        Write-OK "'$root'"
    } elseif (-not $Check -and $root -eq (Join-Path $env:USERPROFILE '.codex\plugins\cache')) {
        Write-INFO "'$root' will be created during installation."
    } else {
        Write-WARN "'$root' does not exist -- some skills may not load."
    }
}

# -- Check 3: Plugin source (only relevant for install) ------------------------

Write-Host ''
Write-Host '3. Plugin source'
if (Test-Path -LiteralPath $PLUGIN_SOURCE -PathType Container) {
    Write-OK "'$PLUGIN_SOURCE'"
} else {
    Write-FAIL "Plugin source not found at '$PLUGIN_SOURCE'. Run from the repository root."
}

# -- Check 4: Installed plugin version ----------------------------------------

Write-Host ''
Write-Host '4. Installed plugin version'
$installedPluginJson = Join-Path $INSPECT_CACHE_DIR '.codex-plugin\plugin.json'
if (Test-Path -LiteralPath $installedPluginJson -PathType Leaf) {
    try {
        $installed = Get-Content -LiteralPath $installedPluginJson -Raw | ConvertFrom-Json
        if ($installed.version -eq $PLUGIN_VERSION) {
            Write-OK "v$($installed.version) at '$INSPECT_CACHE_DIR'"
        } else {
            if ($Check) {
                Write-WARN "Installed version v$($installed.version) does not match expected v$PLUGIN_VERSION"
            } else {
                Write-INFO "Installed version v$($installed.version) will be replaced with v$PLUGIN_VERSION."
            }
        }
    } catch {
        Write-WARN "Could not read installed plugin.json: $($_.Exception.Message)"
    }
} else {
    if ($Check) {
        Write-WARN "Plugin not installed at '$INSPECT_CACHE_DIR'. Run without -Check to install."
    } else {
        Write-INFO 'Not yet installed -- will install now.'
    }
}

# -- Check 5: MCP server.mjs version in cache ---------------------------------

Write-Host ''
Write-Host '5. MCP server.mjs version'
$serverMjs = Join-Path $INSPECT_CACHE_DIR 'mcp\server.mjs'
if (Test-Path -LiteralPath $serverMjs -PathType Leaf) {
    $versionLine = (Get-Content -LiteralPath $serverMjs | Select-String "SERVER_VERSION\s*=\s*'([^']+)'") | Select-Object -First 1
    if ($versionLine) {
        $runningVersion = ($versionLine.Matches[0].Groups[1].Value)
        if ($runningVersion -eq $PLUGIN_VERSION) {
            Write-OK "server.mjs reports v$runningVersion"
        } else {
            if ($Check) {
                Write-WARN "server.mjs v$runningVersion ≠ expected v$PLUGIN_VERSION. Reinstall and restart Claude/Codex."
            } else {
                Write-INFO "server.mjs v$runningVersion will be replaced with v$PLUGIN_VERSION."
            }
        }
    } else {
        Write-WARN 'Could not extract version from server.mjs.'
    }
} else {
    if ($Check) {
        Write-WARN 'server.mjs not found in cache. Run without -Check to install.'
    } else {
        Write-INFO 'server.mjs not yet installed.'
    }
}

# -- Check 6: Launcher in codex bin --------------------------------------------

Write-Host ''
Write-Host '6. agy launcher files and command resolution'
foreach ($launcherFile in @(
    @{ Source = $LAUNCHER_SOURCE; Target = $LAUNCHER_TARGET },
    @{ Source = $COMMON_SOURCE; Target = $COMMON_TARGET },
    @{ Source = $CMD_SOURCE; Target = $CMD_TARGET }
)) {
    $source = $launcherFile.Source
    $target = $launcherFile.Target
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        Write-FAIL "Launcher source not found at '$source'."
    } elseif (Test-Path -LiteralPath $target -PathType Leaf) {
        $srcHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        $dstHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        if ($srcHash -eq $dstHash) {
            Write-OK "'$target' is synchronized with repository source."
        } elseif ($Check) {
            Write-WARN "'$target' differs from '$source'. Run without -Check to update."
        } else {
            Write-INFO "'$target' will be updated."
        }
    } elseif ($Check) {
        Write-WARN "Launcher file not found at '$target'. Run without -Check to install."
    } else {
        Write-INFO "'$target' will be installed."
    }
}
$shimPath = Join-Path $AGY_BIN_DIR 'agy.exe'
if (Test-Path -LiteralPath $shimPath -PathType Leaf) {
    if ($RepairLauncher) {
        Write-INFO "The conflicting '$shimPath' will be checked and backed up."
    } else {
        Write-WARN "'$shimPath' shadows agy.cmd and may be blocked by Device Guard."
        Write-INFO 'Use -RepairLauncher to back up an unsigned shim, or explicitly run the full path to agy.cmd.'
    }
}
$agyCommands = @(Get-Command agy -All -ErrorAction SilentlyContinue)
foreach ($command in $agyCommands) {
    Write-INFO "agy resolves to: $($command.CommandType) $($command.Definition)"
}
$pathDirectories = @($env:PATH -split ';' | ForEach-Object {
    [Environment]::ExpandEnvironmentVariables($_.Trim().Trim('"')).TrimEnd('\', '/')
})
if ($AGY_BIN_DIR.TrimEnd('\', '/') -notin $pathDirectories) {
    Write-WARN "'$AGY_BIN_DIR' is missing from PATH. Add it before the real AGY directory and open a new terminal."
} elseif ($agyCommands.Count -gt 0 -and
          $agyCommands[0].Source -ne $CMD_TARGET -and
          -not ($RepairLauncher -and $agyCommands[0].Source -eq $shimPath) -and
          ($Check -or (Test-Path -LiteralPath $CMD_TARGET -PathType Leaf))) {
    Write-WARN 'Another command takes precedence over the bridge wrapper. Use the full path to .codex\bin\agy.cmd or correct PATH/profile precedence.'
}
if ($bridgeLauncher) {
    Write-INFO "Discovered bridge: '$bridgeLauncher'"
} elseif ($Check) {
    Write-WARN 'No complete bridge installation was found in either supported plugin cache.'
}

# -- Check 7: Active sessions --------------------------------------------------

Write-Host ''
Write-Host '7. Active AGY sessions'
if (Test-Path -LiteralPath $SESSION_REGISTRY -PathType Leaf) {
    try {
        $sessions = Get-Content -LiteralPath $SESSION_REGISTRY -Raw | ConvertFrom-Json
        if ($null -eq $sessions) { $sessions = @() }
        if ($sessions -isnot [array]) { $sessions = @($sessions) }
        $liveSessions = @($sessions | Where-Object {
            $bPid = if ($_.bridgePid) { [int]$_.bridgePid } else { [int]$_.pid }
            try { Get-Process -Id $bPid -ErrorAction Stop | Out-Null; $true } catch { $false }
        })
        if ($liveSessions.Count -gt 0) {
            foreach ($s in $liveSessions) {
                $aPid = if ($s.agyPid) { [int]$s.agyPid } else { 0 }
                $agyAlive = if ($aPid -gt 0) { try { Get-Process -Id $aPid -ErrorAction Stop | Out-Null; $true } catch { $false } } else { $false }
                $stateLabel = if ($agyAlive) { "READY (agyPid: $aPid)" } else { "BRIDGE ONLY (agyPid: 0)" }
                $sessionMessage = "session $($s.sessionId) | cwd: $($s.cwd) | pipe: $($s.pipeName) | bridgePid: $($s.bridgePid) | $stateLabel | v$($s.pluginVersion)"
                if ($agyAlive) { Write-OK $sessionMessage } else { Write-INFO "$sessionMessage | Open agy in this project terminal." }
            }
        } else {
            Write-INFO 'No live AGY sessions. Run "agy" in a project terminal to create one.'
        }
    } catch {
        Write-WARN "Could not read session registry: $($_.Exception.Message)"
    }
} else {
    Write-INFO 'No session registry -- no AGY terminals have been opened yet.'
}

# -- Install -------------------------------------------------------------------

if (-not $Check) {
    Write-Host ''
    Write-Host '--- Installing ------------------------------------------------------' -ForegroundColor DarkGray

    if (-not (Test-Path -LiteralPath $PLUGIN_SOURCE -PathType Container)) {
        Write-FAIL 'Cannot install: plugin source directory not found.'
        exit 1
    }

    # Create destination
    foreach ($source in @($LAUNCHER_SOURCE, $COMMON_SOURCE, $CMD_SOURCE)) {
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            Write-FAIL "Cannot install: launcher source not found at '$source'."
            exit 1
        }
    }
    if ($RepairLauncher) {
        if (-not $agyPath) {
            Write-FAIL 'Cannot repair the launcher without a separate real AGY installation. Install AGY first.'
            exit 1
        }
        try {
            $backupPath = Backup-AgyLauncherShim
            if ($backupPath) {
                Write-OK "Unsigned shim backed up at '$backupPath'. Rename it to agy.exe to restore."
            } else {
                Write-INFO 'No conflicting agy.exe shim needs repair.'
            }
        } catch {
            Write-FAIL $_.Exception.Message
            exit 1
        }
    }
    if (-not (Test-Path -LiteralPath $PLUGIN_CACHE_DIR -PathType Container)) {
        New-Item -ItemType Directory -Path $PLUGIN_CACHE_DIR -Force | Out-Null
        Write-INFO "Created '$PLUGIN_CACHE_DIR'"
    }

    # Copy files (overwrite)
    $items = Get-ChildItem -LiteralPath $PLUGIN_SOURCE -Recurse -Force
    foreach ($item in $items) {
        $relative  = $item.FullName.Substring($PLUGIN_SOURCE.Length).TrimStart('\','/')
        $dest      = Join-Path $PLUGIN_CACHE_DIR $relative
        if ($item.PSIsContainer) {
            if (-not (Test-Path -LiteralPath $dest -PathType Container)) {
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
            }
        } else {
            $destDir = Split-Path -Parent $dest
            if (-not (Test-Path -LiteralPath $destDir -PathType Container)) {
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            }
            Copy-Item -LiteralPath $item.FullName -Destination $dest -Force
        }
    }
    Write-OK "Plugin v$PLUGIN_VERSION installed to '$PLUGIN_CACHE_DIR'"

    if (Test-Path -LiteralPath $LAUNCHER_SOURCE -PathType Leaf) {
        if (-not (Test-Path -LiteralPath $AGY_BIN_DIR -PathType Container)) {
            New-Item -ItemType Directory -Path $AGY_BIN_DIR -Force | Out-Null
        }
        Copy-Item -LiteralPath $LAUNCHER_SOURCE -Destination $LAUNCHER_TARGET -Force
        Copy-Item -LiteralPath $COMMON_SOURCE -Destination $COMMON_TARGET -Force
        Write-OK "agy launcher updated at '$LAUNCHER_TARGET'"

        # Also copy agy-auto.cmd to agy.cmd if present in script dir
        if (Test-Path -LiteralPath $CMD_SOURCE -PathType Leaf) {
            Copy-Item -LiteralPath $CMD_SOURCE -Destination $CMD_TARGET -Force
            Write-OK "agy command wrapper updated at '$CMD_TARGET'"
        }
    } else {
        Write-WARN "Launcher source not found at '$LAUNCHER_SOURCE'"
    }

    Write-Host ''
    Write-Host '--- Post-install steps ----------------------------------------------' -ForegroundColor DarkGray
    Write-Host '  1. Restart Claude / Codex to reload the MCP process.' -ForegroundColor Yellow
    Write-Host '  2. Ask Codex to open AGY for your project, or run agy yourself.' -ForegroundColor Yellow
    Write-Host '  3. In Claude/Codex, call: agy_status({ cwd: "<project path>" })' -ForegroundColor Yellow
    Write-Host "  4. Verify serverVersion reports $PLUGIN_VERSION and inputReady is true." -ForegroundColor Yellow
}

# -- Summary -------------------------------------------------------------------

Write-Host ''
if ($ok) {
    Write-Host '[OK] All checks passed.' -ForegroundColor Green
} else {
    Write-Host '[WARN] Some checks failed -- see warnings above.' -ForegroundColor Yellow
}
Write-Host ''

if (-not $ok) { exit 1 }
