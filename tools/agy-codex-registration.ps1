# Register one user-level AGY plugin without modifying other plugin settings.
function Get-AgyConfigSections {
    param([string]$Content)
    $headers = [regex]::Matches($Content, '(?m)^[ \t]*\[(?<name>[^\r\n]+?)\][ \t]*(?:#[^\r\n]*)?\r?$')
    for ($i = 0; $i -lt $headers.Count; $i++) {
        $header = $headers[$i]
        $end = if ($i + 1 -lt $headers.Count) { $headers[$i + 1].Index } else { $Content.Length }
        [pscustomobject]@{
            Name = $header.Groups['name'].Value.Trim()
            Start = $header.Index
            BodyStart = $header.Index + $header.Length
            End = $end
            Body = $Content.Substring($header.Index + $header.Length, $end - $header.Index - $header.Length)
        }
    }
}

function Set-AgyConfigTable {
    param([string]$Content, [string]$Name, [System.Collections.IDictionary]$Values)
    $tables = @(Get-AgyConfigSections $Content | Where-Object { $_.Name -ceq $Name })
    if ($tables.Count -gt 1) { throw "Duplicate configuration table [$Name]; registration stopped." }
    $newline = if ($Content.Contains("`r`n")) { "`r`n" } else { "`n" }
    if ($tables.Count -eq 0) {
        $body = ($Values.GetEnumerator() | ForEach-Object { $_.Key + ' = ' + $_.Value }) -join $newline
        return $Content.TrimEnd("`r", "`n") + $newline + $newline + "[$Name]" + $newline + $body + $newline
    }
    $table = $tables[0]
    $body = $table.Body
    foreach ($entry in $Values.GetEnumerator()) {
        $key = [regex]::Escape([string]$entry.Key)
        $assignments = [regex]::Matches($body, "(?m)^[ \t]*$key[ \t]*=")
        if ($assignments.Count -gt 1) { throw "Duplicate $($entry.Key) in [$Name]; registration stopped." }
        if ($assignments.Count -eq 0) {
            $body = $body.TrimEnd("`r", "`n") + $newline + $entry.Key + ' = ' + $entry.Value + $newline
        } else {
            $pattern = '(?m)^([ \t]*' + $key + '[ \t]*=[ \t]*)(true|false|"(?:\\.|[^"\\])*"|''[^'']*'')([ \t]*(?:#[^\r\n]*)?)(\r?)$'
            if (-not [regex]::IsMatch($body, $pattern)) { throw "Unsupported $($entry.Key) in [$Name]; registration stopped." }
            $replacementValue = [string]$entry.Value
            $body = [regex]::Replace($body, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{
                param($match)
                $match.Groups[1].Value + $replacementValue + $match.Groups[3].Value + $match.Groups[4].Value
            })
        }
    }
    return $Content.Substring(0, $table.BodyStart) + $body + $Content.Substring($table.End)
}

function Get-AgyCodexRegistration {
    param([string]$ConfigPath, [string]$MarketplacePath)
    $content = if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) { [System.IO.File]::ReadAllText($ConfigPath) } else { '' }
    $sections = @(Get-AgyConfigSections $content)
    $plugin = @($sections | Where-Object { $_.Name -eq 'plugins."agy-terminal@agy-terminal-mcp"' })
    $marketplace = @($sections | Where-Object { $_.Name -eq 'marketplaces.agy-terminal-mcp' })
    $enabled = $plugin.Count -eq 1 -and $plugin[0].Body -match '(?m)^\s*enabled\s*=\s*true\s*(?:#.*)?$'
    $duplicates = @($sections | Where-Object {
        $_.Name -match '^plugins\.["'']agy-terminal@[^"'']+["'']$' -and
        $_.Name -ne 'plugins."agy-terminal@agy-terminal-mcp"' -and
        $_.Body -notmatch '(?m)^\s*enabled\s*=\s*false\s*(?:#.*)?$'
    })
    $source = $null
    if ($marketplace.Count -eq 1 -and $marketplace[0].Body -match '(?m)^\s*source\s*=\s*("(?:\\.|[^"\\])*"|''[^'']*'')\s*(?:#.*)?$') {
        $literal = $Matches[1]
        $source = if ($literal.StartsWith('"')) { $literal | ConvertFrom-Json } else { $literal.Substring(1, $literal.Length - 2) }
    }
    $local = $marketplace.Count -eq 1 -and $marketplace[0].Body -match '(?m)^\s*source_type\s*=\s*["'']local["'']\s*(?:#.*)?$'
    $matchesSource = $source -and ([System.IO.Path]::GetFullPath($source) -eq [System.IO.Path]::GetFullPath($MarketplacePath))
    [pscustomobject]@{ Ready = [bool]($enabled -and $local -and $matchesSource -and $duplicates.Count -eq 0); LegacyCount = $duplicates.Count }
}

function Register-AgyCodexPlugin {
    param([string]$ConfigPath, [string]$MarketplacePath)
    if (-not [System.IO.Path]::IsPathRooted($ConfigPath) -or [System.IO.Path]::GetFileName($ConfigPath) -ne 'config.toml') {
        throw 'Registration requires an absolute config.toml path.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $MarketplacePath '.agents\plugins\marketplace.json') -PathType Leaf)) {
        throw 'Standalone marketplace metadata is missing.'
    }
    $original = if (Test-Path -LiteralPath $ConfigPath) { [System.IO.File]::ReadAllText($ConfigPath) } else { '' }
    # Do not treat table-looking lines inside multiline strings as real tables.
    if ($original.Contains('"""') -or $original.Contains("'''")) { throw 'Multiline TOML strings require manual registration; no configuration was changed.' }
    $content = $original
    foreach ($section in @(Get-AgyConfigSections $original)) {
        if ($section.Name -match '^plugins\.["'']agy-terminal@[^"'']+["'']$' -and $section.Name -ne 'plugins."agy-terminal@agy-terminal-mcp"') {
            $content = Set-AgyConfigTable $content $section.Name ([ordered]@{ enabled = 'false' })
        }
    }
    $quotedSource = $MarketplacePath.Replace('\', '/') | ConvertTo-Json -Compress
    $content = Set-AgyConfigTable $content 'marketplaces.agy-terminal-mcp' ([ordered]@{ source_type = '"local"'; source = $quotedSource })
    $content = Set-AgyConfigTable $content 'plugins."agy-terminal@agy-terminal-mcp"' ([ordered]@{ enabled = 'true' })
    if ($content -ceq $original) { return $null }
    $backup = $null
    if (Test-Path -LiteralPath $ConfigPath) {
        if ([System.IO.File]::ReadAllText($ConfigPath) -cne $original) { throw 'Codex configuration changed during registration; retry without overwriting it.' }
        $backup = $ConfigPath + '.agy-backup.' + [guid]::NewGuid().ToString('N')
        Copy-Item -LiteralPath $ConfigPath -Destination $backup
    }
    [System.IO.File]::WriteAllText($ConfigPath, $content, (New-Object System.Text.UTF8Encoding($false)))
    return $backup
}
