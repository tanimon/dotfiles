---
date: 2026-04-04
topic: closed-loop-rule-lifecycle
---

# Closed-Loop Rule Lifecycle

## Problem Frame

The harness engineering system learns through ECC instincts (confidence-scored observations) but cannot crystallize knowledge into permanent rules without manual `/promote-instincts` invocation. Once promoted, rules accumulate indefinitely — there is no feedback loop to measure whether a rule actually changes agent behavior, and no mechanism to remove ineffective rules. This one-way accumulation degrades context window utilization and dilutes the signal of effective rules.

The closed-loop lifecycle transforms the instinct-to-rule bridge from a manual, one-way escalator into an automated, bidirectional cycle: instincts auto-promote when mature, rules are measured for effectiveness, and ineffective rules are demoted back to instincts.

**Current state caveat:** The ECC observer has not yet produced instincts in this project (observer failures observed). Prerequisite #5 (Learning Pipeline Health Monitor) must confirm the observer is healthy before this system can operate. All requirements below assume a functioning instinct pipeline.

```
┌───────────────────────────────────────────────────────────────┐
│                    Closed-Loop Lifecycle                       │
│                                                               │
│  ┌────────────┐                      ┌──────────────────┐     │
│  │  Instinct  │   auto-promote       │ Provisional Rule │     ��
│  │ (ECC obs.) │   (weekly CI,        │ (auto-promoted)  │     │
│  │            │   confidence≥0.7)    │                  │     ���
│  │            │ ─────────────���─────► │  origin: auto    │     │
│  │            │                      │  instinct_id: X  │     │
│  └────────────┘ ◄─────────────────── └─────────────────��┘     │
│       ▲          auto-demote               │                  │
│       │          (90 days ineffective,     │ effectiveness    │
│       │          revert to instinct 0.4)   │ monitoring       │
│       │                                    ▼                  │
│       │                             ┌──────────────┐          │
│       │  same pattern re-appears    │  ECC Observer │          │
│       └─────────────────────────────│  (instinct    ��          │
│          = rule ineffective         │   re-creation │          │
│                                     │   signals)    │          │
│                                     ���──────────────┘          │
│                                                               │
│  Data flow: local instincts → snapshot commit → CI pipeline   │
│                                                               │
│  ┌──────────────────────────────���─────────────────────────┐   │
│  │ Manual Rules (CLAUDE.md, ~/.claude/rules/)             │   │
│  │ → NOT subject to auto-demotion                         │   │
│  │ → staleness detection only (existing lifecycle)        │   │
│  └───────────────────────��────────────────────────────────┘   │
└──────────────────��────────────────────────────────���───────────┘
```

## Requirements

**Instinct Data Sync**

- R1. A local mechanism (chezmoi declarative sync pattern) periodically snapshots instinct data from `~/.claude/homunculus/` to the chezmoi source tree, making it available to CI workflows.
- R2. The snapshot uses the same pattern as marketplace/extension sync: a `scripts/update-instinct-snapshot.sh` helper regenerates the snapshot, and a `run_onchange_` script tracks the hash.

**Auto-Promotion**

- R3. A weekly CI workflow reads the instinct snapshot and identifies candidates with confidence >= 0.7.
- R4. Each candidate is checked for duplication against existing rules before entering the proposal pipeline.
- R5. Candidates that pass deduplication are fed into the existing propose→validate→apply pipeline, preserving generator-evaluator separation.
- R6. Risk tiering is preserved: documentation-like rules auto-apply; behavioral rules create a PR for review.
- R7. Promoted rules carry a metadata comment: `# Auto-promoted from instinct <id> on <date> (confidence: <score>)`. Structured YAML frontmatter is deferred until the system handles 10+ auto-promoted rules.

**Effectiveness Measurement**

- R8. After a rule is promoted, the system monitors whether the ECC observer generates new instincts matching the same pattern (same domain, similar trigger) in subsequent snapshots.
- R9. Instinct re-creation within the rule's domain is the primary effectiveness signal: no re-creation = rule is working; re-creation = rule is being ignored or is insufficient.
- R10. The weekly CI workflow computes effectiveness status for each auto-promoted rule using a 30-day rolling window: `effective` (no matching instincts in window), `inconclusive` (fewer than 4 weekly snapshots available), or `ineffective` (matching instincts re-appeared).
- R11. Effectiveness state is persisted in a simple JSON file in the chezmoi source (e.g., `dot_claude/auto-promoted-rules-state.json`) tracking per-rule status history.

**Auto-Demotion**

- R12. Only auto-promoted rules (identified by the `# Auto-promoted from instinct` comment) are subject to auto-demotion. Manually written rules are excluded.
- R13. An auto-promoted rule is demoted when it has been `ineffective` for 90 consecutive days (the same staleness threshold as harness-rule-lifecycle).
- R14. Demotion removes the rule file from the chezmoi source tree and writes a new instinct file to the local instinct directory at confidence 0.4, preserving the learned pattern for potential re-promotion.
- R15. Demotion creates a commit (low-risk) or PR (high-risk). The state JSON (R11) records the demotion event including date, reason, and cycle count to detect repeat promote-demote patterns.

**Observability**

- R16. The weekly CI run produces a summary in `$GITHUB_STEP_SUMMARY`: total auto-promoted rules, effective count, inconclusive count, ineffective count, demoted this cycle.
- R17. Demotion events for high-risk rules create a GitHub Issue for visibility.

