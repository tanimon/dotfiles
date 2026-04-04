---
title: "feat: Add session-start deterministic learning injection"
type: feat
status: completed
date: 2026-04-04
origin: docs/brainstorms/2026-04-04-session-start-learning-injection-requirements.md
---

# feat: Add session-start deterministic learning injection

## Overview

Replace `harness-activator.sh` with a new `learning-briefing.sh` hook that injects pipeline health status and a broader range of instincts (>= 0.6 confidence) at session start. Simultaneously migrate `pipeline-health.sh` from `scripts/` (repo-only) to `dot_claude/scripts/` (single source of truth, deployed by chezmoi to `~/.claude/scripts/`).

## Problem Frame

The current harness-activator hook only shows instincts at >= 0.7 confidence and has no pipeline health awareness. The agent starts each session blind to whether the ECC observer is functioning. Near-promotion instincts (0.6-0.69) — patterns trending upward — are invisible. The `pipeline-health.sh` script implemented in #5 (PR #125) cannot be called from hooks because it lives in `scripts/` which is excluded from chezmoi deployment. (see origin: `docs/brainstorms/2026-04-04-session-start-learning-injection-requirements.md`)

## Requirements Trace

- R1. New hook script `executable_learning-briefing.sh` replaces `harness-activator.sh`
- R2. Pipeline health via `pipeline-health.sh --json` (deployed by chezmoi)
- R3. Instincts >= 0.6, showing domain, trigger, first line of body (action), confidence. Cap 15
- R4. CLAUDE.md check + compact evaluation reminder (always present)
- R5. ~600 token budget with soft per-section limits
- R6. Truncation with count indicator for instincts
- R7. Hook entry replacement in `settings.json.tmpl` with error-handling pattern
- R8. Existing behavior preserved with intentional threshold change (0.7 → 0.6)
- R9. `pipeline-health.sh` moved to `dot_claude/scripts/executable_pipeline-health.sh`
- R10. Makefile `test-pipeline-health` and `test-scripts` targets updated
- R11. Old files deleted, orphan target cleaned via `.chezmoiremove`
- R12-R14. Graceful degradation for missing health data, instincts, or all data

## Scope Boundaries

- Not implementing raw observation injection (instincts are higher signal)
- Not modifying ECC observer or instinct format
- Not adding LLM summarization in the hook
- Not changing the claudeception-activator hook entry

## Context & Research

### Relevant Code and Patterns

- `dot_claude/scripts/executable_harness-activator.sh` — canonical one-shot flag pattern, session_id extraction, instinct loading logic (lines 47-98)
- `dot_claude/settings.json.tmpl` — hook wiring at lines 203-219 (UserPromptSubmit) and 150-159 (SessionStart cleanup)
- `scripts/pipeline-health.sh` — 414-line health check with `--json` output, project discovery via git remote hash
- `Makefile` — `test-scripts` target (lines 115-169) tests harness-activator; `test-pipeline-health` (lines 172-228) tests pipeline-health.sh

### Institutional Learnings

- Hook exit code contract: `exit 0` for skip, `exit 1` + stderr for error (see `docs/solutions/integration-issues/claude-code-hook-exit-code-and-stderr-semantics.md`)
- One-shot flag: set AFTER context guards, not before (see `docs/solutions/developer-experience/autonomous-harness-engineering-hooks-2026-03-28.md`)
- ECC project ID: SHA256 of git remote URL, first 12 chars; instincts at `~/.claude/homunculus/projects/<hash>/instincts/personal/` (see `docs/solutions/integration-issues/ecc-continuous-learning-harness-integration-2026-04-03.md`)
- Instinct frontmatter fields: `id`, `trigger`, `confidence`, `domain`, `source`, `scope`, `project_id`. No `action:` field — the action description is the file body after `---`

## Key Technical Decisions

- **Instinct "action" is first line of file body** — ECC instinct YAML frontmatter has no `action:` field. The action description is the markdown body after the `---` delimiter. The briefing extracts the first non-empty line of the body as a compact action summary. Falls back to trigger-only display if body is empty. (Resolved from origin deferred question)
- **SessionStart cleanup pattern updated** — The flag file prefix changes from `claude-harness-checked-` to `claude-learning-briefing-` to match the new script name. The SessionStart hook cleanup command in `settings.json.tmpl` is updated accordingly.
- **`.chezmoiremove` for orphan target cleanup** — New file `.chezmoiremove` with exact target path `.claude/scripts/harness-activator.sh`. This is chezmoi's native mechanism for removing targets that no longer have source files. Exact path (no glob) avoids accidental removals. (Resolved from origin deferred question)
- **Evaluation reminder condensed** — The current 4-item reminder block (~200 tokens) is condensed to ~50 tokens with key skill references (`/propose-harness-improvement`, `/capture-harness-feedback`, `/ce:compound`). Full detail is removed since agents can discover skill documentation when needed.
- **pipeline-health.sh callable by path at runtime** — The hook invokes `"$HOME/.claude/scripts/pipeline-health.sh" --json` using the deployed path. No need for chezmoi source directory resolution.

