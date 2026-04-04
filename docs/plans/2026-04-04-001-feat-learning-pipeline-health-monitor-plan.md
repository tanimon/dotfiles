---
title: "feat: Add learning pipeline health monitor"
type: feat
status: completed
date: 2026-04-04
origin: docs/brainstorms/2026-04-04-learning-pipeline-health-monitor-requirements.md
---

# feat: Add learning pipeline health monitor

## Overview

Add a shell script (`scripts/pipeline-health.sh`) that diagnoses the ECC continuous learning pipeline health by inspecting local data files. The script checks three stages (observation capture, observer analysis, instinct creation), reports binary ok/broken status per stage, and outputs both human-readable and JSON formats. The JSON output serves as the health gate data source for the future #1 (Closed-Loop Rule Lifecycle) CI workflow.

## Problem Frame

The ECC observer pipeline currently fails silently. The observer has crashed on all analysis attempts (prompt file deleted before use in observer-loop.sh), producing zero instincts despite 178+ observations. Without a health check, downstream systems cannot distinguish "pipeline working, no patterns found" from "pipeline broken." (see origin: `docs/brainstorms/2026-04-04-learning-pipeline-health-monitor-requirements.md`)

## Requirements Trace

- R1. Shell script at `scripts/pipeline-health.sh`, callable from CLI and CI
- R2. Three-stage binary health check (ok/broken)
- R3. Overall status: healthy (all ok) / broken (any broken)
- R4. Human-readable output with actionable next steps
- R5. Machine-readable `--json` output
- R6. Graduated thresholds (deferred to Tier 2)

## Scope Boundaries

- Not fixing the observer-loop.sh bug (separate ECC plugin issue)
- Not automating remediation (report only)
- Not historical tracking (point-in-time snapshot)
- Not alerting beyond CLI/CI output
- Graduated thresholds deferred (R6)

## Context & Research

### Relevant Code and Patterns

- `scripts/update-brewfile.sh`, `scripts/update-gh-extensions.sh`, `scripts/update-marketplaces.sh` — existing helper scripts in same directory, follow `#!/usr/bin/env bash` + `set -euo pipefail` pattern
- `dot_claude/scripts/executable_harness-activator.sh` — existing script that reads instinct files, uses same project hash discovery pattern
- `.claude/rules/shell-scripts.md` — shell script rules (header, error handling)

### ECC Data Paths (verified)

| Component | Path | Format |
|-----------|------|--------|
| Project dir | `~/.claude/homunculus/projects/<hash>/` | Directory |
| Project metadata | `project.json` | JSON (`id`, `name`, `root`, `remote`) |
| Observations | `observations.jsonl` | JSON Lines |
| Observer log | `observer.log` | Plain text with timestamped entries |
| Instinct files | `instincts/personal/*.md` | YAML frontmatter + markdown |
| Observer activity | `.observer-last-activity` | Touch file (mtime) |
| Observer PID | `.observer.pid` | Plain text (PID number) |

### Observer Log Parsing

Success marker: line contains `"Analyzing"` + observation count
Failure marker: line contains `"Claude analysis failed (exit 1)"`
The last analysis entry in the log determines observer health.

### Project Hash Discovery

```
git remote get-url origin | sed -E 's|://[^@]+@|://|' | shasum -a 256 | cut -c1-12
```

Falls back to globbing `~/.claude/homunculus/projects/*/` if no git remote.

### Institutional Learnings

- Hook exit code contract: `exit 0` for healthy/skip, `exit 1` + stderr for errors (see `docs/solutions/integration-issues/claude-code-hook-exit-code-and-stderr-semantics.md`)
- jq dependency guard: `command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 1; }`
- `~/.claude/` is rw-allowed in sandbox — no sandbox changes needed

## Key Technical Decisions

- **`--json` writes to stdout** — Both human and JSON modes write to stdout. CI can redirect to file (`scripts/pipeline-health.sh --json > pipeline-health.json`). Simpler than managing file paths in the script. (Resolved from origin deferred question)
- **Project discovery: git remote hash first, glob fallback** — Deterministic when inside a git repo. Glob `~/.claude/homunculus/projects/*/` as fallback handles non-git contexts. (Resolved from origin deferred question)
- **Observer log parsing: grep for last failure/success marker** — Parse the last `"Claude analysis failed"` or `"Analyzing"` line. Simple and robust against log format changes. (Resolved from origin deferred question)

## Open Questions

### Deferred to Implementation

- Observer PID file (`.observer.pid`) reliability: may not be cleaned up on crash. Use `.observer-last-activity` mtime as primary activity signal instead of PID liveness.

## Implementation Units

- [x] **Unit 1: Core health check script**

**Goal:** Create the main `scripts/pipeline-health.sh` that checks all three pipeline stages and outputs human-readable results.

**Requirements:** R1, R2, R3, R4

**Dependencies:** None

**Files:**
- Create: `scripts/pipeline-health.sh`
- Test: `Makefile` target `test-pipeline-health`

