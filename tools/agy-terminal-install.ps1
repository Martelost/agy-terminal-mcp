#Requires -Version 5.1
# agy-terminal-install.ps1 -- AGY Terminal plugin installer & doctor  (v0.4.1)
#
# Usage:
#   .\tools\agy-terminal-install.ps1          # Install plugin globally
#   .\tools\agy-terminal-install.ps1 -Check   # Doctor: verify installation & MCP version
#
[CmdletBinding()]
param(
    # When set, only check the installation state without changing anything.
    [switch]$Check
)

$ErrorActionPreference = 'Stop'

$PLUGIN_VERSION   = '0.4.1'
$PLUGIN_NAME      = 'agy-terminal'
$PLUGIN_NAMESPACE = 'agy-terminal-mcp'
$SCRIPT_DIR       = Split-Path -Parent $MyInvocation.MyCommand.Path
$REPO_ROOT        = Split-Path -Parent $SCRIPT_DIR
$PLUGIN_SOURCE    = Join-Path $REPO_ROOT 'plugin'
$PLUGIN_CACHE_DIR = Join-Path $env:USERPROFILE ".codex\plugins\cache\$PLUGIN_NAMESPACE\$PLUGIN_NAME\$PLUGIN_VERSION"
$AGY_BIN_DIR      = Join-Path $env:USERPROFILE '.codex\bin'
$LAUNCHER_SOURCE  = Join-Path $SCRIPT_DIR 'agy-auto.ps1'
$LAUNCHER_TARGET  = Join-Path $AGY_BIN_DIR 'agy-auto.ps1'
$SESSION_REGISTRY = Join-Path $env:TEMP 'codex-agy-sessions.json'

$ok = $true

function Write-OK   { param([string]$msg) Write-Host "  [OK]  $msg" -ForegroundColor Green }
function Write-WARN { param([string]$msg) Write-Host "  [!!]  $msg" -ForegroundColor Yellow; $script:ok = $false }
function Write-FAIL { param([string]$msg) Write-Host "  [XX]  $msg" -ForegroundColor Red;    $script:ok = $false }
function Write-INFO { param([string]$msg) Write-Host "  [--]  $msg" -ForegroundColor Cyan }

Write-Host ''
Write-Host "AGY Terminal Plugin  v$PLUGIN_VERSION  --  $(if ($Check) { 'Doctor' } else { 'Installer' })" -ForegroundColor Cyan
Write-Host '--------------------------------------------------------------------' -ForegroundColor DarkGray
Write-Host ''

# -- Check 1: agy.exe ----------------------------------------------------------