## Open Questions

### Resolved During Planning

- **Instinct action field**: No `action:` in frontmatter. Use first line of body content.
- **Orphan cleanup mechanism**: `.chezmoiremove` with exact target path. New pattern for this repo but chezmoi-native and idempotent.
- **shellcheck/shfmt coverage**: `executable_*` glob in Makefile already covers `dot_claude/scripts/`.
- **CI impact**: Only Makefile paths need updating; `.github/workflows/lint.yml` job names reference `make` targets, not script paths directly.
- **Flag file prefix**: Changed to `claude-learning-briefing-` with SessionStart cleanup updated.

### Deferred to Implementation

- Exact token output with representative instinct data. Adjust instinct cap (15) if real-world output exceeds ~600 tokens.
- Whether the condensed evaluation reminder needs specific wording adjustments based on how agents respond to it.

## Implementation Units

> **Execution order:** Unit 1 → Unit 3 → Unit 2 → Unit 4 → Unit 5 (Unit 2 depends on Unit 3, so implement the hook script before updating tests)

- [x] **Unit 1: Migrate pipeline-health.sh to dot_claude/scripts/**

**Goal:** Move `pipeline-health.sh` from `scripts/` to `dot_claude/scripts/executable_pipeline-health.sh` as single source of truth, deployed by chezmoi to `~/.claude/scripts/pipeline-health.sh`.

**Requirements:** R9

**Dependencies:** None

**Files:**
- Create: `dot_claude/scripts/executable_pipeline-health.sh` (moved from `scripts/pipeline-health.sh`)
- Delete: `scripts/pipeline-health.sh`

**Approach:**
- Copy `scripts/pipeline-health.sh` content to `dot_claude/scripts/executable_pipeline-health.sh`
- The `executable_` prefix ensures chezmoi sets the execute bit on the deployed target
- The script content is unchanged — only the source location moves
- chezmoi deploys to `~/.claude/scripts/pipeline-health.sh` (strips `executable_` prefix, preserves `.sh`)

**Patterns to follow:**
- `dot_claude/scripts/executable_harness-activator.sh` for naming convention

**Test scenarios:**
- Happy path: `dot_claude/scripts/executable_pipeline-health.sh --help` exits 0 and shows usage
- Happy path: `dot_claude/scripts/executable_pipeline-health.sh --json` produces valid JSON (same test as current)
- Edge case: script passes shellcheck and shfmt (verify glob picks it up)

**Verification:**
- `dot_claude/scripts/executable_pipeline-health.sh` exists with identical content to old `scripts/pipeline-health.sh`
- `scripts/pipeline-health.sh` is deleted
- `make shellcheck` and `make shfmt` pass (new path auto-discovered)

---

- [x] **Unit 2: Update Makefile test targets**

**Goal:** Update `test-pipeline-health` to reference the new path and `test-scripts` to test `learning-briefing.sh` instead of `harness-activator.sh`.

**Requirements:** R10

**Dependencies:** Unit 1 (pipeline-health.sh at new path), Unit 3 (learning-briefing.sh exists)

**Files:**
- Modify: `Makefile`

**Approach:**
- `test-pipeline-health`: Change `scripts/pipeline-health.sh` to `dot_claude/scripts/executable_pipeline-health.sh`
- `test-scripts`: Replace harness-activator tests with learning-briefing tests:
  - Test 1: script is executable with correct shebang
  - Test 2: normal execution outputs "Learning Pipeline" or "ECC Learning" section header
  - Test 3: HOME directory guard (should suppress output)
  - Test 4: duplicate session_id idempotency (second invocation suppressed by flag file)
- Update `.PHONY` if any target names change

**Patterns to follow:**
- Current `test-pipeline-health` structure (lines 172-228) for path-based testing
- Current `test-scripts` structure (lines 115-169) for hook behavior testing

**Test scenarios:**
- Happy path: `make test-pipeline-health` passes with new script path
- Happy path: `make test-scripts` passes with learning-briefing.sh tests
- Edge case: both targets pass in CI (no `~/.claude/homunculus/` data — graceful degradation)

**Verification:**
- `make lint` passes with all updated targets
- CI `pipeline-health` and `harness-scripts` jobs pass

---

- [x] **Unit 3: Create learning-briefing.sh**

**Goal:** Create the new session-start hook script that outputs pipeline health, instincts >= 0.6, CLAUDE.md check, and a compact evaluation reminder.

**Requirements:** R1, R2, R3, R4, R5, R6, R8, R12, R13, R14

**Dependencies:** Unit 1 (pipeline-health.sh at deployed path)

**Files:**
- Create: `dot_claude/scripts/executable_learning-briefing.sh`
- Test: `Makefile` `test-scripts` target (updated in Unit 2)

**Approach:**
- Script header: `#!/usr/bin/env bash` + `set -euo pipefail`
- Read stdin JSON immediately, extract `session_id` via `jq -r '.session_id // empty'`
- One-shot flag: `/tmp/claude-learning-briefing-${SESSION_ID}`, checked early, touched AFTER context guards
- Context guards: HOME exclusion, `.claude` dir exclusion, git repo check (same pattern as harness-activator)
- **Pipeline health section**: Invoke `"$HOME/.claude/scripts/pipeline-health.sh" --json 2>/dev/null || true`, extract `overall_status` via jq. If healthy: one line "Pipeline: healthy". If broken: one line listing broken stages. If unavailable: skip silently
- **Instincts section**: Discover project ID (git remote URL hash, same as harness-activator). Iterate `instincts/personal/*.{md,yaml,yml}`, extract `confidence`, `trigger`, `domain` from frontmatter and first non-empty body line as action. Filter >= 0.6 confidence. Sort by confidence descending. Cap at 15. Truncate with "... and N more" if needed
- **CLAUDE.md check**: Same as harness-activator (warn if missing, suggest `/scaffold-claude-md`)
- **Compact evaluation reminder**: Condensed to ~50 tokens referencing `/propose-harness-improvement`, `/capture-harness-feedback`, `/ce:compound`
- Output all sections to stdout within ~600 token target

**Patterns to follow:**
- `dot_claude/scripts/executable_harness-activator.sh` for one-shot flag, session_id extraction, project ID discovery, instinct file iteration
- `scripts/pipeline-health.sh` for `shasum`/`sha256sum` cross-platform pattern

**Test scenarios:**
- Happy path: script runs without error in a git project context and outputs "Learning Pipeline" header
- Happy path: with instinct files present and confidence >= 0.6, instinct section lists domain/trigger/action/confidence
- Happy path: pipeline health section shows "healthy" or "broken" status
- Edge case: no `~/.claude/homunculus/` directory — outputs CLAUDE.md check + reminder only (R14 fallback)
- Edge case: no instinct files meeting >= 0.6 threshold — instincts section skipped
- Edge case: pipeline-health.sh not available — health section skipped silently
- Edge case: HOME directory context — exits 0 silently (one-shot flag NOT consumed)
- Edge case: duplicate session_id — second invocation exits 0 (one-shot flag prevents re-fire)
- Error path: jq not available — exits 0 (graceful skip)
- Error path: instinct file with malformed YAML frontmatter — skipped, doesn't break iteration
- Integration: combined output fits within ~600 token estimate (verify with real or synthetic data)

**Verification:**
- Script passes shellcheck and shfmt (`make shellcheck`, `make shfmt`)
- `make test-scripts` passes
- Manual test: running in this repo shows pipeline health status and any available instincts

---

- [x] **Unit 4: Update settings.json.tmpl hook wiring**

**Goal:** Replace the harness-activator hook entry with learning-briefing.sh and update the SessionStart cleanup pattern.

**Requirements:** R7

**Dependencies:** Unit 3 (learning-briefing.sh exists)

**Files:**
- Modify: `dot_claude/settings.json.tmpl`

**Approach:**
- **UserPromptSubmit hooks** (line ~216): Replace `harness-activator.sh` with `learning-briefing.sh` in the `bash -c` wrapper, preserving stderr redirect and `|| true`:
  ```
  "command": "bash -c '\"$HOME/.claude/scripts/learning-briefing.sh\" 2>>\"$HOME/.claude/logs/harness-errors.log\" || true'"
  ```
- **SessionStart cleanup** (line ~156): Update cleanup to handle both old and new flag patterns during transition: `find /tmp -maxdepth 1 \( -name "claude-learning-briefing-*" -o -name "claude-harness-checked-*" \) -mtime +0 -delete`. The old pattern can be removed after a few weeks
- Leave claudeception-activator entry completely unchanged

**Patterns to follow:**
- Existing hook entry format in `settings.json.tmpl` lines 203-219

**Test scenarios:**
- Happy path: `chezmoi execute-template` validates the template renders valid JSON
- Happy path: deployed `~/.claude/settings.json` has updated hook command after `chezmoi apply`
- Edge case: claudeception-activator entry preserved exactly as-is
- Integration: `make check-templates` passes

**Verification:**
- Template renders valid JSON
- `make check-templates` passes
- Hook command references `learning-briefing.sh`, not `harness-activator.sh`

---

- [x] **Unit 5: Create .chezmoiremove and delete old source files**

**Goal:** Clean up old files: delete `harness-activator.sh` source and handle orphan target at `~/.claude/scripts/harness-activator.sh`.

**Requirements:** R11

**Dependencies:** Unit 3, Unit 4 (new script exists and is wired)

**Files:**
- Create: `.chezmoiremove`
- Modify: `.chezmoiignore` (add `.chezmoiremove` entry)
- Delete: `dot_claude/scripts/executable_harness-activator.sh`

**Approach:**
- Create `.chezmoiremove` with a single line: `.claude/scripts/harness-activator.sh`
- This is a target path (not source path). chezmoi will delete `~/.claude/scripts/harness-activator.sh` on next `chezmoi apply`
- Delete the source file `dot_claude/scripts/executable_harness-activator.sh`
- Add `.chezmoiremove` to `.chezmoiignore` so the file itself doesn't deploy to `~/` (it's a chezmoi control file, not a target file)

**Patterns to follow:**
- chezmoi documentation for `.chezmoiremove` (exact target paths, no globs for safety)

**Test scenarios:**
- Happy path: `chezmoi managed` no longer lists `.claude/scripts/harness-activator.sh` as a managed target
- Happy path: `chezmoi apply --dry-run` shows removal of the orphan target
- Edge case: `.chezmoiremove` only contains the one exact path (no glob that could catch other files)
- Edge case: `.chezmoiremove` itself does not appear in chezmoi managed output

**Verification:**
- `dot_claude/scripts/executable_harness-activator.sh` no longer exists in source
- `chezmoi apply --dry-run` confirms target removal
- No other targets are affected by `.chezmoiremove`

## System-Wide Impact

- **Interaction graph:** The new hook calls `pipeline-health.sh` as a subprocess and reads instinct files from `~/.claude/homunculus/`. Both are read-only operations. No interaction with Claude Code sessions, ECC observer, or other hooks. The claudeception-activator hook fires independently on the same `UserPromptSubmit` event.
- **Error propagation:** All failures are swallowed silently (`|| true` wrapper in settings.json.tmpl, internal `|| true` guards). The hook never causes a user-visible error — worst case is no briefing output.
- **State lifecycle risks:** The one-shot flag file `/tmp/claude-learning-briefing-*` is session-scoped and cleaned up by the SessionStart hook. Stale flags (> 1 day) are cleaned by the `find -mtime +0 -delete` pattern.
- **Unchanged invariants:** The claudeception-activator hook is not modified. ECC observer configuration (`CLV2_CONFIG`, `continuous-learning-config.json`) is not modified. The `--json` output format of `pipeline-health.sh` is preserved exactly.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| No instinct files exist yet (observer is broken) | Graceful degradation (R13/R14). Health section surfaces the broken observer. Instincts section skips silently. |
| Token budget ~600 is still an estimate | Soft target. Implementation validates with real/synthetic data. Instinct cap (15) is the primary knob. |
| `.chezmoiremove` is a new pattern for this repo | Using exact target path (no glob). Minimal risk of accidental removal. |
| `pipeline-health.sh` path change affects CI | Only Makefile path reference changes. CI jobs call `make` targets, not scripts directly. |
| SessionStart cleanup pattern change | Old flag files (`claude-harness-checked-*`) will be cleaned by the updated pattern on the next session after `chezmoi apply`. Stale old flags are harmless (one-shot check passes through). |

## Sources & References

- **Origin document:** [docs/brainstorms/2026-04-04-session-start-learning-injection-requirements.md](docs/brainstorms/2026-04-04-session-start-learning-injection-requirements.md)
- Predecessor script: `dot_claude/scripts/executable_harness-activator.sh`
- Pipeline health monitor: `scripts/pipeline-health.sh` (PR #125)
- Hook exit code semantics: `docs/solutions/integration-issues/claude-code-hook-exit-code-and-stderr-semantics.md`
- Autonomous harness hooks: `docs/solutions/developer-experience/autonomous-harness-engineering-hooks-2026-03-28.md`
- ECC integration: `docs/solutions/integration-issues/ecc-continuous-learning-harness-integration-2026-04-03.md`