**Approach:**
- Script header: `#!/usr/bin/env bash` + `set -euo pipefail`
- Discover project directory via git remote hash, fallback to glob
- Check stage 1 (observation capture): `observations.jsonl` exists and mtime within 14 days
- Check stage 2 (observer analysis): parse `observer.log` for last analysis result
- Check stage 3 (instinct creation): count files in `instincts/personal/`
- Aggregate: overall `healthy` if all ok, `broken` if any broken
- Print human-readable summary with per-stage status and actionable messages
- Exit 0 for health states (diagnostic tool, not a gate — the gate logic is in #1); exit non-zero for usage errors (unknown flags) and missing dependencies (jq)

**Patterns to follow:**
- `scripts/update-brewfile.sh` for script structure and header
- `dot_claude/scripts/executable_harness-activator.sh` for instinct directory scanning pattern

**Test scenarios:**
- Happy path: script runs without error when `~/.claude/homunculus/` exists with valid project directory
- Happy path: all stages report `ok` when observations are recent, observer log shows success, and instinct files exist
- Error path: observation capture reports `broken` when `observations.jsonl` is missing or older than 14 days
- Error path: observer analysis reports `broken` when last log entry contains "Claude analysis failed"
- Error path: instinct creation reports `broken` when `instincts/personal/` is empty despite observations existing
- Edge case: script handles missing `~/.claude/homunculus/` directory gracefully (reports all broken, does not crash)
- Edge case: script handles no git remote gracefully (falls back to glob discovery)
- Integration: running against the current live data surfaces observer as broken (validates the real bug)

**Verification:**
- `bash scripts/pipeline-health.sh` runs and shows observer analysis as BROKEN against current live data
- Script passes shellcheck and shfmt

---

- [x] **Unit 2: JSON output mode**

**Goal:** Add `--json` flag that outputs machine-readable JSON to stdout.

**Requirements:** R5

**Dependencies:** Unit 1

**Files:**
- Modify: `scripts/pipeline-health.sh`
- Test: `Makefile` target `test-pipeline-health`

**Approach:**
- Parse `--json` flag from `$1`
- Reuse same health check logic from Unit 1
- When `--json`, output structured JSON via jq instead of human-readable text
- JSON schema: `{ "overall_status": "healthy"|"broken", "snapshot_timestamp": "<iso8601>", "project_id": "<hash>", "stages": { "observation_capture": { "status": "ok"|"broken", "observation_count": N, "last_write_age_days": N }, "observer_analysis": { "status": "ok"|"broken", "last_result": "success"|"failure"|"unknown" }, "instinct_creation": { "status": "ok"|"broken", "instinct_count": N } } }`
- Guard for jq dependency at script start

**Patterns to follow:**
- jq for JSON construction: `jq -n --arg status "$STATUS" '{overall_status: $status, ...}'`

**Test scenarios:**
- Happy path: `--json` flag produces valid JSON (parseable by jq)
- Happy path: JSON contains all required fields (overall_status, stages, snapshot_timestamp)
- Edge case: JSON output works when all stages are broken (no null fields)
- Integration: `scripts/pipeline-health.sh --json | jq .overall_status` returns `"broken"` against current data

**Verification:**
- `scripts/pipeline-health.sh --json | jq .` produces valid, complete JSON
- JSON contains correct status values matching human-readable output

---

- [x] **Unit 3: CI integration (lint + test)**

**Goal:** Add the health script to Makefile lint targets and ensure tests run in CI.

**Requirements:** R1 (callable from CI)

**Dependencies:** Unit 1, Unit 2

**Files:**
- Modify: `Makefile` (add `test-pipeline-health` target)
- Modify: `.github/workflows/lint.yml` (add CI job)

**Approach:**
- Add `test-pipeline-health` target to Makefile, following the pattern of `test-modify` and `test-scripts`
- Add `pipeline-health` CI job to `lint.yml`, following the pattern of `harness-scripts` job
- Smoke test: verify script is executable, `--help` works, `--json` produces valid JSON structure
- Note: full integration tests require `~/.claude/homunculus/` data, so CI smoke tests focus on script syntax and argument handling, not live data checks
- Ensure `scripts/pipeline-health.sh` passes existing `make shellcheck` and `make shfmt` targets (no new Makefile entries needed for these — the glob patterns already cover `scripts/`)

**Test scenarios:**
- Happy path: `make test-pipeline-health` passes
- Happy path: `scripts/pipeline-health.sh` passes shellcheck
- Happy path: `scripts/pipeline-health.sh` passes shfmt (indent=4)
- Edge case: smoke test works on CI runner with no `~/.claude/homunculus/` (graceful degradation)

**Verification:**
- `make lint` passes with the new script included
- `make test-pipeline-health` passes

## System-Wide Impact

- **Interaction graph:** Script reads ECC runtime data (read-only). No writes to `~/.claude/homunculus/`. No interaction with Claude Code hooks or sessions.
- **Error propagation:** Broken/unhealthy pipeline status is reported in output, not via exit code, so diagnostic results do not fail CI by themselves — the gate logic in #1 decides how to act. The script does exit non-zero for actual invocation/runtime errors, including invalid/unknown flags and `--json` when `jq` is unavailable.
- **Unchanged invariants:** `.chezmoiignore` already excludes `~/.claude/homunculus/` — no change needed. Existing `make lint` glob patterns already cover `scripts/`.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Observer log format changes in future ECC versions | Parse for known markers ("Claude analysis failed", "Analyzing") with fallback to "unknown" status |
| `~/.claude/homunculus/` path changes | Project hash discovery is the stable interface; directory structure is a verified assumption against ECC 1.9.0 |
| CI smoke tests limited without live data | Separate integration test (Unit 1 test scenario) validates against real data locally |

## Sources & References

- **Origin document:** [docs/brainstorms/2026-04-04-learning-pipeline-health-monitor-requirements.md](docs/brainstorms/2026-04-04-learning-pipeline-health-monitor-requirements.md)
- ECC observer spec: `~/.claude/plugins/cache/everything-claude-code/.../skills/continuous-learning-v2/agents/observer.md`
- ECC integration solution: `docs/solutions/integration-issues/ecc-continuous-learning-harness-integration-2026-04-03.md`
- Hook exit code semantics: `docs/solutions/integration-issues/claude-code-hook-exit-code-and-stderr-semantics.md`
