---
title: "fix: Allow claude[bot] to trigger harness-auto-remediate workflow"
type: fix
status: completed
date: 2026-03-30
---

# fix: Allow claude[bot] to trigger harness-auto-remediate workflow

## Overview

The `harness-auto-remediate.yml` workflow always skips when triggered by `harness-analysis` labeled issues because the sender (`claude[bot]`) has `author_association: NONE`, which is not in the allowed list.

## Problem Frame

The harness engineering pipeline has two workflows:
1. `harness-analysis.yml` — runs weekly via `claude-code-action`, creates issues with `harness-analysis` label. The label is applied by `claude[bot]`.
2. `harness-auto-remediate.yml` — triggers on `issues: [labeled]` event with `harness-analysis` label.

The auto-remediate workflow's `if` condition requires `github.event.sender.author_association` to be `OWNER`, `MEMBER`, or `COLLABORATOR`. Since `claude[bot]` is a GitHub App bot, its `author_association` is always `NONE`, causing the job to be unconditionally skipped.

This means the autonomous harness improvement pipeline is completely broken — no auto-remediation ever runs.

Evidence: https://github.com/tanimon/dotfiles/actions/runs/23712787643 (status: skipped, triggering_actor: claude[bot])

## Requirements Trace

- R1. `harness-auto-remediate` must run when `claude[bot]` applies the `harness-analysis` label
- R2. Security: external untrusted users must not be able to trigger remediation by labeling issues
- R3. The fix must not break `workflow_dispatch` manual trigger

## Scope Boundaries

- Only the `if` condition in `harness-auto-remediate.yml` needs to change
- No changes to `harness-analysis.yml` or any other workflow
- No changes to the remediation logic itself

## Context & Research

### Relevant Code and Patterns

Current condition in `.github/workflows/harness-auto-remediate.yml:16-20`:
```yaml
if: |
  (github.event_name == 'workflow_dispatch') ||
  (github.event_name == 'issues' &&
   github.event.label.name == 'harness-analysis' &&
   contains(fromJSON('["OWNER", "MEMBER", "COLLABORATOR"]'), github.event.sender.author_association))
```

### Institutional Learnings

- `~/.claude/rules/common/github-actions.md`: Always use `contains(fromJSON(...), ...)` for set-membership checks — the `in` operator does not exist in GitHub Actions expressions.

## Key Technical Decisions

- **Allow `claude[bot]` by login name, not by relaxing `author_association`**: Adding `NONE` to the allowed associations would permit any external user to trigger remediation by labeling an issue. Instead, add an explicit check for `github.event.sender.login == 'claude[bot]'`. This is the most secure and specific approach — it allows only the trusted bot while keeping the human sender check intact.

- **Use OR logic**: The condition becomes: (human with trusted association) OR (claude[bot] specifically). Both paths still require `github.event.label.name == 'harness-analysis'`.

## Open Questions

### Resolved During Planning

- **Why not check `sender.type == 'Bot'`?** — Too broad. Would allow any bot to trigger remediation. The `claude[bot]` login check is more precise.
- **Why not use a PAT instead of GITHUB_TOKEN?** — Overengineered for this use case. Would require secret management and changes to `harness-analysis.yml`.

### Deferred to Implementation

- None — this is a straightforward condition change.

## Implementation Units

- [ ] **Unit 1: Update `if` condition to allow `claude[bot]`**

**Goal:** Fix the `if` condition so that `claude[bot]` can trigger the remediate job.

**Requirements:** R1, R2, R3

**Dependencies:** None

**Files:**
- Modify: `.github/workflows/harness-auto-remediate.yml`

**Approach:**
- Add `github.event.sender.login == 'claude[bot]'` as an alternative to the `author_association` check
- Keep `github.event.label.name == 'harness-analysis'` as a shared requirement for both paths
- Preserve the `workflow_dispatch` path unchanged

**Target condition:**
```yaml
if: |
  (github.event_name == 'workflow_dispatch') ||
  (github.event_name == 'issues' &&
   github.event.label.name == 'harness-analysis' &&
   (contains(fromJSON('["OWNER", "MEMBER", "COLLABORATOR"]'), github.event.sender.author_association) ||
    github.event.sender.login == 'claude[bot]'))
```

**Patterns to follow:**
- Existing `contains(fromJSON(...))` pattern in the same file
- `~/.claude/rules/common/github-actions.md` for expression syntax

**Test scenarios:**
- Happy path: `claude[bot]` labels an issue with `harness-analysis` → job runs (not skipped)
- Happy path: OWNER/MEMBER/COLLABORATOR labels an issue with `harness-analysis` → job runs
- Happy path: `workflow_dispatch` with any user → job runs
- Edge case: External user (author_association=NONE, login != claude[bot]) labels with `harness-analysis` → job skipped

**Verification:**
- The YAML is valid and `make lint` passes
- Re-run the failed workflow or trigger a new `harness-analysis` issue to confirm the job executes

## System-Wide Impact

- **Interaction graph:** `harness-analysis.yml` creates issues → auto-remediate triggers on label. Only the trigger condition changes.
- **Error propagation:** No change — if the condition passes, all downstream steps remain identical.
- **Unchanged invariants:** The remediation logic, PR creation, high-risk comment flow, and permissions are all unchanged.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Bot login name changes | `claude[bot]` is the standard GitHub App bot login for `claude-code-action`. If the action changes its bot identity, the condition would need updating — but this is unlikely and would break many other workflows too. |

## Sources & References

- Failed run: https://github.com/tanimon/dotfiles/actions/runs/23712787643
- GitHub API verification: `claude[bot]` has `author_association: NONE` on all issues it creates
