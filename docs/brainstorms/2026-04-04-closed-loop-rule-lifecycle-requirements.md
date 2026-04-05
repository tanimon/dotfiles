---
date: 2026-04-04
topic: closed-loop-rule-lifecycle
---

# Closed-Loop Rule Lifecycle

## Problem Frame

The harness engineering system learns through ECC instincts (confidence-scored observations) but cannot crystallize knowledge into permanent rules without manual `/promote-instincts` invocation. Once promoted, rules accumulate indefinitely — there is no feedback loop to measure whether a rule actually changes agent behavior, and no mechanism to remove ineffective rules. This one-way accumulation degrades context window utilization and dilutes the signal of effective rules.

The closed-loop lifecycle transforms the instinct-to-rule bridge from a manual, one-way escalator into an automated, bidirectional cycle: instincts auto-promote when mature, rules are measured for effectiveness, and ineffective rules are demoted back to instincts.

**Prerequisite status (as of 2026-04-04):**
- **#5 Learning Pipeline Health Monitor** — ✅ Merged (PR #125). `pipeline-health.sh` deployed at `~/.claude/scripts/`, supports `--json` output with `stages.instinct_creation.instinct_count` and `stages.observer_analysis.status`.
- **#3 Session-Start Deterministic Learning Injection** — ✅ Merged (PR #126). `learning-briefing.sh` injects instincts >= 0.6 confidence at session start.
- **ECC Observer** — ✅ Patched locally (temp file race condition + missing `--dangerously-skip-permissions`). Instinct generation confirmed working (3 instincts created). Note: local patch will be overwritten on plugin update.

## Phased Delivery

The system is delivered in two phases to reduce risk and validate assumptions with real data before building detection logic.

**Phase 1 (v1): Auto-Promotion** — R1-R7, R16, R18. Snapshots instincts, auto-promotes mature ones to rules, with health gate and observability. Deliverable: instincts become rules without manual invocation.

**Phase 2 (v2): Effectiveness Measurement + Auto-Demotion** — R8-R15, R17. Monitors promoted rules for effectiveness and demotes ineffective ones. Gate: proceed only after 10+ auto-promoted rules exist and empirical data on instinct patterns (re-creation rate, domain coverage) is available from v1 operation.

```
+---------------------------------------------------------------+
|                    Closed-Loop Lifecycle                       |
|                                                               |
|  +------------+                      +------------------+     |
|  |  Instinct  |   auto-promote       | Provisional Rule |     |
|  | (ECC obs.) |   (weekly CI,        | (auto-promoted)  |     |
|  |            |   confidence>=0.7)   |                  |     |
|  |            | -------------------> |  origin: auto    |     |
|  |            |                      |  instinct_id: X  |     |
|  +------------+ <------------------- +------------------+     |
|       ^          auto-demote (v2)          |                  |
|       |          (90 days ineffective,     | effectiveness    |
|       |          confidence reset to 0.4)  | monitoring (v2)  |
|       |                                    v                  |
|       |                             +--------------+          |
|       |  same pattern re-appears    | ECC Observer |          |
|       +-----------------------------|  (instinct   |          |
|          = rule ineffective         |   re-creation|          |
|                                     |   signals)   |          |
|                                     +--------------+          |
|                                                               |
|  Data flow: local instincts -> snapshot commit -> CI pipeline |
|                                                               |
|  +---------------------------------------------------------+  |
|  | Manual Rules (CLAUDE.md, ~/.claude/rules/)              |  |
|  | -> NOT subject to auto-demotion                         |  |
|  | -> staleness detection only (existing lifecycle)        |  |
|  +---------------------------------------------------------+  |
+---------------------------------------------------------------+
```

## Requirements

### Phase 1: Auto-Promotion

**Instinct Data Sync**

- R1. A local helper script (`scripts/update-instinct-snapshot.sh`) copies instinct data from `~/.claude/homunculus/projects/<hash>/instincts/personal/` to the chezmoi source tree (e.g., `dot_claude/instinct-snapshots/`), making it available to CI workflows via committed data.
- R2. The snapshot is committed manually or via a pre-CI step (not via `run_onchange_`, which flows source→target and does not apply to runtime→source data capture). The snapshot location is excluded from chezmoi deployment via `.chezmoiignore` to prevent deploying snapshot data to `~/`.

