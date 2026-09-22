<#
.SYNOPSIS
    run_model_cost_test.ps1 - Run the same small test task against several OpenRouter
    models and report tokens + USD cost per model. Companion to check_spend.ps1.

.DESCRIPTION
    Self-contained. Sends one identical prompt to each model in $Models (max_tokens
    capped, no tools), then reads OpenRouter's /generation endpoint for authoritative
    usage + cost. Appends one row per model to results.csv and prints a table.

    Budget: worst case ~250 prompt tokens + 600 output tokens per model call.

.EXAMPLE
    $env:OPENAI_API_KEY = 'sk-or-v1-...'
    .\run_model_cost_test.ps1
#>

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$Models = @(
    'z-ai/glm-5.3-flash'
    'openai/gpt-5.6-luna'
    'deepseek/deepseek-v4-pro-0813'
    'anthropic/claude-sonnet-5'
    'anthropic/claude-opus-5'
)

$MaxTokens   = 1500
$Temperature = 0.2

# The shared test task (see MODEL_COST_TEST.md). Deliberately small + deterministic.
$Prompt = @"
Write a PowerShell 5.1-compatible function ConvertTo-TopScores that:
1. Takes a file path to a CSV with columns Name,Score and an optional -Top parameter (default 3).
2. Returns the top N rows by Score (descending), ties broken alphabetically by Name.
3. Throws a clear error if the file does not exist.
Return ONLY: the function code, then a one-sentence explanation.
"@

$Endpoint = 'https://openrouter.ai/api/v1/chat/completions'
$GenBase  = 'https://openrouter.ai/api/v1/generation?id='

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$inv = [Globalization.CultureInfo]::InvariantCulture

try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

$apiKey = $env:OPENAI_API_KEY
if ([string]::IsNullOrWhiteSpace($apiKey)) {
    Write-Host 'SKIP: OPENAI_API_KEY is not set (same OpenRouter key as check_cost.bat).' -ForegroundColor Yellow
    exit 1
}

$csvPath = Join-Path $PSScriptRoot 'results.csv'
if (-not (Test-Path $csvPath)) {
    "timestamp,model,prompt_tokens,completion_tokens,total_tokens,cost_usd,cost_php,max_tokens_cap" |
        Set-Content -Path $csvPath -Encoding UTF8
}

$RateUsdToPhp = 62.91
try {
    $fx = Invoke-RestMethod -Uri 'https://open.er-api.com/v6/latest/USD' -TimeoutSec 5
    if ($null -ne $fx.rates.PHP -and [double]$fx.rates.PHP -gt 0) { $RateUsdToPhp = [double]$fx.rates.PHP }
} catch { }

$bar = '=' * 70
Write-Host ''
Write-Host $bar -ForegroundColor Cyan
Write-Host '   Model Cost Test - same task, 3 models (results append to results.csv)' -ForegroundColor Cyan
Write-Host $bar -ForegroundColor Cyan

$rows = @()
foreach ($m in $Models) {
    Write-Host ("  -> {0} ... " -f $m) -NoNewline
    $body = @{
        model       = $m
        messages    = @(@{ role = 'user'; content = $Prompt })
        max_tokens  = $MaxTokens
        temperature = $Temperature
    }
    try {
        $resp = Invoke-RestMethod -Method Post -Uri $Endpoint `
            -Headers @{ Authorization = "Bearer $apiKey" } `
            -ContentType 'application/json; charset=utf-8' `
            -Body ($body | ConvertTo-Json -Depth 5) -TimeoutSec 120

        $genId = $resp.id
        Start-Sleep -Seconds 3   # generation stats become queryable shortly after completion

        $costUsd = $null
        $pt = $ct = $null
        try {
            $gen = Invoke-RestMethod -Method Get -Uri ($GenBase + $genId) `
                -Headers @{ Authorization = "Bearer $apiKey" } -TimeoutSec 30
            $genData = $gen.data
            if ($null -ne $genData) {
                $pt      = $genData.prompt_tokens
                $ct      = $genData.completion_tokens
                $costUsd = if ($null -ne $genData.usage) { [double]$genData.usage } else { $null }
            }
        } catch { }

        # Fallback to response usage if generation endpoint unavailable.
        if (-not $pt -and $resp.usage) {
            $pt = $resp.usage.prompt_tokens
            $ct = $resp.usage.completion_tokens
        }

        $ptNum = if ($pt) { [int]$pt } else { 0 }
        $ctNum = if ($ct) { [int]$ct } else { 0 }
        if ($null -eq $costUsd -and $resp.usage -and $resp.usage.cost) { $costUsd = [double]$resp.usage.cost }
        $costUsd2 = if ($null -ne $costUsd) { $costUsd } else { 0.0 }

        $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', $inv)
        $row = [pscustomobject]@{
            timestamp        = $stamp
            model            = $m
            prompt_tokens    = $ptNum
            completion_tokens= $ctNum
            total_tokens     = ($ptNum + $ctNum)
            cost_usd         = [math]::Round($costUsd2, 6)
            cost_php         = [math]::Round($costUsd2 * $RateUsdToPhp, 4)
            max_tokens_cap   = $MaxTokens
        }
        $rows += $row
        $row | Export-Csv -Path $csvPath -Append -NoTypeInformation -Encoding UTF8

        # Save the answer text for quality judgment.
        $slug = ($m -replace '[/]', '_')
        $resp.choices[0].message.content | Set-Content -Path (Join-Path $PSScriptRoot "answer_$slug.txt") -Encoding UTF8

        Write-Host ("done - {0} in / {1} out / `${2:N6}" -f $ptNum, $ctNum, $costUsd2) -ForegroundColor Green
    }
    catch {
        Write-Host ("FAILED - {0}" -f $_.Exception.Message) -ForegroundColor Red
        $rows += [pscustomobject]@{
            timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', $inv)
            model = $m; prompt_tokens = ''; completion_tokens = ''; total_tokens = ''
            cost_usd = ''; cost_php = ''; max_tokens_cap = $MaxTokens
        }
    }
}

# --- Summary table ----------------------------------------------------------
Write-Host ''
Write-Host ('{0,-32} {1,6} {2,6} {3,10} {4,10}' -f 'Model', 'In', 'Out', 'USD', 'PHP') -ForegroundColor White
foreach ($r in $rows) {
    $short = ($r.model -replace '^.*[/]', '')
    if ($r.cost_usd -ne '') {
        Write-Host ('{0,-32} {1,6} {2,6} {3,10:N6} {4,10:N4}' -f $short, $r.prompt_tokens, $r.completion_tokens, [double]$r.cost_usd, [double]$r.cost_php)
    } else {
        Write-Host ('{0,-32} {1,>6} {2,>6} {3,>10} {4,>10}' -f $short, '-', '-', 'FAILED', '-') -ForegroundColor Yellow
    }
}
Write-Host $bar -ForegroundColor Cyan
Write-Host ('Rate: 1 USD = {0} PHP  |  full log: {1}' -f $RateUsdToPhp.ToString('0.####', $inv), $csvPath) -ForegroundColor DarkGray
Write-Host 'Next: eyeball each returned snippet for correctness, then plan the Round-2 agentic test (MODEL_COST_TEST.md).' -ForegroundColor DarkGray