# Harness Engineering System Rebuild — Design

**Date:** 2026-07-06
**Status:** Approved (pending user review of this document)

## Context

The existing harness self-improvement system (ECC instinct observer, propose/validate/apply
skill pipeline, three scheduled CI workflows) was audited on 2026-07-06 and found to have
been silently dead for weeks: `harness-analysis.yml` failing with 401 since 2026-06-07
(expired `CLAUDE_CODE_OAUTH_TOKEN`), `auto-promote.yml` gate skipping green since mid-May
(stale instinct snapshot), and the ECC observer never running (upstream plugin rename
orphaned the `enabledPlugins` key). Over its entire lifetime the instinct system
auto-promoted **zero** rules. Root cause of the outage going unnoticed: the system had no
self-monitoring, and its failure modes were all silent (CI failures with no alerting, gates
skipping as green, a "Pipeline: BROKEN" briefing line with no diagnosis that became
permanent noise).

This design replaces the mechanism from scratch while keeping all accumulated knowledge.

## Decisions (settled during brainstorming)

1. **Scope:** Scrap the existing mechanism entirely; rebuild simple.
2. **Knowledge assets are kept:** CLAUDE.md Known Pitfalls, `.claude/rules/`,
   `~/.claude/rules/`, `docs/solutions/` all survive. Only machinery is demolished.
3. **Trust model:** Every harness change goes through a PR reviewed by a human. No
   auto-merge tiers. The human PR review is the single quality gate (no LLM
   generator-evaluator layer).
4. **Learning capture:** Hook-triggered self-reflection as the primary path, with the same
   logic invocable manually as a skill.
5. **Cost model for reflection:** Deferred. The SessionEnd hook only records the transcript
   path (deterministic append); LLM analysis happens batched inside the next interactive
   reflect/review run. No headless `claude -p` from hooks.
6. **Periodic health checks run locally**, not in CI. This removes the OAuth-token failure
   class entirely.
7. **Improvement candidates live in a local queue file, not GitHub Issues.** Deliverables
   (rule changes) are PRs. Nudging is done by the SessionStart briefing.

## Design principles (derived from the old system's causes of death)

1. **LLM at exactly two points** — extraction (reflect) and triage (review). All
   monitoring, nudging, and freshness checks are deterministic shell scripts.
2. **Not-running must be visible by default.** The briefing prints one status line every
   session even when healthy; silence itself signals a dead hook. Warnings always carry a
   diagnosis and a remediation command.
3. **Runtime state is not chezmoi-managed.** Queue/state live in `~/.claude/harness/`
   (added to `.chezmoiignore`). Only deliverables (rules) are version-controlled, via PR.

## Architecture

```
Session work → learnings occur
      │
SessionEnd hook (deterministic): turn-count gate → append
      │         {transcript_path, session_id, date} to pending.jsonl
      ▼
~/.claude/harness/pending.jsonl   (unreflected sessions)
~/.claude/harness/queue.md        (structured improvement candidates)
~/.claude/harness/state.json      (last reflect/review timestamps)
      │
SessionStart hook (deterministic briefing):
      reads state + queue + pending → one status line, or loud warnings
      (review overdue >7d, pending pile-up, queue pile-up, corrupt state)
      │
/harness-reflect (manual, or run as first step of review):
      analyzes current session and/or batched pending transcripts
      → appends candidates to queue.md, clears pending entries
      │
/harness-review (manual, nudged by briefing every ~7 days):
      1. run harness-doctor.sh (deterministic liveness check)
      2. reflect over any pending transcripts
      3. triage queue: dedupe vs existing rules/solutions → adopt/reject
      4. implement adopted candidates on a branch → one PR
      5. staleness scan of existing rules
      6. update state.json, move processed entries to queue-archive.md
      │
Human reviews & merges PR   ← the only quality gate
```

## Components

### 1. `/harness-reflect` skill — `dot_claude/skills/harness-reflect/SKILL.md`

