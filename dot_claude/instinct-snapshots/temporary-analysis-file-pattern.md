---
id: temporary-analysis-file-pattern
trigger: when preparing observations for analysis or debugging observer output
confidence: 0.7
domain: file-patterns
source: session-observation
scope: project
project_id: 23e6ae2f0a00
project_name: chezmoi
---

# Temporary Analysis File Pattern

## Action
Create `.observer-tmp/ecc-observer-analysis.XXXXXX.jsonl` using `mktemp` and populate with `tail -n` observations before invoking analysis.

## Evidence
- Observed 3 times in session 6e0cc6bc-f31a-498c-b915-9db7e712e48c
- Pattern: `mkdir -p .observer-tmp`, `mktemp .observer-tmp/ecc-observer-analysis.XXXXXX.jsonl`, then `tail -n 500 observations.jsonl > analysis_file`
- Stores analysis data separately from live observations; cleanup with `rm -f` after analysis
- Last observed: 2026-04-04T14:33:32Z
