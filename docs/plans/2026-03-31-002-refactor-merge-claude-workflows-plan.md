---
title: "refactor: Merge claude-code-review.yml into claude.yml"
type: refactor
status: completed
date: 2026-03-31
---

# refactor: Merge claude-code-review.yml into claude.yml

## Overview

Consolidate two separate Claude Code Action workflows (`claude.yml` and `claude-code-review.yml`) into a single workflow. The review functionality will be triggered when a comment contains both `@claude` and `/review`, eliminating the need for a separate workflow file.

## Problem Frame

Two workflows share the same action (`anthropics/claude-code-action`), same permissions, same checkout step, and same OAuth token. The only difference is the review workflow adds plugin configuration and a custom prompt. Maintaining two nearly identical files creates unnecessary duplication and potential drift. A single workflow with conditional steps is simpler and more maintainable.

## Requirements Trace

- R1. `@claude` mentions without `/review` must continue to work exactly as before (no behavior regression)
- R2. `@claude /review` on a PR comment triggers the code review plugin with the existing review configuration
- R3. `/review` without `@claude` no longer triggers review (intentional behavior change — user confirmed this is acceptable)
- R4. `claude-code-review.yml` is deleted after consolidation
- R5. All review-specific settings are preserved: `allowed_bots`, `show_full_output`, `classify_inline_comments`, `claude_args`, `plugin_marketplaces`, `plugins`, `prompt`

## Scope Boundaries

- No changes to `harness-analysis.yml`, `harness-auto-remediate.yml`, or `lint.yml`
- No changes to the action version SHA or permissions
- No new features — this is pure consolidation

## Context & Research

### Relevant Code and Patterns

- `.github/workflows/claude.yml` — current general-purpose workflow (L1-48)
- `.github/workflows/claude-code-review.yml` — current review-only workflow (L1-42)
- All workflows pin actions to full commit SHAs (repo convention per `~/.claude/rules/common/github-actions.md`)
- `harness-auto-remediate.yml` uses `claude-code-action` with similar patterns

### Institutional Learnings

- `CLAUDE.md` documents: "Verify GitHub Actions template output — workflows generated from templates default to read-only permissions"
- `~/.claude/rules/common/github-actions.md`: Use `contains(fromJSON(...), ...)` for set-membership checks, pin SHAs

## Key Technical Decisions

- **Two conditional steps over environment variables**: Use step-level `if` conditions to select between normal and review mode, rather than environment variable interpolation. Step-level conditions are more readable, easier to debug, and align with how `harness-analysis.yml` structures its logic. Each step has its own clear `with:` block.
- **Review detection scope**: Check for `/review` in all event types that carry a body (issue_comment, pull_request_review_comment, pull_request_review), but only when the event is on a PR. For `issues` events, `/review` is meaningless — always use normal mode.
- **Behavior change for standalone `/review`**: Currently `claude-code-review.yml` triggers on `/review` alone (no `@claude` required). After merge, `@claude /review` is required. This simplifies the trigger model and was confirmed acceptable by the user.

## Open Questions

### Resolved During Planning

- **Q: Should PR review comments and PR reviews also support `/review`?** — Yes. Any `@claude /review` on a PR should trigger review mode regardless of the comment type.
- **Q: Should we use a matrix strategy or conditional steps?** — Conditional steps. Matrix would create two separate job runs and waste CI minutes for the path not taken.

### Deferred to Implementation

- None — this is a straightforward refactor.

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification.*

```
job: claude
  if: (existing @claude trigger conditions — unchanged)

  step: Checkout (unchanged)

  step: Detect review mode
    id: mode
    if: comment/review body contains '/review' AND event is on a PR
    output: is_review=true

  step: Run Claude Code (normal)
    if: steps.mode.outputs.is_review != 'true'
    with: (existing config — unchanged)

  step: Run Claude Code Review
    if: steps.mode.outputs.is_review == 'true'
    with: (review-specific config from claude-code-review.yml)
```

## Implementation Units

- [ ] **Unit 1: Add review detection and conditional steps to claude.yml**

**Goal:** Consolidate both workflows into `claude.yml` with conditional review mode

**Requirements:** R1, R2, R3, R5

**Dependencies:** None

**Files:**
- Modify: `.github/workflows/claude.yml`

**Approach:**
- Add a "Detect review mode" step after checkout that checks if the triggering comment/review body contains `/review` and the event is on a PR
- For `issue_comment`: check `github.event.issue.pull_request` AND `contains(github.event.comment.body, '/review')`
- For `pull_request_review_comment`: check `contains(github.event.comment.body, '/review')` (always on a PR)
- For `pull_request_review`: check `contains(github.event.review.body, '/review')` (always on a PR)
- For `issues`: never review mode
- Convert existing "Run Claude Code" step to conditional on `steps.mode.outputs.is_review != 'true'`
- Add new "Run Claude Code Review" step conditional on `steps.mode.outputs.is_review == 'true'` with all review-specific settings from `claude-code-review.yml`

**Patterns to follow:**
- Existing step `if` patterns in `harness-analysis.yml`
- SHA-pinned actions convention
- `contains(fromJSON(...), ...)` for set-membership checks (per `github-actions.md` rule)

**Test scenarios:**
- Happy path: `@claude fix the typo` on a PR comment → normal Claude mode (no review plugin)
- Happy path: `@claude /review` on a PR comment → review mode with plugins and custom prompt
- Happy path: `@claude please review this` on a PR comment → normal mode (`/review` substring not present as standalone command)
- Edge case: `@claude /review` on an issue (not PR) → normal mode (no `pull_request` context)
- Edge case: `@claude /review` in a PR review body → review mode
- Edge case: `@claude /review` in a PR review comment → review mode
- Happy path: `@claude` on an opened issue → normal mode (issues event, never review)

**Verification:**
- `claude.yml` contains two mutually exclusive Claude Code Action steps
- Review step includes all settings from R5 (allowed_bots, show_full_output, classify_inline_comments, claude_args, plugin_marketplaces, plugins, prompt)
- Normal step preserves existing configuration exactly

- [ ] **Unit 2: Delete claude-code-review.yml**

**Goal:** Remove the now-redundant review workflow

**Requirements:** R4

**Dependencies:** Unit 1

**Files:**
- Delete: `.github/workflows/claude-code-review.yml`

**Approach:**
- Delete the file
- Verify no other files reference `claude-code-review.yml` (grep for the filename)

**Test expectation:** none — pure file deletion

**Verification:**
- File no longer exists
- No dangling references to `claude-code-review.yml` in the repository

## System-Wide Impact

- **Interaction graph:** The `harness-auto-remediate.yml` workflow is independent and unaffected. No other workflow references `claude-code-review.yml`.
- **Error propagation:** No change — each step runs or skips based on its condition.
- **Behavior change:** Standalone `/review` (without `@claude`) will no longer trigger review. This is intentional per R3.
- **Unchanged invariants:** All existing `@claude` trigger conditions in the job-level `if` remain exactly as-is. Permissions block unchanged.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Review mode detection logic has a bug, causing `/review` to run in normal mode or vice versa | Test scenarios cover all event types; review step conditions are explicit and mutually exclusive |
| Standalone `/review` users (if any) lose functionality | User confirmed this behavior change is acceptable (R3) |

## Sources & References

- `.github/workflows/claude.yml` — current general workflow
- `.github/workflows/claude-code-review.yml` — current review workflow
- `~/.claude/rules/common/github-actions.md` — expression syntax constraints
- `anthropics/claude-code-action` — action documentation