Extracts harness-worthy learnings and appends structured entries to `queue.md`.

- **Inputs:** (a) the current session (manual invocation; full context, highest quality),
  (b) batched unreflected transcripts from `pending.jsonl`.
- **Extracts:** wrong agent assumptions and their root cause; user corrections; reusable
  patterns; drift between rules/CLAUDE.md and reality.
- **Does not extract:** one-off circumstances, things the repo already shows,
  conversation-local context (inherits criteria from `harness-engineering.md`).
- **Queue entry format:** what happened / root cause / proposed rule text / scope
  (project or global) / source session ID / date.
- **No dedup at reflect time** — dedup is review's job; reflect stays cheap.
- Removes processed entries from `pending.jsonl`.

### 2. SessionEnd hook — `dot_claude/scripts/executable_harness-reflect-trigger.sh`

Deterministic, ~a dozen lines:

- Reads hook JSON from stdin (`transcript_path`, `session_id`).
- **Gate:** skip if user/assistant turn count < 10; skip headless runs (env guard).
- Appends one JSON line to `~/.claude/harness/pending.jsonl`.
- Records attempt in `state.json`. Malformed stdin → exit 0 (never break session teardown).

### 3. `/harness-review` skill — `dot_claude/skills/harness-review/SKILL.md`

The periodic health check. Steps as in the architecture diagram. Additional rules:

- Adopted candidates are implemented as rule/CLAUDE.md/docs-solutions changes on a branch
  and bundled into **one PR** per review run.
- Rejected candidates go to `queue-archive.md` with the verdict recorded.
- Staleness scan: verify files/commands referenced by existing rules still exist; flag
  rules contradicted by recent learnings.

### 4. SessionStart briefing — `dot_claude/scripts/executable_harness-briefing.sh`

Deterministic, replaces the old ECC learning-briefing.

- Healthy: `Harness: OK | queue: 3 | pending: 2 | last review: 4d ago` (one line, always).
- Warnings (each with a remediation command), limited to exactly four kinds:
  1. review overdue (>7 days)
  2. pending pile-up (>5 entries or oldest >20 days — transcript retention risk)
  3. queue pile-up (>10 unprocessed)
  4. state file corrupt/unreadable
- A warning that becomes permanent noise is itself a harness bug → queue it.

### 5. `harness-doctor.sh` — `dot_claude/scripts/executable_harness-doctor.sh`

Deterministic liveness check, run by review and standalone:

- hooks registered in deployed settings; harness dir writable; state/pending/queue
  parseable; last reflect-trigger attempt recorded recently; skills deployed.

### 6. Runtime state — `~/.claude/harness/` (chezmoi-ignored)

- `state.json`: `last_reflect_attempt`, `last_reflect_ok`, `last_review`,
  `consecutive_reflect_failures`.
- `queue.md`: append-only Markdown, human-readable and hand-editable.
- `pending.jsonl`, `queue-archive.md`.
- Writes are append-only or atomic (temp file + rename) to tolerate concurrent sessions.
- Corrupt files never crash reflect/review: warn and rebuild from empty.

### 7. Wiring — `dot_claude/settings.json.tmpl`

- Add SessionEnd → reflect-trigger, SessionStart → briefing.
- Hook commands stay trivial (single script path) per the inline-hook pitfall rule.

## Demolition plan

### Delete

- **Workflows:** `harness-analysis.yml`, `auto-promote.yml`, `harness-auto-remediate.yml`.
- **Skills:** `propose-harness-improvement`, `validate-harness-proposal`,
  `compound-harness-knowledge`, `ecc-observer-diagnosis`.
- **Commands:** `apply-harness-proposal`, `capture-harness-feedback`, `harness-health`,
  `harness-rule-lifecycle`, `promote-instincts`, `resolve-harness-issues`.
