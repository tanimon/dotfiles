---
title: "fix: code-review plugin missing --comment flag and security-alerts permission cleanup"
type: fix
status: completed
date: 2026-04-02
---

# fix: code-review plugin missing --comment flag and security-alerts permission cleanup

## Overview

The `@claude /review` command on PR #109 completed successfully (20 turns, 4 issues found, $1.44 cost) but posted no review comment. Root cause: the code-review plugin requires a `--comment` flag to post PR comments, and without it the plugin's final result is an empty string — so `claude-code-action` also has nothing to post. Additionally, the review itself found legitimate permission issues in `security-alerts.yml` that should be addressed.

## Problem Frame

Issue #94 requires end-to-end validation that `@claude /review` posts comments on non-trivial PRs. The first real test (PR #109) revealed the comment-posting mechanism is broken. Two separate problems:

1. **No review comment posted** — The code-review plugin outputs `"No --comment flag was provided, so no GitHub comments will be posted."` and returns `result: ""`. `claude-code-action` receives the empty result and posts nothing.
2. **security-alerts.yml has overly broad permissions** — The review found `id-token: write` (unnecessary on all 4 jobs) and `security-events: write` (unnecessary on 3 of 4 jobs).

## Requirements Trace

- R1. `@claude /review` must post review comments on the PR (Issue #94 TODO item 1)
- R2. Remove unnecessary `id-token: write` from security-alerts workflow jobs
- R3. Remove/downgrade unnecessary `security-events: write` from security-alerts workflow jobs
- R4. After validation, revert debug settings per Issue #94 TODO items 2-3

## Scope Boundaries

- Not fixing the code-review plugin upstream — only adjusting our workflow invocation
- Not addressing prompt injection / autonomous dismissal concerns from the review (those are design decisions for a separate Issue)
- Not changing the `claude-code-action` SHA pin

## Context & Research

### Relevant Code and Patterns

- `.github/workflows/claude.yml:78` — current prompt missing `--comment` flag
- `.github/workflows/security-alerts.yml` — permission blocks on all 4 jobs
- `docs/solutions/integration-issues/claude-code-review-no-pr-comments-classify-inline-filter-2026-03-29.md` — prior silent-failure debugging of the same workflow

### Institutional Learnings

- The code-review plugin from `claude-code-plugins` marketplace uses `--comment` flag to enable GitHub comment posting
- `classify_inline_comments: false` was set in PR #83 as a workaround; Issue #94 asks to evaluate reverting it
- `show_full_output: true` was set for debugging; Issue #94 asks to evaluate reverting it

### Workflow Run Evidence

- Run 23897510281, Job 69685698760: all steps succeeded, review found 4 issues
- Final result: `"result": ""` — empty string, no text to post
- Plugin output: `"No --comment flag was provided, so no GitHub comments will be posted."`
- `gh pr view tanimon/dotfiles/109` failed (wrong format), but plugin recovered

## Key Technical Decisions

- **Add `--comment` flag to code-review prompt**: This tells the plugin to post its findings as a PR comment via the `gh` CLI. The workflow already has `pull-requests: write` permission and `Bash(gh *)` in allowed tools, so the plugin can post.
- **Keep `show_full_output: true` for now**: Revert only after confirming comment posting works end-to-end. The cost of debugging silent failures without output is too high.
- **Keep `classify_inline_comments: false` for now**: Same reasoning — revert only after confirming the basic flow works.
- **Remove `id-token: write` from all 4 jobs**: None use Bedrock/Vertex/Foundry. All authenticate via `CLAUDE_CODE_OAUTH_TOKEN`.
- **Remove `security-events: write` from `dependabot` and `sweep` jobs**: They don't interact with code scanning alerts.
- **Downgrade `security-events: write` to `security-events: read` on `code-scanning` job**: It reads code scanning alerts but doesn't upload SARIF or dismiss alerts.

## Implementation Units

- [ ] **Unit 1: Add `--comment` flag to code-review prompt**

**Goal:** Enable the code-review plugin to post review findings as PR comments.

**Requirements:** R1

**Dependencies:** None

**Files:**
- Modify: `.github/workflows/claude.yml`

**Approach:**
- Add `--comment` to the end of the prompt string on line 78
- The prompt becomes: `/code-review:code-review ${{ github.repository }}/pull/${{ github.event.issue.number || github.event.pull_request.number }} --comment`

**Patterns to follow:**
- The code-review plugin from `claude-code-plugins` expects `--comment` flag to enable posting

**Test scenarios:**
- Happy path: after deployment, `@claude /review` on a non-trivial PR produces a review comment
- Edge case: on a trivial PR (Renovate bump), plugin may skip review — this is acceptable behavior

**Verification:**
- The prompt line in `claude.yml` includes `--comment` at the end

- [ ] **Unit 2: Remove `id-token: write` from all security-alerts workflow jobs**

**Goal:** Remove unnecessary OIDC permission from all 4 jobs.

**Requirements:** R2

**Dependencies:** None

**Files:**
- Modify: `.github/workflows/security-alerts.yml`

**Approach:**
- Remove `id-token: write` line from permissions blocks of `dependabot` (line 35), `code-scanning` (line 135), `secret-scanning` (line 225), and `sweep` (line 293) jobs

**Test scenarios:**
- Test expectation: none — pure permission removal, no behavioral change. Validated by the fact that no job uses Bedrock/Vertex/Foundry.

**Verification:**
- No `id-token: write` appears in any job's permissions block
- `make lint` passes

- [ ] **Unit 3: Remove/downgrade `security-events: write` from security-alerts workflow jobs**

**Goal:** Apply least-privilege to security-events permission.

**Requirements:** R3

**Dependencies:** None

**Files:**
- Modify: `.github/workflows/security-alerts.yml`

**Approach:**
- `dependabot` job: remove `security-events: write` entirely (Dependabot API uses PAT, not GITHUB_TOKEN security-events scope)
- `code-scanning` job: downgrade `security-events: write` to `security-events: read` (reads alerts but doesn't dismiss or upload SARIF)
- `sweep` job: downgrade `security-events: write` to `security-events: read` (reads alerts from all types, doesn't modify code scanning state)
- `secret-scanning` job: already correctly scoped (no security-events permission)

**Test scenarios:**
- Test expectation: none — permission scoping change. Validated by prompt analysis (no SARIF uploads, no alert dismissals for code scanning).

**Verification:**
- `dependabot` job has no `security-events` permission
- `code-scanning` and `sweep` jobs have `security-events: read`
- `secret-scanning` job is unchanged
- `make lint` passes

## System-Wide Impact

- **Interaction graph:** The `--comment` flag changes how the code-review plugin interacts with GitHub — it will call `gh pr comment` or `gh pr review` to post findings. This requires `Bash(gh *)` (already allowed) and `pull-requests: write` (already granted).
- **Error propagation:** If `--comment` posting fails (e.g., permission issue), the plugin should still complete — the review text will be visible in workflow logs via `show_full_output: true`.
- **Unchanged invariants:** The `@claude` trigger phrase, review detection logic, and non-review Claude Code step are not modified.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| `--comment` flag format or behavior differs from expected | `show_full_output: true` still enabled — full diagnostic output available in logs |
| Permission removal breaks security alert handling | None of the removed permissions are used by any job's prompt or allowed tools |
| code-review plugin changes upstream | Plugin is pinned via marketplace; behavior is stable |

## Sources & References

- Related issues: #94, #83, #92, #93, #104
- Workflow run: actions/runs/23897510281/job/69685698760
- Solution doc: `docs/solutions/integration-issues/claude-code-review-no-pr-comments-classify-inline-filter-2026-03-29.md`