**Auto-Promotion**

- R3. A weekly CI workflow reads the instinct snapshot and identifies candidates with confidence >= 0.7. A minimum population gate of 5+ distinct instincts is required before any promotion runs (prevents premature promotion from sparse data).
- R4. Each candidate is checked for duplication against existing rules before entering the proposal pipeline. Domain-based filtering excludes meta/debugging instincts (domain `debugging` with triggers referencing the observer itself) from promotion candidates.
- R5. Candidates that pass deduplication are fed into the existing propose→validate→apply pipeline, preserving generator-evaluator separation. The pipeline must support non-interactive batch invocation from CI (confirm during planning).
- R6. Risk tiering is preserved: documentation-like rules auto-apply; behavioral rules create a PR for review. Classification criteria: instincts with domain `code-style` or `file-patterns` are documentation-like; all others are behavioral.
- R7. Promoted rules follow the existing rule format: a `## <trigger>` section within the appropriate rule file (project: `.claude/rules/`, global: `dot_claude/rules/common/`), with metadata comment `_Promoted from ECC instinct <id> on <date> (confidence: <score>)_`. Structured YAML frontmatter is deferred until the system handles 10+ auto-promoted rules.

**Observability (v1)**

- R16. The weekly CI run produces a summary in `$GITHUB_STEP_SUMMARY`: total instincts in snapshot, promotion candidates, promoted this cycle, skipped (with reason).

**Health Gate**

- R18. The auto-promotion workflow includes a health gate operating on **snapshot data** (not the live `~/.claude/homunculus/` directory, which is unavailable in CI). The gate checks: (a) snapshot freshness (snapshot timestamp within 14 days), (b) instinct count >= 5, (c) snapshot contains valid instinct files with required frontmatter fields (`id`, `trigger`, `confidence`, `domain`). If any check fails, the workflow skips promotion and logs a warning.

### Phase 2: Effectiveness Measurement + Auto-Demotion

> Phase 2 is gated on v1 operating successfully with 10+ auto-promoted rules. Requirements below are provisional and may be revised based on empirical data from v1.

**Effectiveness Measurement**

- R8. After a rule is promoted, the system monitors whether the ECC observer generates new instincts matching the same pattern (same domain, similar trigger keywords) in subsequent snapshots. Note: instinct re-creation is an indirect proxy — it can reflect user inactivity in a domain, observer non-determinism, or compliant behavior being re-observed (see Known Limitations).
- R9. Instinct re-creation within the rule's domain is the primary effectiveness signal: no re-creation = rule is likely working; re-creation = rule may be ineffective. This signal has known false-positive and false-negative paths (documented in Known Limitations).
- R10. The weekly CI workflow computes effectiveness status for each auto-promoted rule using a 30-day rolling window: `effective` (no matching instincts in window), `inconclusive` (fewer than 4 weekly snapshots available, or no domain-relevant sessions detected), or `ineffective` (matching instincts re-appeared).
- R11. Effectiveness state is persisted in the rule's metadata comment (extended from R7 format: `_Promoted from ECC instinct <id> on <date> (confidence: <score>) | status: effective | last_checked: <date>_`). A separate state JSON is not required for v2 — the metadata comment is the single source of truth.

**Auto-Demotion**

- R12. Only auto-promoted rules (identified by the `_Promoted from ECC instinct_` metadata comment) are subject to auto-demotion. Existing rules without this comment are treated as manually written and excluded.
- R13. An auto-promoted rule is demoted when it has been `ineffective` for 90 consecutive days.
- R14. Demotion removes the rule section from the chezmoi source tree and resets the source instinct's confidence to 0.4 (the instinct file persists — it is never deleted by promotion or demotion; only its confidence is adjusted).
- R15. Demotion creates a commit (low-risk) or PR (high-risk). **Circuit breaker**: after 2 demotions of the same instinct ID, the instinct is permanently excluded from auto-promotion (added to an exclusion list in the snapshot metadata). A GitHub Issue is created to flag the pattern for human review.

**Observability (v2)**

- R17. Phase 2 extends R16 with: effective count, inconclusive count, ineffective count, demoted this cycle. Demotion events for high-risk rules create a GitHub Issue for visibility.

