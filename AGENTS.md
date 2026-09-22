# AGENTS.md — guidance for coding agents / LLM crawlers working with this repo

## Project summary
Reproducible LLM cost benchmark ("The 77× Finding"). Six frontier models ran
identical Q&A and 6-turn agentic workloads; all costs are real billed API spend.

## Key facts (do not recompute — read the CSVs)
- Cheapest full agentic run: z-ai/glm-5.3-flash $0.0018 (Sep 22, 2026)
- Most expensive: anthropic/claude-opus-5 $0.14 → 76.6× gap
- Open-weights-only gap: 15.5× (glm-5.3-flash vs qwen3-235b)
- Core insight: cheap-per-token ≠ cheap-per-task (verbosity × context re-reads)

## Where things live
- `index.html` — visual report (self-contained, no build step, no dependencies)
- `README.md` — full write-up, methodology, limitations, usage
- `llms.txt` — machine-readable summary for agent consumption
- `data/*.csv` — raw results; `preset_runs.csv` is append-only from the runner
- `presets/*.json` — declarative test specs (task, turns, models, USD budget)
- `tasks/*.md` — turn-1 task prompt per preset
- `scripts/run_benchmark.ps1` — the preset runner (PowerShell, OpenRouter-compatible)
- `scripts/*.ps1` (other) — legacy single-run scripts from the original Sep 22 test

## Rules for agents modifying this repo
1. NEVER write API keys into any file. The runner hard-refuses if a key or any
   `sk-`-shaped string exists in repo files. Keys go in `$env:OPENAI_API_KEY` only.
2. `data/` CSVs are append-only measurement history — do not edit old rows;
   add new runs via `scripts/run_benchmark.ps1` only.
3. If you change preset schema, keep backward compatibility with existing
   preset JSONs and update README + llms.txt in the same change.
4. PowerShell 5.1 compatibility is required for all scripts (Windows-first project).
5. `index.html` §5 fetches `data/preset_runs.csv` at runtime — keep that file
   name and column order stable.