- **ECC learning glue:** `dot_claude/instinct-snapshots/`, `scripts/snapshot-instincts.sh`,
  `scripts/validate-instinct-snapshot.sh`, `executable_learning-briefing.sh`,
  `pipeline-health.sh`, Makefile targets `test-pipeline-health`,
  `test-snapshot-instincts`, `test-validate-snapshot`.

### Keep (explicit boundary)

- **ECC plugin itself** (reviewer agents and MCP servers are in use independently of the
  learning loop). Disable its continuous-learning observer by keeping `CLV2_CONFIG`
  pointing at a config with the observer disabled — do NOT remove the env var, or plugin
  defaults may re-enable the observer.
- **`security-alerts.yml` + `.github/actions/harness-issue-alert`** — separate concern,
  working independently.
- **`lint.yml`, `claude.yml`** — unrelated.
- **All knowledge assets** (rules, docs/solutions, Known Pitfalls).

### Rewrite

- `~/.claude/rules/common/harness-engineering.md`: drop instinct/ECC mechanism sections;
  describe the new loop (reflect → queue → review → PR) and its operating rules.
- `CLAUDE.md`: replace the four old-system sections (Scheduled harness analysis /
  Autonomous pipeline / Continuous learning / Auto-promotion) with one section on the new
  system; update Common Commands.
- `.chezmoiignore`: add `.claude/harness/`.

### One-time migration

- Triage open `harness-analysis` issues: close #128 (verified fixed); transcribe #130 and
  #158 into `queue.md` as initial entries, then close them.
- Tell the user `~/.claude/homunculus/` can be deleted (do not auto-delete).
- Update the `harness-silent-failure-audit` memory after the rebuild lands.

## Error handling — mapping to old causes of death

| Old cause of death | Countermeasure |
|---|---|
| CI token expiry, 401 unnoticed for a month | No CI; local-only, no token |
| Gate skips passing as green | Briefing always prints; silence = dead hook, visibly |
| Observer dead with no symptoms | Zero resident LLM parts; hook is a deterministic append whose stderr surfaces in-session |
| "Pipeline: BROKEN" as undiagnosed permanent noise | Warnings carry cause + remediation command; only four warning kinds; permanent noise is itself queued as a bug |

Hook scripts follow the existing Exit Code Contract (`.claude/rules/shell-scripts.md`):
intentional skip = exit 0; error = exit 1 + stderr message.

## Testing

- New `make test-harness-scripts` smoke tests (following existing `test-*` patterns):
  - reflect-trigger: skips below turn threshold; appends one line above it; exits 0 on
    malformed stdin.
  - briefing: expected output for healthy / review-overdue / reflect-failing /
    missing-files states.
  - doctor: all-OK in a healthy fixture; detects unregistered hook in a broken fixture.
- New scripts covered by existing `make lint` (shellcheck, shfmt, check-templates).
- Skills (prompts) are not unit-tested; acceptance is one full manual cycle after landing:
  reflect → queue entry → review → PR created.

## Deliverables summary

| Kind | File | Role |
|---|---|---|
| skill | `dot_claude/skills/harness-reflect/SKILL.md` | extract learnings → queue |
| skill | `dot_claude/skills/harness-review/SKILL.md` | health check + triage → PR |
| script | `dot_claude/scripts/executable_harness-reflect-trigger.sh` | SessionEnd: record pending |
| script | `dot_claude/scripts/executable_harness-briefing.sh` | SessionStart: status/nudge |
| script | `dot_claude/scripts/executable_harness-doctor.sh` | deterministic liveness check |
| config | `settings.json.tmpl` hook wiring (2 hooks) | |
| tests | smoke tests + `test-harness-scripts` Makefile target | |

Moving parts: 2 skills, 3 deterministic scripts, 2 hook wirings — versus the old system's
4 skills + 6 commands + 3 workflows + observer + snapshot machinery.

## Out of scope

- Uninstalling the ECC plugin (in use for reviewers/MCP).
- Changes to `security-alerts.yml` or the security handling flow.
- Multi-machine sync of the runtime queue (single-machine assumption; revisit if needed).