Write-Host '1. agy.exe'
$agyCommand = Get-Command agy -ErrorAction SilentlyContinue
$agyPath = if ($agyCommand) { $agyCommand.Source } else { $null }
if (-not $agyPath) {
    $agyPath = Join-Path $env:LOCALAPPDATA 'agy\bin\agy.exe'
}
if (Test-Path -LiteralPath $agyPath -PathType Leaf) {
    Write-OK "Found at '$agyPath'"
} else {
    Write-FAIL "agy.exe not found at '$agyPath' or on PATH. Install AGY first."
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
$installedPluginJson = Join-Path $PLUGIN_CACHE_DIR '.codex-plugin\plugin.json'
if (Test-Path -LiteralPath $installedPluginJson -PathType Leaf) {
    try {
        $installed = Get-Content -LiteralPath $installedPluginJson -Raw | ConvertFrom-Json
        if ($installed.version -eq $PLUGIN_VERSION) {
            Write-OK "v$($installed.version) at '$PLUGIN_CACHE_DIR'"
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
        Write-WARN "Plugin not installed at '$PLUGIN_CACHE_DIR'. Run without -Check to install."
    } else {
        Write-INFO 'Not yet installed -- will install now.'
    }
}

# -- Check 5: MCP server.mjs version in cache ---------------------------------

Write-Host ''
Write-Host '5. MCP server.mjs version'
$serverMjs = Join-Path $PLUGIN_CACHE_DIR 'mcp\server.mjs'
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
Write-Host '6. agy launcher in bin directory'
if (Test-Path -LiteralPath $LAUNCHER_TARGET -PathType Leaf) {
    if (Test-Path -LiteralPath $LAUNCHER_SOURCE -PathType Leaf) {
        $srcHash = (Get-FileHash -LiteralPath $LAUNCHER_SOURCE -Algorithm SHA256).Hash
        $dstHash = (Get-FileHash -LiteralPath $LAUNCHER_TARGET -Algorithm SHA256).Hash
        if ($srcHash -eq $dstHash) {
            Write-OK "Launcher at '$LAUNCHER_TARGET' is synchronized with repository source."
        } else {
            if ($Check) {
                Write-WARN "Launcher at '$LAUNCHER_TARGET' differs from '$LAUNCHER_SOURCE'. Run without -Check to update."
            } else {
                Write-INFO "Launcher differs from repository source and will be updated."
            }
        }
    } else {
        Write-OK "Launcher found at '$LAUNCHER_TARGET'"
    }
} else {
    if ($Check) {
        Write-WARN "Launcher not found at '$LAUNCHER_TARGET'. Run without -Check to install."
    } else {
        Write-INFO 'Launcher not yet installed in bin directory.'
    }
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
            try { Get-Process -Id $bPid -ErrorAction Stop; $true } catch { $false }
        })
        if ($liveSessions.Count -gt 0) {
            foreach ($s in $liveSessions) {
                $aPid = if ($s.agyPid) { [int]$s.agyPid } else { 0 }
                $agyAlive = if ($aPid -gt 0) { try { Get-Process -Id $aPid -ErrorAction Stop; $true } catch { $false } } else { $false }
                $stateLabel = if ($agyAlive) { "READY (agyPid: $aPid)" } else { "BRIDGE ONLY (agyPid: 0)" }
                Write-OK "session $($s.sessionId) | cwd: $($s.cwd) | pipe: $($s.pipeName) | bridgePid: $($s.bridgePid) | $stateLabel | v$($s.pluginVersion)"
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
    if (-not (Test-Path -LiteralPath $PLUGIN_CACHE_DIR -PathType Container)) {
        New-Item -ItemType Directory -Path $PLUGIN_CACHE_DIR -Force | Out-Null
        Write-INFO "Created '$PLUGIN_CACHE_DIR'"
    }

    # Copy files (overwrite)
    $items = Get-ChildItem -LiteralPath $PLUGIN_SOURCE -Recurse
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
        Write-OK "agy launcher updated at '$LAUNCHER_TARGET'"

        # Also copy agy-auto.cmd to agy.cmd if present in script dir
        $cmdSource = Join-Path $SCRIPT_DIR 'agy-auto.cmd'
        $cmdTarget = Join-Path $AGY_BIN_DIR 'agy.cmd'
        if (Test-Path -LiteralPath $cmdSource -PathType Leaf) {
            Copy-Item -LiteralPath $cmdSource -Destination $cmdTarget -Force
            Write-OK "agy command wrapper updated at '$cmdTarget'"
        }
    } else {
        Write-WARN "Launcher source not found at '$LAUNCHER_SOURCE'"
    }

    Write-Host ''
    Write-Host '--- Post-install steps ----------------------------------------------' -ForegroundColor DarkGray
    Write-Host '  1. Restart Claude / Codex to reload the MCP process.' -ForegroundColor Yellow
    Write-Host '  2. Open a terminal in your project and run: agy' -ForegroundColor Yellow
    Write-Host '  3. In Claude/Codex, call: agy_status({ cwd: "<project path>" })' -ForegroundColor Yellow
    Write-Host '  4. Verify serverVersion reports 0.4.1 and agyReady is true.' -ForegroundColor Yellow
}

# -- Summary -------------------------------------------------------------------

Write-Host ''
if ($ok) {
    Write-Host '✓ All checks passed.' -ForegroundColor Green
} else {
    Write-Host '⚠ Some checks failed -- see warnings above.' -ForegroundColor Yellow
}
Write-Host ''

if (-not $ok) { exit 1 }
