---
title: "feat: Auto-promote ECC instincts to harness rules (Closed-Loop v1)"
type: feat
status: active
date: 2026-04-05
origin: docs/brainstorms/2026-04-04-closed-loop-rule-lifecycle-requirements.md
---

# feat: Auto-promote ECC instincts to harness rules (Closed-Loop v1)

## Overview

Implement Phase 1 of the Closed-Loop Rule Lifecycle: automated promotion of high-confidence ECC instincts to permanent harness rules via weekly CI. This eliminates the manual `/promote-instincts` invocation while preserving generator-evaluator separation through the existing propose/validate/apply pipeline.

## Problem Frame

ECC instincts accumulate from session observations but require manual `/promote-instincts` to become permanent rules. This bridge is invoked infrequently, meaning valuable learned patterns remain as low-persistence instincts that decay over time instead of becoming durable rules. Phase 1 automates the instinct-to-rule promotion path; Phase 2 (effectiveness measurement and auto-demotion) is deferred until 10+ auto-promoted rules exist. (see origin: `docs/brainstorms/2026-04-04-closed-loop-rule-lifecycle-requirements.md`)

## Requirements Trace

- R1. Snapshot instinct data from `~/.claude/homunculus/` to chezmoi source tree for CI access
- R2. Snapshot committed manually (not `run_onchange_`), excluded from deployment via `.chezmoiignore`
- R3. Weekly CI identifies candidates (confidence >= 0.7, population >= 5)
- R4. Dedup against existing rules + domain filtering (exclude debugging meta-instincts)
- R5. Candidates go through propose→validate→apply pipeline (non-interactive CI)
- R6. Risk tiering: `code-style`/`file-patterns` auto-apply; others create PR
- R7. Rule format: `## <trigger>` section with `_Promoted from ECC instinct <id>_` metadata
- R16. `$GITHUB_STEP_SUMMARY` with promotion stats
- R18. Health gate on snapshot data (freshness, count >= 5, format validation)

## Scope Boundaries

- Phase 2 (R8-R15, R17: effectiveness measurement, auto-demotion) is NOT in scope
- No changes to ECC observer or `/promote-instincts` command
- No real-time promotion triggers — weekly batch only
- Cross-project instinct federation is NOT in scope
- Global instinct promotion is NOT in scope (project instincts only; manual `/promote-instincts` handles global)

## Context & Research

### Relevant Code and Patterns

- `scripts/update-marketplaces.sh` — runtime→source sync pattern (tool guard, extract, sort, write)
- `scripts/update-gh-extensions.sh` — same pattern
- `.github/workflows/harness-auto-remediate.yml` — model for `claude-code-action` CI with write permissions
- `.github/workflows/harness-analysis.yml` — weekly schedule pattern
- `dot_claude/commands/apply-harness-proposal.md` — apply command (accepts structured proposals)
- `.claude/commands/promote-instincts.md` — existing manual promote (reference for candidate selection logic)
- `dot_claude/scripts/executable_pipeline-health.sh` — project hash discovery pattern (lines 46-97)
- `Makefile` target `test-pipeline-health` — test pattern for new script tests
- `claude-code-action` SHA: `58dbe8ed6879f0d3b02ac295b20d5fdfe7733e0c # v1.0.85`

### Institutional Learnings

- **chezmoi scripts/ deployment gap** (`docs/solutions/integration-issues/chezmoi-scripts-deployment-gap-repo-only-vs-deployed-2026-04-04.md`): `scripts/` is repo-only (excluded by `.chezmoiignore`). Snapshot script lives here since it's only called locally, not from deployed hooks.
- **GitHub Actions bot author_association** (`docs/solutions/integration-issues/github-actions-bot-author-association-bypass-2026-03-30.md`): Bot-created events have `author_association: NONE`. If workflow triggers on labeled issues, explicitly allowlist `claude[bot]`.
- **claude-code-action v1 parameters** (`docs/solutions/integration-issues/claude-code-action-v1-parameter-migration-2026-03-29.md`): Use `prompt` (not `direct_prompt`), `claude_args` for `--allowedTools`.
- **Workflow tool permissions** (`docs/solutions/integration-issues/claude-code-review-workflow-tool-permissions-2026-03-29.md`): Two-layer permission model — both GitHub Actions `permissions:` and Claude Code `allowedTools` must be configured.
- **Invalid webhook triggers** (`docs/solutions/integration-issues/github-actions-invalid-webhook-event-triggers-2026-04-03.md`): Verify new workflow produces at least one job after first push.
- **Makefile test pitfall** (`docs/solutions/developer-experience/autonomous-harness-engineering-hooks-2026-03-28.md`): `; true` makes tests always pass. Use explicit exit code checks.