## Known Limitations

The effectiveness measurement (R8-R10) relies on instinct re-creation as a proxy for rule impact. This proxy has known weaknesses:

- **False "effective"**: A rule may be ineffective, but the user did not work in that domain during the measurement window, so no instinct re-appeared. The `inconclusive` status partially addresses this but cannot distinguish "domain inactive" from "rule working."
- **False "ineffective"**: The observer may re-create a similar instinct because it observed the agent *following* the rule (compliant behavior looks similar to the original pattern). The keyword-overlap matching cannot distinguish violation from compliance.
- **Observer non-determinism**: The Haiku model may generate different instinct formulations across runs, causing matching failures or false matches.

These limitations are acceptable for v1 because the system's impact is bounded: false "effective" keeps a low-cost rule slightly longer; false "ineffective" demotes a rule that can be re-promoted if the pattern is genuinely important. Phase 2 should be informed by empirical data from v1 operation.

## Success Criteria

**v1 (Auto-Promotion):**
- Auto-promoted rules appear in the chezmoi source tree without manual `/promote-instincts` invocation.
- Manual rules and CLAUDE.md entries are never touched by auto-promotion.
- Generator-evaluator separation is maintained (no self-approval).
- The system gracefully degrades when the observer is unhealthy or snapshot is stale.

**v2 (Effectiveness + Demotion, provisional):**
- Rules flagged as ineffective by the re-creation proxy (acknowledging known false-positive paths) are automatically removed within 90 days.
- The ratio of effective-to-total auto-promoted rules is tracked and trends upward over time.
- Promote-demote oscillation is detected and circuit-broken within 2 cycles.
- Manual rules are never touched by the auto-demotion mechanism.

## Scope Boundaries

