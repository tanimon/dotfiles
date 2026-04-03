---
title: "feat: Change Claude Code Review to manual comment trigger"
type: feat
status: completed
date: 2026-03-29
---

# feat: Change Claude Code Review to manual comment trigger

## Overview

Change `.github/workflows/claude-code-review.yml` from automatic PR event triggers (`opened`, `synchronize`, `ready_for_review`, `reopened`) to manual trigger via PR comment, requiring explicit human action to start a review.

## Problem Frame

The current workflow runs automatically on every PR event, consuming API credits and generating review noise on PRs that may not need automated review. The user wants explicit control over when Claude Code Review runs.

## Requirements Trace

- R1. Review must NOT auto-trigger on PR open/sync/reopen events
- R2. Review must trigger on explicit human comment (e.g., `/review`) on the PR
- R3. Only authorized users (OWNER, MEMBER, COLLABORATOR) can trigger the review
- R4. Fork PR exclusion guard must be preserved
- R5. All existing review configuration (plugin, marketplace, prompt) must be preserved

## Scope Boundaries

- NOT changing the `claude.yml` workflow (general `@claude` mentions)
- NOT changing the review plugin configuration or prompt
- NOT adding `workflow_dispatch` (this is about PR-level trigger, not repo-level manual run)

## Context & Research

### Relevant Code and Patterns

- `.github/workflows/claude.yml` — Existing comment-triggered workflow using `issue_comment` + `@claude` mention + `author_association` guard with `contains(fromJSON(...))` pattern. This is the established pattern to follow.
- `.github/workflows/claude-code-review.yml` — Current auto-triggered review workflow (target file)
- `~/.claude/rules/common/github-actions.md` — `in` operator does not exist in GitHub Actions; must use `contains(fromJSON(...))` for set-membership checks

### Institutional Learnings

- GitHub Actions `in` operator silently evaluates to `false` — always use `contains(fromJSON(...))` (from `github-actions.md` rule)
- Actions must be pinned to full commit SHAs for security hardening

## Key Technical Decisions

- **Trigger comment: `/review`** — Short, distinct from `@claude` (which triggers the general workflow), follows conventional slash-command pattern used in many GitHub bots. The `/` prefix is unlikely to appear in normal conversation.
- **Use `issue_comment` event only** — `pull_request_review_comment` is for inline code comments which are awkward for triggering a full review. A top-level PR comment (`issue_comment` on a PR) is the natural UX.
- **Keep as separate workflow** — The review uses a distinct plugin (`code-review@claude-code-plugins`) and different configuration from `claude.yml`, so merging them would add complexity without benefit.

## Open Questions

### Resolved During Planning

- **Which comment pattern?** → `/review` — simple, distinct, conventional
- **Should `pull_request_review_comment` be included?** → No, top-level comment is sufficient and cleaner UX

### Deferred to Implementation

- None

## Implementation Units

- [ ] **Unit 1: Change workflow trigger from PR events to comment trigger**

**Goal:** Replace automatic PR event triggers with `issue_comment` trigger and `/review` comment detection

**Requirements:** R1, R2, R3, R4, R5

**Dependencies:** None

**Files:**
- Modify: `.github/workflows/claude-code-review.yml`

**Approach:**
- Replace `on: pull_request` with `on: issue_comment: types: [created]`
- Replace the existing `if` condition with a compound condition:
  1. The event is an `issue_comment` on a pull request (`github.event.issue.pull_request`)
  2. The comment body contains `/review`
  3. The comment author is OWNER, MEMBER, or COLLABORATOR (using `contains(fromJSON(...))` pattern from `claude.yml`)
  4. The PR is not from a fork (preserve existing fork guard — adapt to `issue_comment` event context where PR head repo must be checked differently)
- Preserve all `steps`, `permissions`, and review configuration unchanged

**Patterns to follow:**
- `.github/workflows/claude.yml` lines 14-27 for `issue_comment` + `author_association` guard pattern
- `contains(fromJSON('["OWNER", "MEMBER", "COLLABORATOR"]'), github.event.comment.author_association)` syntax

**Test scenarios:**
- Happy path: OWNER posts `/review` comment on a non-fork PR → workflow triggers and runs review
- Happy path: MEMBER posts `/review` comment → workflow triggers
- Edge case: Comment contains `/review` as substring of larger text (e.g., "please /review this") → should still trigger (contains match)
- Error path: External contributor (author_association not in allowed list) posts `/review` → workflow does NOT trigger
- Error path: Fork PR receives `/review` comment → workflow does NOT trigger
- Edge case: Comment on an issue (not a PR) containing `/review` → workflow does NOT trigger (`github.event.issue.pull_request` check)
- Edge case: PR `synchronize` event (push to PR branch) → workflow does NOT trigger (event type changed)

**Verification:**
- `make lint` passes (CI alignment)
- The workflow YAML is valid
- The `if` condition uses `contains(fromJSON(...))` and NOT the `in` operator
- All existing `steps` and review configuration are unchanged

## System-Wide Impact

- **Interaction graph:** The existing `claude.yml` workflow is not affected — `@claude` mentions continue to work independently. The `/review` trigger is exclusive to this workflow.
- **API surface parity:** No other interfaces need the same change
- **Unchanged invariants:** Review plugin configuration, marketplace, prompt, and permissions remain identical

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Fork PR guard logic differs between `pull_request` and `issue_comment` event contexts | Verify the correct event payload path for checking PR head repo in `issue_comment` context |
| Users may not know about the new `/review` trigger | Consider adding usage note in PR template or CLAUDE.md |

## Sources & References

- Related code: `.github/workflows/claude.yml` (comment trigger pattern)
- Related code: `.github/workflows/claude-code-review.yml` (target file)
- Related rules: `~/.claude/rules/common/github-actions.md`