## Key Technical Decisions

- **Snapshot format: full instinct .md files + metadata.json** — CI needs YAML frontmatter access for filtering (R3-R4) and format validation (R18). Summary JSON would lose evidence/action text needed for LLM-based dedup. `metadata.json` records snapshot timestamp and project hash.
- **New workflow (not extending harness-analysis.yml)** — Different permission requirements (`contents: write` vs `read`), different trigger semantics (schedule + manual dispatch, not issue-labeled). Follows separation of concerns.
- **LLM-based dedup via claude-code-action** — Instinct triggers are free-text natural language; rules are markdown sections. Deterministic keyword matching would be fragile. The claude-code-action prompt reads both snapshot and existing rules, then judges similarity. This mirrors the manual `/promote-instincts` approach (Step 2: search for matching patterns).
- **claude-code-action inline prompt** — Same pattern as `harness-auto-remediate.yml`. The entire promotion pipeline (filter → dedup → classify risk → format rule → apply) is embedded as a structured prompt. **Generator-evaluator compromise**: true separation (two independent LLM sessions) is ideal but impractical in a single workflow step. The v1 compromise: the LLM validates its own proposals within the session, with high-risk promotions always going through PR review as the real human-in-the-loop gate. This is acknowledged as weaker than true separation but acceptable for a system that only adds rules (never modifies existing behavior).
- **Atomic commit for promoted rules** — All promotions within a single CI run are collected first, then committed in one atomic operation. This prevents partial state if claude-code-action fails mid-execution.
- **Snapshot location: `dot_claude/instinct-snapshots/`** — Under `dot_claude/` for consistency with other Claude-related config. Added to `.chezmoiignore` (target path `.claude/instinct-snapshots`) to prevent deployment to `~/`.
- **Snapshot is a manual local step** — The snapshot script must be run locally before CI can process instincts. This is intentional (same as marketplace/extension sync), documented in CLAUDE.md, and bounded by the 14-day freshness gate. A stale snapshot causes CI to skip (not produce wrong results).
- **Project instincts only in v1** — Global instincts at `~/.claude/homunculus/instincts/personal/` are not included in the snapshot. Manual `/promote-instincts` continues to handle global instincts.

## Open Questions

### Resolved During Planning

- **CI workflow structure**: New `auto-promote.yml` — different permissions and concerns than harness-analysis
- **Snapshot format**: Full .md files + metadata.json — CI needs frontmatter for filtering
- **Pipeline CI integration**: claude-code-action inline prompt (same as harness-auto-remediate.yml)
- **Dedup approach**: LLM-based — claude-code-action reads snapshot + rules, judges similarity
- **Snapshot timestamp**: `metadata.json` file with ISO timestamp, project hash, instinct count

### Deferred to Implementation

- Exact LLM prompt wording for dedup and promotion — depends on testing with real instinct data
- Whether `validate-harness-proposal` skill can be reliably invoked from within a claude-code-action session — may need to inline validation logic instead
- Metadata comment format string: `_Promoted from ECC instinct <id> on <date> (confidence: <score>)_` — exact pipe-delimited extension for v2 status tracking is deferred to Phase 2

## Implementation Units

- [ ] **Unit 1: Snapshot Script**

**Goal:** Create `scripts/snapshot-instincts.sh` that copies instinct data from local ECC storage to the chezmoi source tree.

**Requirements:** R1, R2

**Dependencies:** None

**Files:**
- Create: `scripts/snapshot-instincts.sh`
- Create: `dot_claude/instinct-snapshots/` (directory, initially empty)
- Test: via Makefile target (Unit 4)

**Approach:**
- Follow `scripts/update-marketplaces.sh` template: tool guard → detect project → copy data → write metadata → print summary
- Discover project hash using the same logic as `pipeline-health.sh` (git remote URL → SHA256 → first 12 chars)
- Copy all `.md` files from `~/.claude/homunculus/projects/<hash>/instincts/personal/` to `dot_claude/instinct-snapshots/`
- Write `dot_claude/instinct-snapshots/metadata.json` with: `{"timestamp": "ISO-8601", "project_id": "<hash>", "project_name": "<name>", "instinct_count": N}`
- Validate each copied instinct has required frontmatter fields (`id`, `trigger`, `confidence`, `domain`) — skip invalid files with warning
- Guard: `jq` required (for metadata.json), `git` required (for project detection), `shasum` or `sha256sum` required

