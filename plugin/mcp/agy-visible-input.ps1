#Requires -Version 5.1
# agy-visible-input.ps1 -- AGY Terminal MCP visible input v0.4.1
# Sends keystrokes into a specific agy.exe process identified by sessionId.
# The PID is read from the session registry (agyPid field) so we always target
# the exact process the user opened -- no guessing from process name.
param(
    # Session ID -- looked up in registry to find agyPid if AgyPid not given directly.
    [string] $SessionId = '',

    # Explicit agyPid -- if provided, directly targets this process without registry lookup.
    [int] $AgyPid = 0,

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string] $Text = '',

    # Path to file containing prompt text (immune to shell escaping)
    [string] $PromptFile = '',

    [switch] $NoEnter,

    # Marker written at the end of the prompt; when visible the script knows AGY finished.
    [string] $CompletionMarker,

    # Seconds to wait for the completion marker.
    [int] $WaitSeconds = 0,

    # If set, write JSON result here instead of stdout.
    [string] $ResultFile,

    # Enable auto-approve for scoped file-edit prompts only.
    [switch] $AutoApprove,

    # Working directory used for path validation.
    [string] $Cwd = '',

    # JSON array string of allowed file paths.
    [string] $EditableFilesJson = '[]'
)

$ErrorActionPreference = 'Stop'

$SESSION_REGISTRY = Join-Path $env:TEMP 'codex-agy-sessions.json'

# ── Resolve agyPid ───────────────────────────────────────────────────────────

function Get-RegistryEntry {
    param([string]$SessionId)
    if (-not (Test-Path -LiteralPath $SESSION_REGISTRY)) {
        throw "Session registry not found. Run 'agy' in the project terminal first."
    }
    try {
        $raw     = [System.IO.File]::ReadAllText($SESSION_REGISTRY, [System.Text.Encoding]::UTF8)
        $entries = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $entries) { $entries = @() }
        if ($entries -isnot [array]) { $entries = @($entries) }
        $entry = $entries | Where-Object { $_.sessionId -eq $SessionId } | Select-Object -First 1
        if ($null -eq $entry) {
            throw "Session '$SessionId' not found in registry. The bridge may have exited."
        }
        return $entry
    } catch {
        throw "Could not read session registry: $($_.Exception.Message)"
    }
}

if ($AgyPid -eq 0) {
    if ([string]::IsNullOrWhiteSpace($SessionId)) {
        throw "Either -SessionId or -AgyPid must be provided."
    }
    $entry  = Get-RegistryEntry -SessionId $SessionId
    $AgyPid = [int]$entry.agyPid
}

if ($AgyPid -eq 0) {
    throw "agyPid is 0 for session '$SessionId'. The agy.exe process has not been detected yet. " +
          "Wait a few seconds after starting 'agy' and retry."
}

# Verify the process is still alive
try {
    $proc = Get-Process -Id $AgyPid -ErrorAction Stop
    if ($proc.Name -notlike 'agy*') {
        throw "PID $AgyPid is not an agy process (found: $($proc.Name))."
    }
} catch [Microsoft.PowerShell.Commands.ProcessCommandException] {
    throw "agy.exe (PID $AgyPid) is no longer running. Re-open 'agy' in the project terminal."
}

$ProcessId = [uint32]$AgyPid

# ── Path validation helpers ───────────────────────────────────────────────────

