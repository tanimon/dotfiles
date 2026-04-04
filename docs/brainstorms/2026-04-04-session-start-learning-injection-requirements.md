---
date: 2026-04-04
topic: session-start-learning-injection
---

# Session-Start Deterministic Learning Injection

## Problem Frame

The harness-activator hook currently injects two things at session start: a CLAUDE.md existence check and a generic "evaluate improvements after this session" reminder. It also lists high-confidence instincts (>= 0.7). However, this is a backward-looking prompt to the agent to self-evaluate, not a forward-looking data-driven briefing. The agent starts each session without awareness of the learning pipeline's health or the full spectrum of patterns the observer has detected.

The result: the agent only sees instincts that have already reached high confidence (>= 0.7), missing the broader set of patterns the observer has detected but not yet crystallized. Additionally, the agent has no visibility into whether the learning pipeline itself is functioning — a silent observer crash means zero instincts without any warning.

```
Current flow (harness-activator.sh):

  Session Start
       |
       v
  [Check CLAUDE.md] --> warn if missing
       |
       v
  [List instincts >= 0.7] --> static list (high-confidence only)
       |
       v
  [Print evaluation reminder] --> "after this session, evaluate..."
       |
       v
  Agent works (no pipeline health awareness, limited instinct visibility)
```

```
Proposed flow (learning-briefing.sh):

  Session Start
       |
       v
  [Pipeline Health] --> pipeline-health.sh --json
       |                 broken? -> warn with summary
       |                 healthy? -> 1-line status
       v
  [Instincts >= 0.6] --> near-promotion + active instincts
       |                  domain, trigger, action, confidence
       v
  [CLAUDE.md check + Evaluation Reminder] --> retained
       |
       v
  Agent works with pipeline awareness + broader instinct context
```

## Requirements

**Data Injection**

- R1. A new hook script (`dot_claude/scripts/executable_learning-briefing.sh`) replaces `harness-activator.sh` as the `UserPromptSubmit` hook. It fires once per session (same one-shot flag pattern) and outputs a data-driven briefing to stdout.
- R2. The briefing includes pipeline health status by invoking `pipeline-health.sh --json` (co-located in `dot_claude/scripts/`, deployed to `~/.claude/scripts/` by chezmoi). When healthy, output a single summary line. When broken, output the overall status and which stages are broken (compact format, not full per-stage detail).
- R3. The briefing includes instincts at confidence >= 0.6 (lowered from the current 0.7), showing domain, trigger, action (if available), and confidence. Cap at 15 instincts. This surfaces near-promotion patterns the observer has detected but not yet crystallized, alongside active high-confidence instincts.
- R4. The briefing retains the CLAUDE.md existence check and a compact evaluation reminder. The current multi-item reminder (~200 tokens) is condensed to a 1-2 line summary with skill invocation references (~50 tokens). The CLAUDE.md check and evaluation reminder are always included in the output regardless of whether health/instinct data is available.

**Token Budget**

- R5. Total briefing output targets ~600 tokens. Per-section soft budgets: pipeline health (~50 tokens when healthy, ~100 when broken), instincts (~350 tokens for up to 15 instincts), CLAUDE.md check + compact evaluation reminder (~50 tokens). These are estimates to be validated during planning with representative data; the instinct cap (R3) should be adjusted if real-world measurement shows the budget is exceeded.
- R6. When instincts would exceed their budget, truncate with a count indicator (e.g., "... and 5 more instincts"). Prioritize higher-confidence instincts.

**Backward Compatibility**

- R7. The old `harness-activator.sh` is removed from the `UserPromptSubmit` hook configuration in `settings.json.tmpl`. Only the harness-activator entry is replaced; the claudeception-activator entry remains unchanged. The replacement entry must preserve the same error-handling pattern as the current harness-activator entry: stderr redirect to log file and `|| true` failure suppression.
- R8. All existing harness-activator behavior is preserved in the new script, with one intentional change: the instinct confidence threshold is lowered from 0.7 to 0.6 to surface near-promotion patterns.

**Pipeline Health Script Migration**

- R9. `scripts/pipeline-health.sh` is moved to `dot_claude/scripts/executable_pipeline-health.sh` as the single source of truth. chezmoi deploys it to `~/.claude/scripts/pipeline-health.sh`, making it available to the hook at runtime.
- R10. The Makefile `test-pipeline-health` target is updated to reference the new path (`dot_claude/scripts/executable_pipeline-health.sh`). The `test-scripts` target is also updated to test the new `learning-briefing.sh` instead of `harness-activator.sh`, including updated expected output strings and flag file patterns.
- R11. The old `scripts/pipeline-health.sh` is deleted. The old `dot_claude/scripts/executable_harness-activator.sh` is also deleted; chezmoi target cleanup (via `.chezmoiremove` or manual removal note) ensures the orphan `~/.claude/scripts/harness-activator.sh` is handled.

**Graceful Degradation**