**Patterns to follow:**
- `scripts/update-marketplaces.sh` — sync template
- `dot_claude/scripts/executable_pipeline-health.sh` lines 46-97 — project hash discovery

**Test scenarios:**
- Happy path: Given instinct files at expected path, snapshot copies them to `dot_claude/instinct-snapshots/` and writes valid `metadata.json`
- Happy path: `metadata.json` contains correct instinct count matching copied files
- Edge case: No instinct directory exists → script exits 0 with warning message
- Edge case: Instinct files with missing frontmatter fields → skipped with warning, not copied
- Edge case: Empty instinct directory → exits 0 with warning, metadata.json has count 0
- Error path: `jq` not available → exits 0 with warning (same as other sync scripts)

**Verification:**
- Running `scripts/snapshot-instincts.sh` from the repo root produces files in `dot_claude/instinct-snapshots/`
- `metadata.json` is valid JSON with required fields
- Invalid instinct files are not copied

---

- [ ] **Unit 2: .chezmoiignore + CI boilerplate**

**Goal:** Exclude snapshot directory from deployment and set up the CI workflow skeleton.

**Requirements:** R2, R3 (partial — workflow structure)

**Dependencies:** Unit 1 (snapshot directory exists)

**Files:**
- Modify: `.chezmoiignore`
- Create: `.github/workflows/auto-promote.yml`

**Approach:**
- Add `.claude/instinct-snapshots` to `.chezmoiignore` (target path, not source path — `.chezmoiignore` evaluates target paths; `dot_claude/instinct-snapshots/` in source maps to `.claude/instinct-snapshots/` as target)
- Create workflow with: `schedule: cron '0 1 * * 0'` (Sunday 01:00 UTC, offset from harness-analysis at 00:00), `workflow_dispatch` for manual trigger
- Permissions: `contents: write`, `pull-requests: write`, `issues: write`, `id-token: write`
- Concurrency: `group: auto-promote`, `cancel-in-progress: false`
- Checkout with `persist-credentials: false`, setup node from `.node-version`
- `timeout-minutes: 30` (prevent claude-code-action hangs)
- Pin `claude-code-action` to same SHA as other workflows (`58dbe8ed6879f0d3b02ac295b20d5fdfe7733e0c`)

**Patterns to follow:**
- `harness-auto-remediate.yml` — permissions, claude-code-action usage
- `harness-analysis.yml` — schedule cron pattern
- All workflows — SHA pinning, `persist-credentials: false`, node-version-file

**Test scenarios:**
- Happy path: `actionlint` and `zizmor` pass on the new workflow file
- Edge case: `chezmoi managed | grep instinct-snapshots` returns nothing (excluded by `.chezmoiignore` target path `.claude/instinct-snapshots`)

**Verification:**
- `make actionlint` passes
- `make zizmor` passes
- `.chezmoiignore` entry prevents snapshot deployment

---

- [ ] **Unit 3: Health Gate Logic**

**Goal:** Implement snapshot validation as a shell script that the CI workflow calls before promotion.

**Requirements:** R18

**Dependencies:** Unit 1 (snapshot format defined)

**Files:**
- Create: `scripts/validate-instinct-snapshot.sh`
- Test: via Makefile target (Unit 4)

**Approach:**
- Standalone shell script (testable outside CI) that validates snapshot data
- Checks: (a) `metadata.json` exists and has `timestamp` field, (b) timestamp within 14 days of current date, (c) instinct count >= 5 (from metadata.json and verified against actual file count), (d) each instinct .md has required frontmatter fields (`id`, `trigger`, `confidence`, `domain`)
- Exit 0 with JSON output on success: `{"status": "ok", "instinct_count": N, "snapshot_age_days": N}`
- Exit 1 with JSON output on failure: `{"status": "failed", "reason": "..."}`
- CI workflow calls this script first; if exit != 0, skips promotion and writes reason to step summary

**Patterns to follow:**
- `dot_claude/scripts/executable_pipeline-health.sh` — JSON output mode, health check structure

