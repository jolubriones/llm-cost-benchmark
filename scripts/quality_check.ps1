<#
.SYNOPSIS
    Functional quality grader for run transcripts produced by run_benchmark.ps1.

.DESCRIPTION
    Scans transcript files (data/outputs/*.md) for PowerShell code blocks,
    extracts the target function, then runs a fixed test battery against it
    in a fresh Windows PowerShell 5.1 child process (this also verifies the
    5.1-compatibility requirement from the task prompt).

    Battery is for the 'general' preset task: ConvertTo-TopScores
    (CSV file path, -Top default 3, score desc, ties alphabetical,
    throws on missing file).

.PARAMETER Transcript
    One or more transcript .md files to grade. Default: all files in data\outputs.

.EXAMPLE
    .\quality_check.ps1    # grade every transcript in data\outputs
#>
param(
    [string[]]$Transcript,
    [string]$FunctionName = 'ConvertTo-TopScores'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$outDir = Join-Path $root 'data\outputs'

if (-not $Transcript -or $Transcript.Count -eq 0) {
    $Transcript = @(Get-ChildItem $outDir -Filter *.md -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
}
if ($Transcript.Count -eq 0) { Write-Host 'No transcripts found in data\outputs.' -ForegroundColor Yellow; exit 1 }

# --- extraction -----------------------------------------------------------
function Get-CodeBlocks {
    param([string]$Text)
    $blocks = @()
    foreach ($mt in [regex]::Matches($Text, '(?s)```[a-zA-Z]*\r?\n(.*?)```')) { $blocks += $mt.Groups[1].Value }
    if ($blocks.Count -eq 0 -and $Text -match '(?ms)^function\s+') { $blocks += $Text }
    return $blocks
}

# --- test battery (executed inside a fresh PS 5.1 child process) ----------
$battery = @'
param([string]$CodePath)
$ErrorActionPreference = 'Continue'
try {
    . ([scriptblock]::Create((Get-Content $CodePath -Raw)))   # dot-source candidate code
} catch {
    "FAIL ps51_parse: $($_.Exception.Message)"
    exit
}

$results = @()
function T { param($name, [scriptblock]$test) try { & $test; $script:results += "PASS $name" } catch { $script:results += ("FAIL {0}: {1}" -f $name, $_.Exception.Message) } }

$csv = Join-Path $env:TEMP ("qtest_{0}.csv" -f [guid]::NewGuid().ToString('N'))
$csvData = "Name,Score", "alice,90", "bob,90", "carol,70", "dave,95"
$csvData | Set-Content -Path $csv -Encoding UTF8

T 'top3_desc_default' {
    $r = @(ConvertTo-TopScores -Path $csv)
    if ($r.Count -ne 3) { throw "expected 3 rows, got $($r.Count)" }
    if ($r[0].Name -ne 'dave') { throw "first should be dave, got $($r[0].Name)" }
    if ($r[0].Score -ne 95) { throw "first score should be 95, got $($r[0].Score)" }
}
T 'tie_breaks_alphabetical' {
    $names = @(ConvertTo-TopScores -Path $csv | ForEach-Object { $_.Name })
    $iA = [array]::IndexOf($names, 'alice'); $iB = [array]::IndexOf($names, 'bob')
    if ($iA -lt 0 -or $iB -lt 0) { throw "alice/bob missing: $($names -join ',')" }
    if ($iA -gt $iB) { throw "alice should precede bob, got $($names -join ',')" }
}
T 'top_parameter' {
    $names = @(ConvertTo-TopScores -Path $csv -Top 2 | ForEach-Object { $_.Name })
    if ($names.Count -ne 2 -or $names[0] -ne 'dave') { throw "got $($names -join ',')" }
}
T 'missing_file_throws' {
    $threw = $false
    try { ConvertTo-TopScores -Path 'Z:\definitely\missing.csv' 2>$null } catch { $threw = $true }
    if (-not $threw) { throw 'no error raised for missing file' }
}
T 'pipeline_input_ok' {
    $r = @(,([pscustomobject]@{ Name = 'eve'; Score = 99 }) | ConvertTo-TopScores -ErrorAction SilentlyContinue)
    if ($r.Count -ge 1 -and $r[0].Name -ne 'eve') { throw "pipeline gave $($r[0].Name)" }
}

Remove-Item $csv -ErrorAction SilentlyContinue
$results
'@

$batPath = Join-Path $env:TEMP ("qbat_{0}.ps1" -f [guid]::NewGuid().ToString('N'))
[IO.File]::WriteAllText($batPath, $battery, (New-Object Text.UTF8Encoding($false)))

# --- grade each transcript ------------------------------------------------
$summary = @()
try {
foreach ($tf in $Transcript) {
    $label = [IO.Path]::GetFileNameWithoutExtension($tf)
    $text = [IO.File]::ReadAllText($tf)
    # prefer the LAST fenced block containing the function (most evolved
    # version after follow-up turns); fall back to the shortest match.
    $blocks = @(Get-CodeBlocks -Text $text | Where-Object { $_ -match "function\s+$FunctionName" })
    if ($blocks.Count -eq 0) {
        Write-Host ("{0}: NO '{1}' definition found in transcript" -f $label, $FunctionName) -ForegroundColor Red
        $summary += [pscustomobject]@{ run = $label; passed = 0; total = 5; verdict = 'no_function' }
        continue
    }
    $code = $blocks[$blocks.Count - 1]
    $codePath = Join-Path $env:TEMP ("qcode_{0}.ps1" -f [guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($codePath, $code, (New-Object Text.UTF8Encoding($false)))
    # powershell.exe = Windows PowerShell 5.1: the task demands 5.1 compat
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $batPath $codePath 2>&1
    $lines = @($out | Where-Object { $_ -is [string] -and $_ -match '^(PASS|FAIL)' })
    $pass = @($lines | Where-Object { $_ -like 'PASS*' }).Count
    $total = $lines.Count
    $color = if ($total -gt 0 -and $pass -eq $total) { 'Green' } elseif ($pass -gt 0) { 'Yellow' } else { 'Red' }
    Write-Host ("{0}: {1}/{2} functional checks passed (PS 5.1)" -f $label, $pass, $total) -ForegroundColor $color
    $lines | ForEach-Object { Write-Host ("   $_") -ForegroundColor DarkGray }
    $summary += [pscustomobject]@{ run = $label; passed = $pass; total = $total; verdict = if ($total -eq 0) { 'no_output' } else { 'graded' } }
}
} finally {
    Remove-Item $batPath -ErrorAction SilentlyContinue
}
Write-Host ''
$summary | Format-Table -AutoSize | Out-String | Write-Host
