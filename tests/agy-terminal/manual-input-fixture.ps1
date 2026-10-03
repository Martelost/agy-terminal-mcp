# Test-only fake console: exercise the production PowerShell flow without typing
# into the user's terminal. This file is not shipped inside the plugin.
param([string]$Scenario, [string]$InputScript, [string]$ResultFile, [string]$LogFile)
$ErrorActionPreference = 'Stop'
Microsoft.PowerShell.Utility\Add-Type -TypeDefinition @'
using System;
using System.IO;
public static class AgyVisibleInput {
    public static string Screen;
    public static string Log;
    public static void Send(uint pid, string text) { File.AppendAllText(Log, text); }
    public static string Capture(uint pid) { return Screen; }
}
'@
function Add-Type { param($TypeDefinition, $Language) }
function Get-Process { param($Id, $ErrorAction) [pscustomobject]@{ Name = 'agy'; Id = 42 } }
[AgyVisibleInput]::Log = $LogFile
$parameters = @{
    AgyPid = 42; Text = 'TASK'; CompletionMarker = 'TEST_END'
    WaitSeconds = 2; ResultFile = $ResultFile
}
switch ($Scenario) {
    'read' { [AgyVisibleInput]::Screen = ">`n? for shortcuts"; $parameters.ReadOnly = $true }
    'manual' { [AgyVisibleInput]::Screen = 'Press Enter to continue' }
    'observe' { [AgyVisibleInput]::Screen = "TEST_END`nTEST_END"; $parameters.ObserveOnly = $true }
    'auth' { [AgyVisibleInput]::Screen = 'Login with Google; verification code: PRIVATE_TEST_CODE' }
    'scope' {
        [AgyVisibleInput]::Screen = 'Allow file edit to "C:\outside\app.js"? [y/n]'
        $parameters.AutoApprove = $true
        $parameters.Cwd = Split-Path -Parent $ResultFile
        $parameters.EditableFilesJson = ConvertTo-Json -InputObject @((Join-Path $parameters.Cwd 'app.js')) -Compress
    }
    'survey' { [AgyVisibleInput]::Screen = "How's the CLI experience`n[0] Skip" }
    default { throw 'Unknown test scenario.' }
}
& $InputScript @parameters
