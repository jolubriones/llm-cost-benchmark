<#
.SYNOPSIS
    run_benchmark.ps1 - Preset-driven LLM cost benchmark runner.

.DESCRIPTION
    Loads a preset JSON (presets/*.json), runs each model through the same
    multi-turn task with a hard USD budget kill-switch per model, applies
    auto-checks to the final output, and appends every turn to
    data/preset_runs.csv. Budget exhaustion is a RESULT (outcome =
    budget_exhausted), not a crash.

    A "budget" preset value also caps spend: the run aborts the moment
    cumulative cost reaches budget_usd, recording outcome 'budget_exhausted'.

.EXAMPLE
    $env:OPENAI_API_KEY = 'sk-or-v1-...'
    .\run_benchmark.ps1 -Preset general                 # one preset
    .\run_benchmark.ps1 -Preset all                     # every preset
    .\run_benchmark.ps1 -Preset general -BudgetUsd 0.25 # override budget

    # Quick-test a NEW model without creating a preset:
    .\run_benchmark.ps1 -Preset general -Models 'vendor/new-model-id'
    .\run_benchmark.ps1 -Preset general -Models 'vendor/new-model','z-ai/glm-5.3-flash'
    # Custom one-off task instead of the preset's task:
    .\run_benchmark.ps1 -Preset general -Models 'vendor/new-model' -TaskText 'Write a haiku about APIs.'
    # Non-OpenRouter endpoint (any OpenAI-compatible API):
    .\run_benchmark.ps1 -Preset general -Models 'my-model' -ApiBase 'https://my.host/v1/chat/completions'
    # Record costs in a second currency (USD is always recorded):
    .\run_benchmark.ps1 -Preset general -CurrencyCode EUR -CurrencyRate 0.92
#>
param(
    [Parameter(Mandatory)]
    [string]$Preset,
    [double]$BudgetUsd = -1,
    [string[]]$Models,          # override preset model list (quick-test new models)
    [string]$TaskText,          # override preset task: turn 1 uses this text
    [string]$ApiBase = 'https://openrouter.ai/api/v1/chat/completions',
    [string]$CurrencyCode = '',   # optional display currency, e.g. 'PHP' (USD is always recorded)
    [double]$CurrencyRate = 0     # units of CurrencyCode per 1 USD, e.g. 62.9; required with -CurrencyCode
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$inv = [Globalization.CultureInfo]::InvariantCulture
$root = Split-Path $PSScriptRoot -Parent

try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

$apiKey = $env:OPENAI_API_KEY
if ([string]::IsNullOrWhiteSpace($apiKey)) {
    Write-Host 'SKIP: OPENAI_API_KEY not set.' -ForegroundColor Yellow
    exit 1
}

# ===========================================================================
# KEY SAFETY GATE - refuses to run if the key looks exposed.
# ===========================================================================
function Test-KeySafety {
    param([string]$Key, [string]$RepoRoot)

    # 1. The key itself must never exist in any repo file (someone pasted it
    #    into a preset, task, CSV, README...). Scan everything except .git.
    $hit = Get-ChildItem $RepoRoot -Recurse -File |
        Where-Object { $_.FullName -notmatch '\\\.git\\' -and $_.Length -lt 5MB } |
        Select-String -SimpleMatch $Key -List -ErrorAction SilentlyContinue
    if ($hit) {
        Write-Host ("REFUSING TO RUN: API key found in plain text inside '{0}'. Remove it (and purge git history if it was ever committed), then rotate the key at openrouter.ai/keys." -f $hit.Path) -ForegroundColor Red
        return $false
    }

    # 2. Any key-shaped string (sk-...) sitting in repo files means SOME key
    #    is exposed - even if it is an old/other key, refuse and say where.
    $shaped = Get-ChildItem $RepoRoot -Recurse -File -Include *.json,*.md,*.csv,*.ps1,*.txt,*.html |
        Where-Object { $_.FullName -notmatch '\\\.git\\' } |
        Select-String -Pattern 'sk-[A-Za-z0-9_-]{20,}' -List -ErrorAction SilentlyContinue
    if ($shaped) {
        Write-Host ("REFUSING TO RUN: a key-shaped string (sk-...) is stored in '{0}'. No key ever belongs inside repo files. Remove it and rotate that key." -f $shaped.Path) -ForegroundColor Red
        return $false
    }

    # 3. Key must not be longer than env allows, i.e. it must come from the
    #    environment only - never from a parameter or file (enforced above
    #    by design; this documents the invariant).
    if ($Key -match '[\s'']') {
        Write-Host 'REFUSING TO RUN: OPENAI_API_KEY contains whitespace/quote characters - that is not a valid key format.' -ForegroundColor Red
        return $false
    }

    return $true
}

# Scrubs the key from anything we ever print (error messages etc.).
function Remove-Key {
    param([string]$Text, [string]$Key)
    if ([string]::IsNullOrEmpty($Text) -or [string]::IsNullOrEmpty($Key)) { return $Text }
    return $Text.Replace($Key, 'sk-***REDACTED***')
}

if (-not (Test-KeySafety -Key $apiKey -RepoRoot $root)) { exit 2 }

# 4. Optional live check: confirm the key is valid + see its remaining
#    credit BEFORE burning anything on runs.
try {
    $keyInfo = Invoke-RestMethod -Method Get `
        -Uri ($ApiBase -replace '/chat/completions', '/auth/key') `
        -Headers @{ Authorization = "Bearer $apiKey" } -TimeoutSec 20
    $remaining = $keyInfo.data.limit - $keyInfo.data.usage
    if ($null -ne $remaining) {
        Write-Host ("Key OK. Remaining credit on this key: `${0:N2}" -f $remaining) -ForegroundColor DarkGray
        if ($remaining -lt $budget) {
            Write-Host ("WARNING: remaining credit (${0:N2}) is below the preset budget (${1:N2}). Runs may abort mid-task." -f $remaining, $budget) -ForegroundColor Yellow
        }
    } else {
        Write-Host 'Key OK (unlimited/open key - consider setting a spend limit).' -ForegroundColor DarkGray
    }
} catch {
    Write-Host (Remove-Key -Text ("Key pre-check failed: {0}" -f $_.Exception.Message) -Key $apiKey) -ForegroundColor Yellow
    Write-Host 'Continuing anyway - the run itself will fail fast if the key is bad.' -ForegroundColor DarkGray
}
# --- end key safety gate --------------------------------------------------

# --- load preset(s) -------------------------------------------------------
$presetsDir = Join-Path $root 'presets'
if ($Preset -eq 'all') {
    $files = Get-ChildItem $presetsDir -Filter *.json
} else {
    $p = Join-Path $presetsDir "$Preset.json"
    if (-not (Test-Path $p)) { Write-Host "Preset '$Preset' not found in $presetsDir" -ForegroundColor Red; exit 1 }
    $files = Get-Item $p
}

$csvPath = Join-Path $root 'data\preset_runs.csv'
$useCur = $CurrencyCode -and $CurrencyRate -gt 0
if ($useCur) {
    $curCode = $CurrencyCode.ToUpperInvariant()
    $curCol = 'cum_cost_' + $curCode.ToLowerInvariant()
} else {
    $curCode = ''; $curCol = $null
}
if (-not (Test-Path $csvPath)) {
    $header = "timestamp,preset,model,turn,prompt_tokens,completion_tokens,cum_cost_usd,budget_usd,outcome,checks_passed"
    if ($curCol) {
        $header = $header -replace 'cum_cost_usd,', "cum_cost_usd,$curCol,"
    }
    $header | Set-Content -Path $csvPath -Encoding UTF8
}

$bar = '=' * 70

foreach ($file in $files) {
    $preset = Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $name   = $preset.name
    $budget = if ($BudgetUsd -ge 0) { $BudgetUsd } else { [double]$preset.budget_usd }
    $turns  = [int]$preset.turns
    $task   = if ($TaskText) { $TaskText } else { Get-Content (Join-Path $root $preset.task_file) -Raw -Encoding UTF8 }

    # Ad-hoc model override: quick-test new models against the preset's task.
    if ($Models -and $Models.Count -gt 0) {
        $preset.models = $Models
        $name = "$name+custom"
    }

    Write-Host ''
    Write-Host $bar -ForegroundColor Cyan
    Write-Host ("  PRESET '{0}' | {1} turns | budget `${2:N2}/model" -f $name, $turns, $budget) -ForegroundColor Cyan
    Write-Host ("  {0}" -f $preset.description) -ForegroundColor DarkGray
    Write-Host $bar -ForegroundColor Cyan

    foreach ($m in $preset.models) {
        Write-Host ("`n-> {0}" -f $m) -ForegroundColor Cyan
        $history = @()
        $cumCost = 0.0; $checksPassed = 0; $outcome = 'completed'
        $sw = [Diagnostics.Stopwatch]::StartNew()

        for ($t = 1; $t -le $turns; $t++) {
            if ($t -eq 1) { $prompt = $task }
            elseif ($preset.followups) { $prompt = $preset.followups[$t - 2] }
            else { break }

            $history += @{ role = 'user'; content = $prompt }
            $body = @{
                model       = $m
                messages    = $history
                max_tokens  = [int]$preset.max_tokens
                temperature = [double]$preset.temperature
            }
            try {
                $resp = Invoke-RestMethod -Method Post -Uri $ApiBase `
                    -Headers @{ Authorization = "Bearer $apiKey" } `
                    -ContentType 'application/json; charset=utf-8' `
                    -Body ($body | ConvertTo-Json -Depth 6) -TimeoutSec 240

                $cost = if ($resp.usage.cost) { [double]$resp.usage.cost } else { 0.0 }
                $cumCost += $cost
                $history += @{ role = 'assistant'; content = $resp.choices[0].message.content }

                $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', $inv)
                $row = [ordered]@{
                    timestamp = $stamp; preset = $name; model = $m; turn = $t
                    prompt_tokens = [int]$resp.usage.prompt_tokens
                    completion_tokens = [int]$resp.usage.completion_tokens
                    cum_cost_usd = [math]::Round($cumCost, 6)
                }
                if ($curCol) { $row[$curCol] = [math]::Round($cumCost * $CurrencyRate, 4) }
                $row['budget_usd'] = $budget; $row['outcome'] = 'running'; $row['checks_passed'] = $checksPassed
                [pscustomobject]$row | Export-Csv -Path $csvPath -Append -NoTypeInformation -Encoding UTF8
                Write-Host ("   turn {0}: cum `${1:N5}" -f $t, $cumCost) -NoNewline

                # --- budget kill-switch ---------------------------------
                if ($cumCost -ge $budget -and $t -lt $turns) {
                    $outcome = 'budget_exhausted'
                    Write-Host ("  BUDGET HIT -> aborting model" ) -ForegroundColor Red
                    break
                }
                Write-Host ''
            }
            catch {
                $outcome = 'api_error'
                Write-Host ("   turn {0} FAILED - {1}" -f $t, (Remove-Key -Text $_.Exception.Message -Key $apiKey)) -ForegroundColor Red
                break
            }
        }

        # --- auto-checks on final assistant output -----------------------
        if ($outcome -eq 'running') { $outcome = 'completed' }
        if ($outcome -eq 'completed' -and $preset.auto_checks) {
            $final = $history[-1].content
            $checksPassed = 0
            foreach ($chk in $preset.auto_checks) {
                if ($final -match $chk.pattern) { $checksPassed++ }
            }
            # stamp last row with final outcome + checks: rewrite via temp re-export
            $all = Import-Csv $csvPath
            $last = $all | Where-Object { $_.preset -eq $name -and $_.model -eq $m } |
                Sort-Object { [datetime]$_.timestamp } | Select-Object -Last 1
            if ($last) {
                $last.outcome = $outcome; $last.checks_passed = $checksPassed
                $all | Export-Csv -Path "$csvPath.tmp" -NoTypeInformation -Encoding UTF8
                Move-Item -Force "$csvPath.tmp" $csvPath
            }
        }

        $sw.Stop()
        $short = ($m -replace '^.*[/]', '')
        $total = '${0:N5}' -f $cumCost
        if ($curCol) { $total += (' = {0:N4} {1}' -f ($cumCost * $CurrencyRate), $curCode) }
        Write-Host ("   TOTAL {0}: {1} | {2} | checks {3}/{4} | {5:N0}s" -f `
            $short, $total, $outcome, $checksPassed, ($preset.auto_checks | Measure-Object).Count, $sw.Elapsed.TotalSeconds) `
            -ForegroundColor Green
    }
}

Write-Host ''
Write-Host ('Results appended to ' + $csvPath) -ForegroundColor DarkGray
Write-Host 'The report page (index.html) renders the latest run per preset+model automatically.' -ForegroundColor DarkGray