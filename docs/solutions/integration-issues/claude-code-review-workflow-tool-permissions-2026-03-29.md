---
title: Claude Code Review workflow tool permission denials (allowedTools)
date: 2026-03-29
category: integration-issues
module: github-actions
problem_type: integration_issue
component: tooling
symptoms:
  - Claude Code tool approval system blocking gh CLI commands in GitHub Actions
  - WebFetch tool permission denial in code-review plugin
  - Workflow jobs show success but plugin cannot fetch PR data or post comments
root_cause: missing_permission
resolution_type: workflow_improvement
severity: high
tags:
  - claude-code
  - github-actions
  - permissions
  - tool-approval
  - code-review-plugin
  - allowedTools
---

# Claude Code Review workflow tool permission denials (allowedTools)

## Problem

The Claude Code Review GitHub Actions workflow experienced internal tool permission denials. The code-review plugin's `gh api`, `gh pr`, and `WebFetch` commands were blocked by Claude Code's internal tool approval system (`permissionMode: default`), even though the workflow's GITHUB_TOKEN had correct permissions.

## Symptoms

- Workflow jobs completed with "success" status but the plugin encountered repeated internal errors
- `"Error: This command requires approval"` for `gh api`, `gh pr view`, `gh pr diff` commands
- `"Error: This Bash command contains multiple operations. The following part requires approval: gh api repos/..."` (multi-operation blocking)
- `"Claude requested permissions to use WebFetch, but you haven't granted it yet."`
- `"Output redirection to '/tmp/...' was blocked"` (working directory restriction — separate from allowedTools)

## What Didn't Work

- Searched for GitHub API 403/forbidden errors — found none because the GITHUB_TOKEN permissions were correct; the issue was Claude Code's internal permission mode, not GitHub's
- Searched for "permission denied" — matched too broadly on unrelated log content (UUIDs containing "403", file content with "forbidden")
- Had to narrow search to `"requires approval"` and `"haven't granted"` to isolate the actual errors

## Solution

Added `claude_args` with `--allowedTools` to pre-approve the needed tools:

**Before:**
```yaml
- uses: anthropics/claude-code-action@sha # v1
  with:
    claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
    additional_permissions: |
      actions: read
    # ... other config ...
```

**After:**
```yaml
- uses: anthropics/claude-code-action@sha # v1
  with:
    claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
    claude_args: '--allowedTools "Bash(gh *),WebFetch"'
    additional_permissions: |
      actions: read
    # ... other config ...
```

## Why This Works

Claude Code runs in `permissionMode: "default"` within GitHub Actions, which requires explicit approval for tools and complex bash commands. The `--allowedTools` flag pre-approves specified tools at invocation time.

Key distinction: `additional_permissions` controls **GITHUB_TOKEN scopes** (GitHub API access). `claude_args --allowedTools` controls **Claude Code's internal tool approval** (which bash commands and tools the agent can use without interactive confirmation). These are separate permission layers — both must be configured correctly.

The `gh` CLI is already authenticated with the workflow's GITHUB_TOKEN, so allowing it via `--allowedTools` doesn't bypass any security controls — the token's scope remains the actual permission boundary.

## Prevention

- When Claude Code tools fail with "requires approval" in GitHub Actions, check `claude_args --allowedTools` first — not GITHUB_TOKEN permissions
- `claude-code-action` defaults to restrictive permission mode; any plugin using external CLI tools or non-default tools (WebFetch, etc.) needs explicit `--allowedTools`
- Proactively add `--allowedTools` for known tools when configuring new workflows rather than discovering them through CI failures
- Distinguish the two permission layers: `additional_permissions` = GitHub API scopes, `claude_args --allowedTools` = Claude Code internal tool approval

## Related Issues

- [claude-code-action v1 parameter migration](claude-code-action-v1-parameter-migration-2026-03-29.md) — documents the v0.x `allowed_tools` → v1 `claude_args --allowedTools` API change
- [Claude Code Review no PR comments](claude-code-review-no-pr-comments-classify-inline-filter-2026-03-29.md) — related workflow permission troubleshooting (different failure mode: comments dropped vs tools denied)
- PR #93: fix adding `--allowedTools` to the review workflow
