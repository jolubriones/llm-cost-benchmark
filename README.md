# llm-cost-benchmark — run real-cost LLM benchmarks with a budget kill-switch

**What does it actually cost a model to do *your* job?** Don't guess from price sheets. This open-source benchmark runner sends any model (or set of models) through a real agentic task, tracks **actual billed API spend** turn by turn, and hard-stops every model at a USD budget you choose.

- ⚡ **Quickstart (3 lines):**

  ```powershell
  git clone https://github.com/jolubriones/llm-cost-benchmark.git
  $env:OPENAI_API_KEY = 'sk-...'        # OpenRouter-compatible by default
  .\scripts\run_benchmark.ps1 -Preset general
  ```

  That runs every bundled preset model through a 6-turn agent task and appends billed cost per turn to `data/preset_runs.csv`. Requires PowerShell 5+. [More presets and options](#using-presets).

- 📊 **See example output:** the [interactive report](https://jolubriones.github.io/llm-cost-benchmark/) from our Sep 22 run — the cheapest model finished the identical agent job for **$0.0018**, the most expensive for **$0.14**: a **77× cost gap** for equivalent output. [Results tables](#example-run-sep-22-2026)

- 🤖 **Agent-readable:** [llms.txt](llms.txt) for LLM crawlers, [AGENTS.md](AGENTS.md) for coding agents, raw CSVs in `data/`.

**Contents:** [Quickstart](#quickstart) · [Why per-task cost](#why-per-task-cost-not-per-token) · [Using presets](#using-presets) · [Key behaviors](#key-behaviors) · [Example run (Sep 22, 2026)](#example-run-sep-22-2026) · [The insight](#the-actual-insight-cheap-per-token--cheap-per-job) · [Methodology](#methodology) · [FAQ](#faq) · [Limitations](#limitations) · [Repo layout](#repo-layout) · [Contributing](#contributing)

## Why per-task cost, not per-token

Published token prices are a poor predictor of real task cost. The cheapest-looking model on a price sheet can be the most expensive one in production, because:

- **Verbosity compounds:** in agentic workloads each turn re-reads prior context, so a talkative model pays its verbosity tax *with interest* every turn.
- **Token price ≠ task price:** a low-rate model that generates thousands of tokens per turn can cost 15× more per task than a disciplined one at the same rate tier.

So this runner measures **cost-per-completed-task**: identical workload, per-turn cumulative cost extracted from the API billing response, hard kill-switch at your budget. "Model X burned its whole budget before finishing" is a data point here, not a footnote.

## Example run (Sep 22, 2026)

Our first run with this tool: six frontier models, identical workload (a single Q&A prompt and a full 6-turn agentic loop with plan → tool call → self-correct), per-turn cumulative cost tracked from the API responses. Live visual report: https://jolubriones.github.io/llm-cost-benchmark/

### 6-turn agent task — total billed cost

| Model | Total cost (USD) | × cheapest |
|---|---|---|
| GLM-5.3-flash | $0.0018 | 1× |
| GPT-5.6-luna | $0.0056 | 3.1× |
| DeepSeek V4 Pro | $0.0155 | 8.5× |
| Claude Sonnet 5 | $0.0449 | 24.6× |
| Claude Opus 5 | $0.1400 | **76.6×** |

### Same task, open-weight models only

| Model | Total cost (USD) | × cheapest |
|---|---|---|
| GLM-5.3-flash | $0.0019 | 1× |
| DeepSeek V4 Pro | $0.0073 | 3.9× |
| Kimi K2 | $0.0133 | 7.1× |
| Qwen3-235B | $0.0289 | **15.5×** |

## The actual insight: cheap-per-token ≠ cheap-per-job

The benchmark's most useful finding isn't "flash models are cheap" — everyone suspects that. It's that **published token prices are a poor predictor of real task cost**.

- **Qwen3-235B** bills near the bottom per token, yet finished 15.5× more expensive than GLM flash — because it generated thousands of tokens per turn (up to 4,340 in a single turn). Verbosity, not rate, drove the cost.
- **Claude Opus 5** is the opposite pattern: disciplined ~800-token turns, but a per-token rate so high it still landed 77× above flash.
- **Cost ramps compounding:** in agentic workloads each turn re-reads prior context, so a talkative model pays its verbosity tax *with interest* every turn. Qwen's cumulative curve steepens; flash's stays nearly flat.

Practical takeaway: when budgeting agent workloads, model **cost-per-completed-task**, not price-per-million-tokens. The cheapest-looking model on a price sheet can be the most expensive one in production.

## Methodology

1. **Test 1 — Q&A:** identical prompt sent to each model; billed prompt + completion tokens recorded from the API response.
2. **Test 2 — agentic loop (full field):** each model executes the same 6-turn agent task; cumulative real cost tracked per turn (`agentic_results.csv`).
3. **Test 3 — open weights only:** same loop restricted to GLM-5.3-flash, DeepSeek V4 Pro, Kimi K2, Qwen3-235B (`agentic_results_open.csv`).
4. Costs are actual billed spend in **USD**, extracted programmatically from API responses — see `scripts/run_benchmark.ps1` (`scripts/run_model_cost_test.ps1` and `scripts/cheap_agentic_test.ps1` are legacy scripts that produced the Sep 22 data; their CSVs also carry a `cum_cost_php` column).

## Repo layout

```
index.html                  ← interactive visual report (offline-capable, no dependencies)
README.md                   ← this write-up
presets/*.json              ← declarative benchmark presets (see below)
tasks/*.md                  ← turn-1 task prompt per preset
scripts/run_benchmark.ps1   ← preset runner: budget kill-switch, auto-checks, CSV output
scripts/                    ← legacy single-run scripts from the original Sep 22 test
data/*.csv                  ← raw results (per-turn history)
publish.ps1                 ← one-command GitHub Pages push
```

## Using presets

A preset is a declarative spec — task, turn count, models, and a hard **USD budget kill-switch** per model:

```json
{
  "name": "agentic-web-app",
  "task_file": "tasks/agentic-web-app.md",
  "turns": 8,
  "max_tokens": 1500,
  "budget_usd": 1.0,
  "models": ["z-ai/glm-5.3-flash", "anthropic/claude-opus-5"],
  "followups": ["Add validation…", "Add localStorage…"],
  "auto_checks": [{ "name": "html_or_js_present", "type": "regex", "pattern": "(<script|function)" }]
}
```

Bundled presets:

| Preset | What it tests | Budget/model | Turns |
|---|---|---|---|
| `general` | Quick value check — generic agent task, all popular models | $0.50 | 6 |
| `agentic-web-app` | Build + iteratively extend a web app | $1.00 | 8 |
| `agentic-data-analysis` | Clean + analyze a messy CSV over iterative turns | $0.75 | 6 |
| `tool-heavy` | Many small tool-shaped calls — exposes context re-read burn | $0.75 | 10 |

Run (PowerShell, needs `OPENAI_API_KEY`, OpenRouter-compatible by default):

```powershell
.\scripts\run_benchmark.ps1 -Preset general          # one preset
.\scripts\run_benchmark.ps1 -Preset all              # everything
.\scripts\run_benchmark.ps1 -Preset general -BudgetUsd 0.25   # tighter cap

# Quick-test a brand-new model (no preset file needed) against any preset's task:
.\scripts\run_benchmark.ps1 -Preset general -Models 'vendor/new-model-id'
# Compare it head-to-head with the current value king:
.\scripts\run_benchmark.ps1 -Preset general -Models 'vendor/new-model-id','z-ai/glm-5.3-flash'
# One-off custom task, or a non-OpenRouter OpenAI-compatible endpoint:
.\scripts\run_benchmark.ps1 -Preset general -Models 'my-model' -TaskText 'Your task here.'
.\scripts\run_benchmark.ps1 -Preset general -Models 'my-model' -ApiBase 'https://my.host/v1/chat/completions'
# Costs are recorded in USD by default; add a display currency if you like (e.g. EUR at 0.92 per USD):
.\scripts\run_benchmark.ps1 -Preset general -CurrencyCode EUR -CurrencyRate 0.92
```

Key behaviors:
- **Key safety gate:** the runner *refuses to start* if the API key exists in plain text anywhere in the repo, or if any `sk-`-shaped string is found in repo files (exposed key = no run; remove it and rotate). The key is accepted from the environment only, and is scrubbed from all error output. A live pre-flight check reports remaining credit before spending anything.
- **Budget kill-switch:** the moment a model's cumulative cost reaches `budget_usd`, the run aborts and records `outcome=budget_exhausted` — a *result*, not a failure ("Opus burned $1 before finishing" is a data point).
- **Auto-checks:** cheap regex checks run against the final output (`checks_passed` column); a 1–5 manual quality score can be added per run in the CSV.
- **Results append to `data/preset_runs.csv`**, and the report page (`index.html` §5) automatically renders the latest run per preset + model. All costs are recorded in USD; pass `-CurrencyCode`/`-CurrencyRate` to add a second currency column. Contribute a preset via PR — drop a JSON in `presets/`.

## FAQ

**Which is the cheapest LLM for agentic work?**
In this benchmark, GLM-5.3-flash — it completed the same 6-turn agent task for $0.0018, 77× cheaper than Claude Opus 5 and 15.5× cheaper than the best open-weight alternative (Qwen3-235B).

**Is a cheap token price the same as a cheap model?**
No — that's the benchmark's core finding. Token price predicts almost nothing about real task cost. Qwen3-235B looked cheap per token but finished 15.5× more expensive because of verbosity, multiplied by per-turn context re-reads.

**How is this benchmark different from LLM leaderboards?**
Leaderboards score quality; this measures billed cost per *completed task* with a hard USD budget kill-switch. "Opus burned $1 before finishing" is a result here, not a footnote.

**Can I run this benchmark myself?**
Yes. It needs PowerShell 5+ and an `OPENAI_API_KEY` (OpenRouter-compatible by default). See [Using presets](#using-presets). The runner includes a key-safety gate that refuses to start if a key is exposed in repo files.

**Can I test a model that isn't in the list?**
Yes — no preset file needed: `.\scripts\run_benchmark.ps1 -Preset general -Models 'vendor/new-model-id'`. Any OpenAI-compatible endpoint works via `-ApiBase`.

**Are the costs accurate?**
They are actual billed amounts extracted from API responses (`usage.cost`), captured Sep 22, 2026. Absolute prices age quickly; the methodology (measure per-task, not per-token) doesn't.

## Limitations

- Single task per test; one model's "same output quality" is judged by task completion, not output-quality scoring.
- 2026 pricing snapshot — absolute numbers age fast; the *methodology* (measure per-task, not per-token) doesn't.

## Contributing

PRs welcome, two ways:

- **New preset:** drop a JSON in `presets/` (schema above; a `tasks/<name>.md` turn-1 prompt is required).
- **New results:** run any preset with your key and append via the runner — `data/preset_runs.csv` renders on the live report automatically.

## Cite / share

Found this useful? Star the repo and share the live report: **https://jolubriones.github.io/llm-cost-benchmark/**

If you reference the finding, please keep the date: *"As of Sep 2026, GLM-5.3-flash completed a 6-turn agent task for $0.0018 vs $0.14 for Claude Opus 5 (77× gap) — measured with real billed API spend."*

## License

MIT — see [LICENSE](LICENSE). Data in `data/` is yours to use; attribution appreciated.

## Built with

The Sep 22 example run — benchmark design, orchestration, analysis, and this report — was built and executed with [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness), an open-source agent harness. The runner itself is plain PowerShell and has no dependency on it.

---
*Built as a personal benchmarking exercise. Data and scripts included — rerun it yourself.*