function Resolve-EditableFiles {
    param([string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { return @() }
    try {
        $arr = $Json | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $arr) { return @() }
        return @($arr | ForEach-Object { [string]$_ })
    } catch { return @() }
}

$editableFiles       = Resolve-EditableFiles -Json $EditableFilesJson
$normalizedCwd       = if ([string]::IsNullOrWhiteSpace($Cwd)) { '' } else {
    try { [System.IO.Path]::GetFullPath($Cwd).ToLowerInvariant() } catch { '' }
}
$normalizedEditables = @($editableFiles | ForEach-Object {
    try { [System.IO.Path]::GetFullPath($_).ToLowerInvariant() } catch { $null }
} | Where-Object { $null -ne $_ })

function Get-NormalizedPath {
    param([string]$Raw, [string]$BaseCwd)
    $p = $Raw.Trim().Trim('"').Trim("'")
    if (-not [System.IO.Path]::IsPathRooted($p)) {
        if ([string]::IsNullOrWhiteSpace($BaseCwd)) { return $null }
        $p = Join-Path $BaseCwd $p
    }
    if ($p -match '(?:^|[\\/])\.\.(?:[\\/]|$)') { return $null }
    try { return [System.IO.Path]::GetFullPath($p).ToLowerInvariant() } catch { return $null }
}

function Test-PathInScope {
    param([string]$NPath, [string]$NCwd, [string[]]$NEditables)
    if ([string]::IsNullOrEmpty($NPath)) { return $false }
    $prefix = $NCwd.TrimEnd('\/')
    if (-not ($NPath.StartsWith($prefix + '\') -or $NPath.StartsWith($prefix + '/') -or $NPath -eq $prefix)) { return $false }
    if ($NEditables.Count -eq 0) { return $false }
    if ($NEditables -notcontains $NPath) { return $false }
    $filename = [System.IO.Path]::GetFileName($NPath)
    if ($filename -match '(^\.env|\.key$|secret|credential|password|token|auth)') { return $false }
    return $true
}

function Get-PathFromLine {
    param([string]$Line)
    if ($Line -match '"([^"]+)"') { return $Matches[1] }
    if ($Line -match "'([^']+)'") { return $Matches[1] }
    if ($Line -match '(?:^|[\s:])([A-Za-z]:[\\/][^\s"'']+|[/\\][^\s"'']+)') { return $Matches[1] }
    return ''
}

# ── C# Win32 keyboard injection + console capture ─────────────────────────────

$source = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class AgyVisibleInput
{
    private const uint GR = 0x80000000, GW = 0x40000000, FSR = 0x00000001, FSW = 0x00000002, OE = 3;
    private const ushort KE = 0x0001;
    private const int IHV = -1;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct KER { public int D; public ushort RC, VK, VS; public char UC; public uint CK; }
    [StructLayout(LayoutKind.Explicit, Size = 20)]
    struct IR { [FieldOffset(0)] public ushort ET; [FieldOffset(4)] public KER KE; }
    [StructLayout(LayoutKind.Sequential)] struct Coord { public short X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct SR { public short L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)]
    struct CSBI { public Coord Sz, CP; public ushort Attr; public SR Win; public Coord MWS; }

    [DllImport("kernel32.dll", SetLastError=true)] static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern IntPtr CreateFile(string n, uint acc, uint sh, IntPtr sec, uint cd, uint fl, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool WriteConsoleInputW(IntPtr h, IR[] r, uint n, out uint w);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetConsoleScreenBufferInfo(IntPtr h, out CSBI i);
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern uint ReadConsoleOutputCharacterW(IntPtr h, StringBuilder b, uint l, Coord c, out uint r);

    static IR Key(char c, bool dn) {
        ushort vk = c=='\r'?(ushort)0x0D:c=='\n'?(ushort)0x0D:c=='\b'?(ushort)0x08:c=='\t'?(ushort)0x09:c=='\x1B'?(ushort)0x1B:(ushort)0;
        return new IR { ET=KE, KE=new KER{ D=dn?1:0, RC=1, VK=vk, UC=c } };
    }

    public static void Send(uint pid, string text) {
        FreeConsole();
        if (!AttachConsole(pid)) throw new Win32Exception(Marshal.GetLastWin32Error(), "AttachConsole failed");
        IntPtr h = CreateFile("CONIN$", GR|GW, FSR|FSW, IntPtr.Zero, OE, 0, IntPtr.Zero);
        if (h.ToInt64()==IHV) throw new Win32Exception(Marshal.GetLastWin32Error(), "CONIN$ failed");
        try {
            var recs=new IR[text.Length*2]; int i=0;
            foreach(var c in text){recs[i++]=Key(c,true);recs[i++]=Key(c,false);}
            uint w; if(!WriteConsoleInputW(h,recs,(uint)recs.Length,out w)||w!=recs.Length)
                throw new Win32Exception(Marshal.GetLastWin32Error(),"WriteConsoleInput failed");
        } finally { CloseHandle(h); FreeConsole(); }
    }

    public static string Capture(uint pid) {
        FreeConsole();
        if (!AttachConsole(pid)) throw new Win32Exception(Marshal.GetLastWin32Error(), "AttachConsole failed (capture)");
        IntPtr h = CreateFile("CONOUT$", GR|GW, FSR|FSW, IntPtr.Zero, OE, 0, IntPtr.Zero);
        if (h.ToInt64()==IHV) throw new Win32Exception(Marshal.GetLastWin32Error(), "CONOUT$ failed");
        try {
            CSBI info; if(!GetConsoleScreenBufferInfo(h,out info))
                throw new Win32Exception(Marshal.GetLastWin32Error(),"GCBI failed");
            short l=info.Win.L, t=info.Win.T, w=(short)(info.Win.R-l+1), ht=(short)(info.Win.B-t+1);
            var sb=new StringBuilder();
            for(short row=0;row<ht;row++){
                var line=new StringBuilder(w); uint r;
                var co=new Coord{X=l,Y=(short)(t+row)};
                if(ReadConsoleOutputCharacterW(h,line,(uint)w,co,out r)==0)
                    throw new Win32Exception(Marshal.GetLastWin32Error(),"ROCW failed");
                sb.AppendLine(line.ToString().TrimEnd('\0',' '));
            }
            return sb.ToString();
        } finally { CloseHandle(h); FreeConsole(); }
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp

# ── Send the prompt ───────────────────────────────────────────────────────────

if ([string]::IsNullOrWhiteSpace($Text) -and -not [string]::IsNullOrWhiteSpace($PromptFile) -and (Test-Path -LiteralPath $PromptFile)) {
    try {
        $Text = [System.IO.File]::ReadAllText($PromptFile, [System.Text.Encoding]::UTF8)
    } catch {}
}

# Flatten internal newlines so each newline does not prematurely submit the prompt
$payload = ($Text -replace '\r?\n+', ' ').Trim()
if (-not $NoEnter) { $payload += "`r" }
[AgyVisibleInput]::Send($ProcessId, $payload)

# ── Result state ──────────────────────────────────────────────────────────────

$result = [ordered]@{
    status        = 'submitted_to_visible_terminal'
    sessionId     = $SessionId
    agyPid        = $agyPid
    captured      = ''
    autoApprovals = 0
    blocked       = 0
    error         = ''
}

function Get-TextOccurrenceCount {
    param([string]$Value, [string]$Needle)
    $count = 0; $offset = 0
    while ($true) {
        $idx = $Value.IndexOf($Needle, $offset, [System.StringComparison]::Ordinal)
        if ($idx -lt 0) { break }
        $count++; $offset = $idx + $Needle.Length
    }
    $count
}

# ── Auto-approve pattern constants ────────────────────────────────────────────

$APPROVE_PATTERNS = @(
    '(?i)allow\s+(?:file\s+)?(?:creat|edit|write|modif|sav|apply)',
    '(?i)(?:create|edit|write|modify|apply|save)\s+file',
    '(?i)apply\s+(?:this\s+)?change'
)
$BLOCK_PATTERNS = @(
    '(?i)run\s+this\s+command',
    '(?i)\bshell\b',
    '(?i)\bbash\b',
    '(?i)\bpowershell\b',
    '(?i)\bdelete\b',
    '(?i)authorization\s+code',
    '(?i)\boauth\b',
    '(?i)\blog\s*in\b',
    '(?i)\blogin\b',
    '(?i)network\s+access',
    '(?i)workspace\s+trust',
    '(?i)accounts\.google\.com',
    '(?i)verification\s+code',
    '(?i)paste.*code'
)
$SURVEY_PATTERN   = "(?is)How['']s the CLI experience.*\[0\]\s*Skip"
$NUMBERED_PROMPT  = '(?is)(?:allow|approve|confirm|apply|write|edit|modify|change|proceed).{0,250}\r?\n\s*>\s*1\.\s*(?:yes|allow|apply|proceed)'
$YN_PATTERNS      = @(
    '(?is)(?:proceed|continue|confirm|approve|allow|apply|write|edit|modify|change).{0,200}(?:\[\s*[yYnN]\s*/\s*[yYnN]\s*\]|\(\s*[yYnN]\s*/\s*[yYnN]\s*\)|\byes/no\b)',
    '(?im)^\s*\[[yYnN]\s*/\s*[yYnN]\]\s*$'
)

# ── Capture + approve loop ────────────────────────────────────────────────────

if (-not [string]::IsNullOrWhiteSpace($CompletionMarker)) {
    $deadline              = (Get-Date).AddSeconds([Math]::Max(1, $WaitSeconds))
    $captured              = ''
    $captureError          = ''
    $found                 = $false
    $idleSamples           = 0
    $lastApprovalSignature = ''
    $lastApprovalAt        = (Get-Date).AddSeconds(-5)

    while ((Get-Date) -lt $deadline) {
        try {
            $captured = [AgyVisibleInput]::Capture($ProcessId)

            if ($AutoApprove) {
                $tail = if ($captured.Length -gt 12000) { $captured.Substring($captured.Length - 12000) } else { $captured }
                $promptArea = if ($tail.Length -gt 1500) { $tail.Substring($tail.Length - 1500) } else { $tail }

                # Survey skip
                if ($promptArea -match $SURVEY_PATTERN) {
                    [AgyVisibleInput]::Send($ProcessId, "0`r")
                    Start-Sleep -Milliseconds 350
                    continue
                }

                $isNumbered = $promptArea -match $NUMBERED_PROMPT
                $isYN = $isNumbered -or ($promptArea -match $YN_PATTERNS[0]) -or ($promptArea -match $YN_PATTERNS[1])

                if ($isYN) {
                    # Hard block check on active prompt area
                    $hardBlocked = $false
                    foreach ($bp in $BLOCK_PATTERNS) {
                        if ($promptArea -match $bp) { $hardBlocked = $true; $result.blocked++; break }
                    }

                    if (-not $hardBlocked) {
                        $isFileEdit = $false
                        foreach ($ap in $APPROVE_PATTERNS) {
                            if ($promptArea -match $ap) { $isFileEdit = $true; break }
                        }

                        if ($isFileEdit) {
                            # Path validation: check if any allowed file is mentioned in prompt
                            $pathOk = $false
                            $tailLower = $promptArea.ToLowerInvariant()
                            foreach ($ne in $normalizedEditables) {
                                if ($tailLower.Contains($ne) -or $tailLower.Contains([System.IO.Path]::GetFileName($ne))) {
                                    $pathOk = $true
                                    break
                                }
                            }

                            if (-not $pathOk) {
                                $promptLines = ($promptArea -split '\r?\n') | Where-Object {
                                    $_ -match '(?i)allow|write|edit|modif|creat|apply|save|file'
                                }
                                if ($promptLines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($normalizedCwd)) {
                                    foreach ($pl in $promptLines) {
                                        $raw  = Get-PathFromLine -Line $pl
                                        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
                                        $norm = Get-NormalizedPath -Raw $raw -BaseCwd $Cwd
                                        if ($null -eq $norm) { continue }
                                        if (Test-PathInScope -NPath $norm -NCwd $normalizedCwd -NEditables $normalizedEditables) {
                                            $pathOk = $true; break
                                        }
                                    }
                                }
                            }

                            if ($pathOk) {
                                $signature = if ($promptArea.Length -gt 500) { $promptArea.Substring($promptArea.Length - 500) } else { $promptArea }
                                if ($signature -ne $lastApprovalSignature -and ((Get-Date) - $lastApprovalAt).TotalSeconds -ge 1) {
                                    $key = if ($isNumbered) { '' } else { 'y' }
                                    [AgyVisibleInput]::Send($ProcessId, "$key`r")
                                    $result.autoApprovals++
                                    $lastApprovalSignature = $signature
                                    $lastApprovalAt = Get-Date
                                    Start-Sleep -Milliseconds 350
                                }
                            } else {
                                $result.blocked++
                            }
                        }
                    }
                }
            }

            $markerCount   = Get-TextOccurrenceCount -Value $captured -Needle $CompletionMarker
            $hasPrompt     = ($captured -match '(?im)^\s*>\s*[^a-zA-Z0-9\r\n]*$')
            $hasShortcuts  = ($captured -match '(?im)\?\s+for shortcuts')
            # AGY's idle prompt is rendered differently across terminal versions.
            # Require two consecutive captures with the shortcut footer instead of
            # requiring one exact standalone `>` line.
            if ($hasShortcuts) { $idleSamples++ } else { $idleSamples = 0 }
            $readyForInput = $idleSamples -ge 2
            if (($markerCount -ge 2) -or (($markerCount -ge 1) -and $readyForInput) -or ($result.autoApprovals -gt 0 -and $readyForInput)) {
                $found = $true
                break
            }
        } catch {
            $captureError = $_.Exception.Message
        }
        Start-Sleep -Milliseconds 300
    }

    $result.captured = $captured
    $result.status   = if ($found) { 'completed' } else {
        $authBlocked = ($captured -match '(?i)accounts\.google\.com|authorization\s+code|\boauth\b|verification\s+code|\blog\s*in\b|\blogin\b')
        if ($authBlocked) {
            $result.error = "Interactive authentication required in the AGY terminal. Please complete login / OAuth in the terminal window."
            'auth_required'
        } elseif ($captureError) {
            $result.error = $captureError
            'capture_error'
        } else {
            $result.error = if ($result.blocked -gt 0) {
                "Prompt execution stopped because an unapproved operation (command/OAuth/delete/out-of-scope) was encountered."
            } else {
                "Completion marker not visible within $WaitSeconds s."
            }
            'capture_timeout'
        }
    }
}

# ── Output ────────────────────────────────────────────────────────────────────

$json = $result | ConvertTo-Json -Compress -Depth 5
if ($ResultFile) {
    Set-Content -LiteralPath $ResultFile -Value $json -Encoding UTF8
} else {
    Write-Output $json
}
