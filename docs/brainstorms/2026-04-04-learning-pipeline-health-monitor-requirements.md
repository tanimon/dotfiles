---
date: 2026-04-04
topic: learning-pipeline-health-monitor
---

# Learning Pipeline Health Monitor

## Problem Frame

The ECC continuous learning pipeline (observations → observer → instincts) operates as a black box. When it fails silently — as it currently does due to an observer-loop.sh bug that deletes the prompt file before use — nobody notices. The observer has failed on all analysis attempts, producing zero instincts despite 178+ captured observations. Without health visibility, downstream systems (#3 Session Injection, #1 Closed-Loop Rule Lifecycle) cannot distinguish "no instincts because the rule works" from "no instincts because the pipeline is broken."

```
Pipeline stages and health check points:

  [Observation Capture]     → observations.jsonl
       │ CHECK: file exists? last write recent?
       ▼
  [Observer Analysis]       → observer.log
       │ CHECK: any success? or all failures?
       ▼
  [Instinct Creation]      → instincts/personal/*.md
       │ CHECK: any instincts created?
       ▼
  [Health Summary]          → stdout + pipeline-health.json
```

## Requirements

**Health Check Script**

- R1. A shell script (`scripts/pipeline-health.sh`) reads local ECC data (`~/.claude/homunculus/`) and reports pipeline health. Shell script (not Claude Code command) so it can be called from both CLI and CI without LLM overhead.
- R2. The script checks three stages and reports binary status per stage (`ok` / `broken`):

| Stage | ok | broken |
|-------|-----|--------|
| Observation capture | `observations.jsonl` exists and has been modified within 14 days | File missing or no writes in 14+ days |
| Observer analysis | Last analysis attempt in `observer.log` succeeded (exit 0) | Last attempt failed (exit 1), or no attempts found, or log missing |
| Instinct creation | 1+ instinct files exist in `instincts/personal/` | Zero instinct files despite observations existing |

- R3. Overall pipeline status: `healthy` (all stages ok), `broken` (any stage broken).
- R4. Human-readable output with actionable next steps for each broken stage (e.g., "Observer analysis: BROKEN — last 3 attempts failed with exit 1. Check observer.log").
- R5. Machine-readable output mode (`--json`) that writes JSON to stdout with: overall status, per-stage status, timestamps, observation count, instinct count. CI consumers can redirect to a file (`scripts/pipeline-health.sh --json > pipeline-health.json`) for inclusion in the instinct snapshot.

**Graduated Health Criteria (Tier 2 — deferred)**

- R6. Once the pipeline has operated successfully for at least one full cycle (observations → instincts), add graduated thresholds (`healthy` / `degraded` / `broken`) with time-based windows (7/14/30 days). Until then, binary ok/broken is sufficient because there is no healthy baseline to degrade from.

## Success Criteria

- Running `scripts/pipeline-health.sh` immediately surfaces the current observer bug (observer analysis: `broken`).
- The script produces both human-readable and JSON output.
- When the observer is fixed and producing instincts, all stages report `ok`.
- #1's CI workflow can consume `pipeline-health.json` to gate auto-promotion.

## Scope Boundaries

- **Not in scope**: Fixing the observer-loop.sh bug itself (separate fix to ECC plugin).
- **Not in scope**: Automated remediation of pipeline failures (the monitor reports, the user fixes).
- **Not in scope**: Historical health tracking or trending (v1 is point-in-time snapshot).
- **Not in scope**: Alerting beyond CLI/CI output (no Slack/email notifications).
- **Not in scope**: CI health gate logic itself (belongs in #1's requirements; this script produces the data).
- **Deferred**: Graduated degraded/healthy/broken thresholds (R6) until pipeline has a healthy baseline.

## Key Decisions

- **Shell script, not Claude Code command** — Must be callable from both CLI and CI without LLM overhead. A `.md` command would require `claude-code-action` in CI, adding unnecessary cost and complexity.
- **Binary health (ok/broken) for v1** — The pipeline has never worked. Graduated thresholds (healthy/degraded/failing) require a healthy baseline to degrade from. Binary detection catches the current total-failure mode, which is the actual problem. Graduated criteria (R6) are deferred.
- **Time-based checks with conservative thresholds** — 14-day window for observation capture accommodates a low-frequency dotfiles repo where sessions may be days apart.
- **CI gate data produced here, gate logic lives in #1** — This script produces `pipeline-health.json`; #1's CI workflow consumes it. No split ownership of gate behavior.

## Dependencies / Assumptions

- **Assumes ECC data at known paths** — `~/.claude/homunculus/projects/<hash>/` with `observations.jsonl`, `observer.log`, `instincts/personal/`. Format verified against current ECC 1.9.0.
- **No external dependencies** — Script uses only standard shell tools (bash, jq, stat, wc). jq is already a project dependency.

## Outstanding Questions

### Deferred to Planning

- [Affects R1][Technical] How to discover the project hash directory automatically. Options: parse `project.json`, use git remote hash, or glob `~/.claude/homunculus/projects/*/`.
- [Affects R2][Needs research] Exact format of `observer.log` success/failure entries — need to parse for exit codes or success markers.
- [Affects R5][Technical] Should `--json` write to stdout or to a fixed file path? CI consumption favors a file; interactive use favors stdout.

## Next Steps

→ `/ce:plan` for structured implementation planning