**Health Gate**

- R18. The auto-promotion and effectiveness measurement workflows include a health gate: if the Learning Pipeline Health Monitor (#5) reports the observer as unhealthy (zero instinct creation in the last 30 days), the workflow skips promotion and logs a warning instead of producing false "effective" readings.

## Success Criteria

- Auto-promoted rules appear in the chezmoi source tree without manual `/promote-instincts` invocation.
- Rules that are demonstrably ineffective (instinct re-creation persists) are automatically removed within 90 days.
- The total count of auto-promoted rules stabilizes over time rather than growing monotonically.
- Manual rules and CLAUDE.md entries are never touched by the auto-demotion mechanism.
- Generator-evaluator separation is maintained for all auto-promotions (no self-approval).
- The system gracefully degrades when the observer is unhealthy (skips rather than produces false data).

## Scope Boundaries

- **Not in scope**: Effectiveness measurement for manually written rules (staleness detection via existing harness-rule-lifecycle is sufficient).
- **Not in scope**: Failure correlation as an effectiveness metric (instinct re-creation is the sole proxy in v1).
- **Not in scope**: Real-time promotion triggers (weekly batch is the only trigger in v1).
- **Not in scope**: Cross-project instinct federation (separate ideation item #2).
- **Not in scope**: Changes to the ECC observer's instinct creation logic or confidence decay rate.
- **Not in scope**: Fixing the ECC observer itself — that is prerequisite #5's responsibility.

## Key Decisions

- **Instinct data access: snapshot commit** — CI runners cannot access `~/.claude/homunculus/`. A local sync script snapshots instinct data to the repo, following the existing declarative sync pattern (marketplaces.txt, extensions.txt). This keeps CI as the execution environment and preserves generator-evaluator separation.
- **Demotion target: auto-promoted rules only** — Manual rules represent intentional human judgment and should not be auto-removed. This preserves trust in the system while allowing automated knowledge to self-optimize.
- **Effectiveness metric: instinct re-creation rate** — A rule that works should suppress the instinct that spawned it. If the ECC observer keeps re-creating the same instinct despite the rule existing, the rule is not influencing agent behavior. This leverages existing ECC data without new telemetry infrastructure.
- **Effectiveness rolling window: 30 days** — Long enough to capture low-frequency patterns across multiple sessions, short enough to provide timely signal. Combined with the 90-day demotion threshold, a rule must be ineffective for 3 consecutive rolling windows before demotion.
- **Promotion trigger: weekly CI** — Matches existing harness-analysis cadence. Batch processing is simpler and more debuggable than event-driven triggers.
- **Demotion window: 90 days** — Aligns with harness-rule-lifecycle's existing staleness threshold.
- **Post-demotion: revert to instinct at 0.4** — Knowledge is preserved, not destroyed. Repeat promote-demote cycles signal that the rule formulation needs improvement, not that the pattern is invalid. Cycle detection via state JSON (R15).
- **Rule metadata: inline comments for v1** — YAML frontmatter is deferred until scale justifies it. A simple comment (`# Auto-promoted from instinct X on YYYY-MM-DD`) is sufficient to identify auto-promoted rules.

## Dependencies / Assumptions

- **Hard prerequisite: #5 (Learning Pipeline Health Monitor)** — Must confirm the ECC observer is healthy and producing instincts before this system can operate. R18 includes a health gate that skips processing when the observer is unhealthy.
- **Depends on #3 (Session-Start Deterministic Learning Injection)** — Session injection ensures instincts and rules are actively loaded into agent context, which is a prerequisite for measuring whether rules influence behavior.
- **Assumes ECC instinct fields are matchable** — Matching "same pattern" between a promoted rule and a new instinct requires comparing domain/trigger fields. The matching algorithm is deferred to planning.
- **Assumes chezmoi source is the single source of truth for rules** — Auto-promotion writes to `dot_claude/rules/` in the chezmoi source; auto-demotion removes from the same location.

## Outstanding Questions

### Deferred to Planning

- [Affects R8, R9][Needs research] How exactly should "same pattern" matching work between a promoted rule and a re-created instinct? Options: exact instinct_id match, domain + trigger similarity, or semantic embedding comparison. Investigate what fields ECC instincts actually expose and what is stable across observer runs.
- [Affects R3][Technical] Should the weekly auto-promotion CI be a new workflow or an additional job in the existing `harness-analysis.yml`? Note: `harness-analysis.yml` has `contents: read`; auto-promotion needs `contents: write` (like `harness-auto-remediate.yml`).
- [Affects R14][Needs research] How to programmatically create an instinct file — investigate the ECC instinct file format and whether `instinct-cli.py` provides a creation API, or if direct file writes to `~/.claude/homunculus/` are needed.
- [Affects R15][Technical] What constitutes a "repeat promote-demote cycle" threshold (likely: 2+ demotions of the same instinct_id) and what action to take (likely: flag for human review via GitHub Issue).
- [Affects R1, R2][Technical] Exact snapshot format and location in chezmoi source tree. Candidate: `dot_claude/instinct-snapshots/` with the same `.chezmoiignore` pattern as other dynamic data.

## Next Steps

→ `/ce:plan` for structured implementation planning (after #5 and #3 are planned/implemented)