- **Not in scope**: Effectiveness measurement for manually written rules (staleness detection via existing harness-rule-lifecycle is sufficient).
- **Not in scope**: Failure correlation as an effectiveness metric (instinct re-creation is the sole proxy; the harness system does not currently emit structured failure signals).
- **Not in scope**: Real-time promotion triggers (weekly batch is the only trigger in v1).
- **Not in scope**: Cross-project instinct federation (separate ideation item #2).
- **Not in scope**: Changes to the ECC observer's instinct creation logic or confidence decay rate.
- **Not in scope**: Fixing the ECC observer itself — local patches are maintenance, not part of this feature.
- **Not in scope**: Modifying `/promote-instincts` to remove its user confirmation requirement — auto-promotion uses a separate CI-driven path.

## Key Decisions

- **Phased delivery** — v1 (auto-promotion only) ships first; v2 (effectiveness + demotion) ships only after 10+ auto-promoted rules and empirical instinct data exist. This avoids building detection logic on unvalidated assumptions about instinct behavior.
- **Instinct data access: snapshot commit** — CI runners cannot access `~/.claude/homunculus/`. A local sync script snapshots instinct data to the repo. Unlike marketplace/extension sync, the data flows runtime→source (not source→target), so `run_onchange_` is not used.
- **Demotion target: auto-promoted rules only** — Manual rules represent intentional human judgment and should not be auto-removed.
- **Effectiveness metric: instinct re-creation rate** — An indirect proxy with known limitations (see Known Limitations). Chosen because it leverages existing ECC data without new telemetry. Phase 2 design may be revised based on v1 empirical data.
- **Instinct persists through promotion and demotion** — The instinct file is never deleted. Promotion doesn't remove it. Demotion resets its confidence to 0.4.
- **Circuit breaker for promote-demote oscillation** — After 2 demotions of the same instinct, it is permanently excluded from auto-promotion and flagged for human review.
- **Effectiveness rolling window: 30 days** — Combined with 90-day demotion threshold, a rule must be ineffective for 3 consecutive windows before demotion.
- **Promotion trigger: weekly CI** — Matches existing harness-analysis cadence.
- **Demotion window: 90 days** — Aligns with harness-rule-lifecycle's existing staleness threshold.
- **Auto-promotion bypasses /promote-instincts** — Uses a separate CI path through propose→validate→apply, skipping interactive review. This creates two promotion paths; shared validation logic should be factored out during planning to reduce maintenance burden.
- **Pattern matching: domain + trigger keyword overlap** — Exact `id` matching is unreliable. Matching approach and threshold are deferred to planning (see Outstanding Questions) but are acknowledged as a load-bearing architectural decision that affects both dedup (R4) and effectiveness measurement (R8-R10).
- **Rule metadata as state carrier** — Rule metadata comments serve triple duty: identification (R12), status tracking (R11), and promotion attribution (R7). No separate state JSON is needed.
- **Minimum population gate** — R3 requires 5+ instincts before any promotion. Prevents premature promotion from sparse, potentially self-referential data.
- **Domain filtering** — Debugging-domain instincts referencing the observer itself are excluded from promotion to prevent meta-patterns from becoming rules.

## Dependencies / Assumptions

- **ECC observer dependency (CRITICAL)** — The observer is an external plugin (`everything-claude-code` v1.9.0) with no stability contract. Local patches (temp file → shell variable, `--dangerously-skip-permissions`) are required and will be overwritten on plugin update. **Mitigation**: (1) R18 health gate provides graceful degradation for pipeline breakage, (2) snapshot parser validates format on every run to detect format drift, (3) consider upstreaming patches or forking the observer script. The ECC plugin maintainer has not been consulted about format stability.
- **Assumes instinct format stability** — The instinct YAML frontmatter fields (`id`, `trigger`, `confidence`, `domain`, `source`, `scope`, `project_id`, `project_name`) are treated as stable. Changes to the ECC plugin's instinct format would break snapshot parsing and pattern matching. The snapshot parser should validate required fields exist before processing to detect format drift early.
- **Assumes chezmoi source is the single source of truth for rules** — Auto-promotion writes to `dot_claude/rules/` or `.claude/rules/` in the chezmoi source; auto-demotion removes from the same location.
- **Assumes session-guardian active hours** — The observer only runs during 8:00-23:00 JST. This affects instinct freshness but not the weekly batch processing. Sparse domain coverage in single-user repo may cause many rules to remain "inconclusive" — this is acceptable in v2.

## Outstanding Questions

### Deferred to Planning

- [Affects R3][Technical] Should the weekly auto-promotion CI be a new workflow or an additional job in the existing `harness-analysis.yml`? Note: `harness-analysis.yml` has `contents: read`; auto-promotion needs `contents: write`, `pull-requests: write`, and `issues: write` (consistent with `harness-auto-remediate.yml`).
- [Affects R1, R2][Technical] Exact snapshot format and location in chezmoi source tree. Candidate: `dot_claude/instinct-snapshots/`. Need to decide: full instinct files vs. summary JSON. Consider that CI must parse these for R3-R4 and R18 validation.
- [Affects R5][Technical] The propose→validate→apply pipeline consists of Claude Code slash-commands (markdown prompts), not scriptable executables. CI integration via `claude-code-action` requires either (a) embedding pipeline logic as an inline prompt (duplicating validation rules) or (b) invoking `claude` CLI with a prompt that references the skills. Determine which approach minimizes duplication while preserving generator-evaluator separation.
- [Affects R8, R10][Needs research — LOAD-BEARING] Pattern matching approach and threshold for "same pattern" detection. This is an architectural decision, not a tuning parameter: it determines the precision of both dedup (R4) and effectiveness measurement (R8-R10). Options: Jaccard similarity on trigger words, simple substring containment, or LLM-based similarity. Must be resolved early in planning.
- [Affects R4][Technical] Dedup approach for comparing instincts against existing rules. The instinct trigger is free-text; rules are markdown sections. Need a comparison strategy that handles format differences.
- [Affects R15][Technical] Circuit breaker exclusion list storage location. Must survive snapshot regeneration (R1 overwrites snapshot from runtime data). Options: separate exclusion file in chezmoi source (not part of snapshot), or merge logic in snapshot update script.
- [Affects R18][Technical] Snapshot timestamp recording mechanism. Options: embedded metadata file in snapshot directory, or `git log` on snapshot files (fragile). Constrained by snapshot format decision.
- [Affects R11][Technical] Metadata comment format string should be defined as a parseable contract (e.g., pipe-delimited key=value pairs) to prevent drift when CI updates status fields via regex.

## Next Steps

→ `/ce:plan` for structured implementation planning (Phase 1 scope: R1-R7, R16, R18)