**Test scenarios:**
- Happy path: Valid snapshot with 5+ instincts and fresh timestamp → exit 0 with `"status": "ok"`
- Edge case: Missing `metadata.json` → exit 1 with reason "no metadata.json"
- Edge case: Stale timestamp (> 14 days old) → exit 1 with reason "snapshot stale"
- Edge case: Count < 5 → exit 1 with reason "insufficient instincts (N < 5)"
- Edge case: Instinct file missing required frontmatter → exit 1 with reason listing invalid files
- Edge case: metadata.json count doesn't match actual file count → exit 1 with reason "count mismatch"

**Verification:**
- Script produces valid JSON on both success and failure paths
- All gate conditions are enforced

---

- [ ] **Unit 4: Makefile Test Targets**

**Goal:** Add test targets for snapshot and validation scripts, integrated with `make lint`.

**Requirements:** Supports R1, R18 testability

**Dependencies:** Unit 1, Unit 3

**Files:**
- Modify: `Makefile`

**Approach:**
- Add `test-snapshot-instincts` target: creates temp dir with mock instinct files, runs `snapshot-instincts.sh`, validates output
- Add `test-validate-snapshot` target: creates temp snapshots (valid, stale, incomplete), runs `validate-instinct-snapshot.sh`, checks exit codes and JSON output
- Add both to the `test-scripts` dependency chain (or create a separate `test-auto-promote` target added to `lint`). Ensure new targets are also added to `lint.yml` CI jobs for parity with local `make lint`
- Follow `test-pipeline-health` pattern: numbered tests, PASS/FAIL output, explicit exit code checks (not `; true`)
- Both scripts should appear in `SHELL_FILES` glob for shellcheck/shfmt

**Patterns to follow:**
- `Makefile` target `test-pipeline-health` — test structure
- Institutional learning: avoid `; true` in Makefile tests

**Test scenarios:**
- Happy path: `make test-snapshot-instincts` passes with mock data
- Happy path: `make test-validate-snapshot` passes all validation cases
- Integration: `make lint` includes the new test targets

**Verification:**
- `make lint` passes including new targets
- Both scripts pass shellcheck and shfmt

---

- [ ] **Unit 5: CI Workflow Promotion Prompt**

**Goal:** Implement the claude-code-action prompt that reads snapshots, filters candidates, and promotes instincts to rules.

**Requirements:** R3, R4, R5, R6, R7, R16

**Dependencies:** Unit 2 (workflow skeleton), Unit 3 (health gate)

**Files:**
- Modify: `.github/workflows/auto-promote.yml`

**Approach:**
- Workflow steps: (1) checkout, (2) run `scripts/validate-instinct-snapshot.sh`, (3) if health gate passes, run `claude-code-action` with promotion prompt
- The promotion prompt instructs the LLM agent to:
  1. Read all instinct files in `dot_claude/instinct-snapshots/`
  2. Filter: confidence >= 0.7, exclude domain=debugging with observer-referencing triggers
  3. Read existing rules in `.claude/rules/` and `dot_claude/rules/` for dedup
  4. For each candidate: assess similarity to existing rules (LLM judgment, not keyword matching)
  5. Classify risk: domain `code-style` or `file-patterns` → low-risk (auto-apply); others → high-risk (PR)
  6. Format promoted rule: `## <trigger>` section with metadata comment (R7 format)
  7. Write to appropriate rule file (project `.claude/rules/` or global `dot_claude/rules/common/`)
  8. Collect all promotion results (rule text, target file, risk tier) without committing yet
  9. After all candidates processed: atomic commit for low-risk rules with message `chore(harness): auto-promote instincts [ids]`
  10. For high-risk: create branch `feat/auto-promote-<id>` and PR
  11. Write `$GITHUB_STEP_SUMMARY` with stats (R16)
- `claude_args`: `--allowedTools "Read,Write,Bash(git add:*),Bash(git commit:*),Bash(git push:*),Bash(git checkout:*),Bash(gh pr create:*),Bash(gh issue list:*),Edit"`
- Generator-evaluator separation: the prompt instructs the agent to validate each promotion against existing rules and the project's CLAUDE.md before applying

**Execution note:** This unit requires iterative testing with the actual CI workflow. Start with `workflow_dispatch` to test manually before relying on the weekly schedule.

**Patterns to follow:**
- `harness-auto-remediate.yml` — inline prompt structure, claude_args pattern
- `promote-instincts.md` — candidate selection logic (Step 2: dedup, Step 4: rule format)