- R12. If `pipeline-health.sh` is not available or fails, skip the health section silently (exit 0 contract).
- R13. If no instincts directory exists or no instincts meet the threshold, skip the instincts section.
- R14. If all data sections are empty (no health data, no instincts), output the CLAUDE.md check and evaluation reminder only (per R4, these are always present). This is the baseline behavior — the success criteria acknowledges this fallback.

## Success Criteria

- Every new session starts with a briefing that includes pipeline health status and instinct context when available.
- The briefing fits within ~600 tokens, avoiding context window pressure.
- Pipeline health status is visible at session start — broken observers are immediately surfaced.
- Near-promotion instincts (0.6-0.69) are now visible alongside active instincts, giving the agent a broader view of observed patterns.
- Running in a project with no ECC data gracefully falls back to the CLAUDE.md check and evaluation reminder (current baseline).
- `pipeline-health.sh` is accessible from both CI (via repo path) and runtime hooks (via chezmoi deployment).

## Scope Boundaries

- **Not in scope**: Raw observation injection to session start (instincts are the distilled learning from observations; raw observation data carries low signal-to-noise for session briefing purposes).
- **Not in scope**: LLM-based summarization (too slow and costly for a hook).
- **Not in scope**: Historical trending or comparison across sessions (point-in-time snapshot only).
- **Not in scope**: Modifying the ECC observer or instinct format.
- **Not in scope**: Adding new hook events (uses existing `UserPromptSubmit`).
- **Not in scope**: Cross-project observation sharing (belongs to idea #2, Cross-Project Instinct Federation).

## Key Decisions

- **Full replacement of harness-activator.sh** — The new `learning-briefing.sh` replaces rather than extends `harness-activator.sh`. This avoids two hooks fighting over session-start output and keeps the briefing unified.
- **Instincts over raw observations** — Instincts are the output of the learning pipeline (synthesized patterns with confidence scores). Raw observations are the input (tool call logs). Injecting raw observations would consume token budget on noise (routine tool calls) rather than signal (learned patterns). The agent benefits more from 15 instincts with domain/trigger/action than from 10 raw observation lines showing "Bash, tool_start, timestamp."
- **~600 token budget** — Compact enough to be negligible in any context window (< 0.1% of Sonnet's 200k). Accommodates 15 instincts + compact health summary + condensed evaluation reminder. Budget estimates are soft targets to be validated with real data during planning.
- **pipeline-health.sh migrated to dot_claude/scripts/** — Single source of truth. Deployed by chezmoi to `~/.claude/scripts/` for runtime access; referenced directly by Makefile for CI. Eliminates the repo-only vs. runtime split.
- **Instinct threshold lowered to 0.6** — The ECC observer creates instincts starting at 0.3 with weekly decay of -0.02. The current 0.7 threshold only shows instincts that have been confirmed multiple times. Lowering to 0.6 captures instincts that are trending upward (3-4 confirming observations) but haven't yet reached promotion threshold. The 10-instinct cap from harness-activator is raised to 15 to accommodate the wider range.
- **Compact broken-state health output** — When the pipeline is broken, the briefing shows overall status + which stages failed in a single compact block (~100 tokens), not full per-stage detail with actionable steps. The agent cannot fix ECC infrastructure; it only needs to know the pipeline is broken so it can inform the user.

## Dependencies / Assumptions

- **Depends on #5 (Learning Pipeline Health Monitor)** — Uses `pipeline-health.sh --json` for health status. Already implemented and merged (PR #125). Script will be migrated from `scripts/` to `dot_claude/scripts/` as part of this work.
- **Assumes ECC data at known paths** — `~/.claude/homunculus/projects/<hash>/instincts/personal/`. Format verified against current ECC.
- **Assumes jq is available** — Already a project dependency, used by pipeline-health.sh and modify_dot_claude.json.
- **UserPromptSubmit hook receives JSON on stdin** — Contains `session_id` for one-shot flag pattern. The new script must capture stdin before any other processing (stdin can only be read once, same pattern as harness-activator.sh).

## Outstanding Questions

### Deferred to Planning

- [Affects R11][Technical] How to handle chezmoi target cleanup for the deleted `harness-activator.sh`. Options: `.chezmoiremove`, a one-time cleanup in `run_onchange_` script, or documentation for manual removal.
- [Affects R5][Needs research] Validate the ~600 token estimate by measuring actual output with representative instinct data. Adjust instinct cap if the budget is exceeded.
- [Affects R3][Technical] Does the instinct file format include an `action` field alongside `trigger`? Investigate the instinct YAML schema to determine which fields are available for display.
- [Affects R10][Technical] Verify that moving `pipeline-health.sh` to `dot_claude/scripts/` doesn't break the existing shellcheck/shfmt glob patterns (the `executable_*` pattern in `dot_claude/scripts/` is already covered).

## Next Steps

→ `/ce:plan` for structured implementation planning
