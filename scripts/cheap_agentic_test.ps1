<#
.SYNOPSIS
    cheap_agentic_test.ps1 - Round 1.5: simulated agentic burn test.

.DESCRIPTION
    For each model, runs ONE growing 6-turn conversation (real context
    accumulation, the token-burn mechanism agents suffer). Records
    cumulative tokens + USD cost per turn. Appends to agentic_results.csv.

    Budget worst case: ~1.5K in / 800 out per turn, 6 turns.

.EXAMPLE
    $env:OPENAI_API_KEY = 'sk-or-v1-...'
    .\cheap_agentic_test.ps1
#>

# Open-weight models only.
$Models = @(
    'z-ai/glm-5.3-flash'
    'deepseek/deepseek-v4-pro-0813'
    'moonshotai/kimi-k2'
    'qwen/qwen3-235b-a22b'
)

$MaxTokens   = 800
$Temperature = 0.2
$Turns = 6

# Turn prompts: turn 1 = task, rest = realistic agent follow-ups on same thread.
$TurnPrompts = @(
    'Write a PowerShell 5.1-compatible function ConvertTo-TopScores that: 1. Takes a file path to a CSV with columns Name,Score and an optional -Top parameter (default 3). 2. Returns the top N rows by Score (descending), ties broken alphabetically by Name. 3. Throws a clear error if the file does not exist. Return ONLY the function code.',
    'Modify it to also accept pipeline input of objects with Name and Score properties instead of a file path.',
    'Now add a -Descending switch that flips the sort order. Keep everything else.',
    'Add basic error handling: rows with non-numeric Score should be skipped with a Write-Warning.',
    'Write a short comment-based help block for the function.',
    'Finally, list the 3 most likely ways this function could fail in production, one line each.'
)

$Endpoint = 'https://openrouter.ai/api/v1/chat/completions'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$inv = [Globalization.CultureInfo]::InvariantCulture

try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

$apiKey = $env:OPENAI_API_KEY
if ([string]::IsNullOrWhiteSpace($apiKey)) {
    Write-Host 'SKIP: OPENAI_API_KEY not set.' -ForegroundColor Yellow
    exit 1
}

$csvPath = Join-Path $PSScriptRoot 'agentic_results_open.csv'
if (-not (Test-Path $csvPath)) {
    "timestamp,model,turn,prompt_tokens,completion_tokens,cum_prompt_tokens,cum_cost_usd,cum_cost_php" |
        Set-Content -Path $csvPath -Encoding UTF8
}

$RateUsdToPhp = 62.91

$bar = '=' * 70
Write-Host ''
Write-Host $bar -ForegroundColor Cyan
Write-Host '   Cheap Agentic Test - 6-turn growing conversation per model' -ForegroundColor Cyan
Write-Host $bar -ForegroundColor Cyan

foreach ($m in $Models) {
    Write-Host ("`n-> {0}" -f $m) -ForegroundColor Cyan
    $short = ($m -replace '^.*[/]', '')
    $history = @()
    $cumIn = 0; $cumOut = 0; $cumCost = 0.0

    for ($t = 1; $t -le $Turns; $t++) {
        $history += @{ role = 'user'; content = $TurnPrompts[$t - 1] }
        $body = @{
            model       = $m
            messages    = $history
            max_tokens  = $MaxTokens
            temperature = $Temperature
        }
        try {
            $resp = Invoke-RestMethod -Method Post -Uri $Endpoint `
                -Headers @{ Authorization = "Bearer $apiKey" } `
                -ContentType 'application/json; charset=utf-8' `
                -Body ($body | ConvertTo-Json -Depth 6) -TimeoutSec 180

            $pt = [int]$resp.usage.prompt_tokens
            $ct = [int]$resp.usage.completion_tokens
            $cost = 0.0
            if ($resp.usage.cost) { $cost = [double]$resp.usage.cost }

            $cumIn += $pt; $cumOut += $ct; $cumCost += $cost
            $history += @{ role = 'assistant'; content = $resp.choices[0].message.content }

            $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', $inv)
            [pscustomobject]@{
                timestamp = $stamp; model = $m; turn = $t
                prompt_tokens = $pt; completion_tokens = $ct
                cum_prompt_tokens = $cumIn
                cum_cost_usd = [math]::Round($cumCost, 6)
                cum_cost_php = [math]::Round($cumCost * $RateUsdToPhp, 4)
            } | Export-Csv -Path $csvPath -Append -NoTypeInformation -Encoding UTF8

            Write-Host ("   turn {0}: {1} in / {2} out / cum `${3:N5}" -f $t, $pt, $ct, $cumCost)
        }
        catch {
            Write-Host ("   turn {0} FAILED - {1}" -f $t, $_.Exception.Message) -ForegroundColor Red
            break
        }
    }

    Write-Host ("   TOTAL {0}: {1} in / {2} out / `${3:N5} ({4:N4} PHP)" -f $short, $cumIn, $cumOut, $cumCost, ($cumCost * $RateUsdToPhp)) -ForegroundColor Green
}

Write-Host ''
Write-Host $bar -ForegroundColor Cyan
Write-Host ('Full log: ' + $csvPath) -ForegroundColor DarkGray
Write-Host 'Judge: compare final cum_cost across models AND the growth curve (does context burn compound?).' -ForegroundColor DarkGray