**Test scenarios:**
- Happy path: Workflow runs on dispatch, reads valid snapshot, identifies candidates, produces step summary
- Happy path: Low-risk candidate (domain=code-style) → committed directly
- Happy path: High-risk candidate (domain=workflow) → PR created
- Edge case: Health gate fails → workflow skips promotion, step summary explains why
- Edge case: All candidates already covered by existing rules → step summary says "0 promoted (all duplicates)"
- Edge case: No candidates at confidence >= 0.7 → step summary says "0 candidates"
- Error path: claude-code-action timeout → workflow fails within timeout-minutes limit
- Integration: Promoted rule has correct `_Promoted from ECC instinct_` metadata format

**Verification:**
- `workflow_dispatch` trigger produces a successful run with step summary
- Promoted rules appear in the correct location with correct format
- `make lint` still passes after promotion (shellcheck, shfmt, actionlint all pass)

---

- [ ] **Unit 6: Documentation Updates**

**Goal:** Update ideation doc and CLAUDE.md with new feature documentation.

**Requirements:** Documentation completeness

**Dependencies:** Units 1-5

**Files:**
- Modify: `docs/ideation/2026-04-04-autonomous-harness-evolution-ideation.md`
- Modify: `CLAUDE.md` (if needed — snapshot script usage, new workflow reference)

**Approach:**
- Update ideation doc session log with implementation entry for #1 Phase 1
- Update #1 status from "Explored" to "Partially implemented (v1)"
- Add snapshot script usage to CLAUDE.md common commands section if appropriate
- Reference the new workflow in the "Scheduled harness analysis" or similar section of CLAUDE.md

**Test expectation:** none — documentation only

**Verification:**
- Ideation doc accurately reflects current state
- `make scan-sensitive` passes (no PII in docs)

## System-Wide Impact

- **Interaction graph:** Snapshot script reads `~/.claude/homunculus/` (ECC runtime state). CI workflow reads snapshot files and writes to `.claude/rules/` and `dot_claude/rules/`. Changes to rule files affect all future Claude Code sessions (rules are loaded at session start).
- **Error propagation:** Health gate (Unit 3) prevents promotion when snapshot is invalid. CI workflow timeout prevents hangs. `|| true` fallback on snapshot script (matches sync script convention).
- **State lifecycle risks:** Snapshot can become stale if user forgets to re-run. 14-day freshness check (R18) bounds staleness. Promoted rules persist permanently (no auto-cleanup in v1).
- **API surface parity:** No API changes. The manual `/promote-instincts` command remains unchanged — two independent promotion paths.
- **Unchanged invariants:** Manual rules in `.claude/rules/` and `dot_claude/rules/` are never modified by auto-promotion. CLAUDE.md content is never auto-modified. ECC observer behavior is unchanged.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| ECC observer plugin update overwrites local patches → instinct generation stops | R18 health gate skips promotion when snapshot is stale; pipeline-health.sh detects broken observer |
| ECC instinct format changes silently | Snapshot validation (Unit 3) checks required frontmatter fields; format drift detected early |
| LLM-based dedup is non-deterministic | Prompt includes explicit dedup criteria; high-risk candidates always go through PR review |
| Snapshot becomes stale (user forgets to update) | 14-day freshness check; workflow logs warning in step summary |
| claude-code-action hangs or produces unexpected output | 30-minute timeout; concurrency group prevents parallel runs |
| Auto-promoted rule is low quality | High-risk promotions go through PR review (human gate); low-risk auto-commits are identifiable by commit message for revert if needed |
| Partial state on claude-code-action failure | Atomic commit pattern: all promotions collected first, committed once at end |

## Sources & References

- **Origin document:** [docs/brainstorms/2026-04-04-closed-loop-rule-lifecycle-requirements.md](docs/brainstorms/2026-04-04-closed-loop-rule-lifecycle-requirements.md)
- Related: `scripts/update-marketplaces.sh` (sync pattern)
- Related: `.github/workflows/harness-auto-remediate.yml` (CI claude-code-action pattern)
- Related: `.claude/commands/promote-instincts.md` (manual promotion reference)
- Related: PR #125 (pipeline health monitor), PR #126 (session-start injection)
- Learnings: `docs/solutions/integration-issues/claude-code-action-v1-parameter-migration-2026-03-29.md`
- Learnings: `docs/solutions/integration-issues/github-actions-bot-author-association-bypass-2026-03-30.md`
- Learnings: `docs/solutions/integration-issues/chezmoi-scripts-deployment-gap-repo-only-vs-deployed-2026-04-04.md`
