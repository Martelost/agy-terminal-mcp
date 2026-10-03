#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('agy-manual-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
$passed = 0
try {
    foreach ($scenario in @('read','manual','observe','auth','scope','survey')) {
        $resultPath = Join-Path $fixtureRoot ($scenario + '.json')
        $logPath = Join-Path $fixtureRoot ($scenario + '.keys')
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'manual-input-fixture.ps1') -Scenario $scenario -InputScript (Join-Path $repoRoot 'plugin\mcp\agy-visible-input.ps1') -ResultFile $resultPath -LogFile $logPath
        if ($LASTEXITCODE -ne 0) { throw "Fixture failed: $scenario" }
        $result = Get-Content -Raw -LiteralPath $resultPath | ConvertFrom-Json
        $keys = if (Test-Path -LiteralPath $logPath) { [System.IO.File]::ReadAllText($logPath) } else { '' }
        switch ($scenario) {
            'read' { if ($result.status -ne 'observed' -or $keys -ne '') { throw 'Read-only capture typed a key.' } }
            'observe' { if ($result.status -ne 'completed' -or $keys -ne '') { throw 'Observation resent the task or pressed Enter.' } }
            'auth' {
                if ($result.status -ne 'auth_required' -or $keys -ne "TASK`r" -or $result.captured.Contains('PRIVATE_TEST_CODE')) { throw 'Authentication was not left to the user or a code was exposed.' }
            }
            default {
                if ($result.status -ne 'awaiting_user' -or $keys -ne "TASK`r" -or $result.autoApprovals -ne 0) { throw "Unexpected automatic input in $scenario." }
            }
        }
        Write-Host "[PASS] $scenario preserves human input ownership"
        $passed++
    }
} finally {
    $resolved = [System.IO.Path]::GetFullPath($fixtureRoot)
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [System.IO.Path]::GetFileName($resolved) -match '^agy-manual-tests-[0-9a-f]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    } else { throw 'Unexpected test fixture path; cleanup refused.' }
}
Write-Host "$passed passed, 0 failed"
