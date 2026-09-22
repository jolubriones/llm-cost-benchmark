First public version of llm-cost-benchmark.

## What you get

- **Preset runner** (`scripts/run_benchmark.ps1`): send any OpenAI-compatible model through declarative benchmark presets (`presets/*.json`), track **actual billed API spend** turn by turn, with a hard **USD budget kill-switch** per model.
- **Budget exhaustion is a result, not an error**: a model that burns its budget mid-task is recorded as `outcome=budget_exhausted`.
- **Key safety gate**: the runner refuses to start if any API key (or `sk-`-shaped string) exists in repo files; keys are accepted from the environment only and scrubbed from error output.
- **Auto-checks**: cheap regex checks on final output, plus a manual 1-5 quality score column.
- **Currency**: costs recorded in USD by default; add any second display currency with `-CurrencyCode EUR -CurrencyRate 0.92`.
- **Interactive report** (`index.html`, live at https://jolubriones.github.io/llm-cost-benchmark/): renders the Sep 22 example run and auto-renders your own runs from `data/preset_runs.csv`.
- **Example run (Sep 22, 2026)**: six frontier models, identical 6-turn agent task, real billed spend: cheapest $0.0018 vs $0.14, a 77x gap.

## Requirements

- Windows PowerShell 5.1+ (Windows-first project)
- An `OPENAI_API_KEY` (OpenRouter-compatible endpoint by default; any OpenAI-compatible API via `-ApiBase`)

## Quickstart

```powershell
git clone https://github.com/jolubriones/llm-cost-benchmark.git
$env:OPENAI_API_KEY = 'sk-...'
.\scripts\run_benchmark.ps1 -Preset general
```

## Included presets

| Preset | What it tests | Budget/model | Turns |
|---|---|---|---|
| `general` | Quick value check, all popular models | $0.50 | 6 |
| `agentic-web-app` | Build + iteratively extend a web app | $1.00 | 8 |
| `agentic-data-analysis` | Clean + analyze a messy CSV over iterative turns | $0.75 | 6 |
| `tool-heavy` | Many small tool-shaped calls; exposes context re-read burn | $0.75 | 10 |
