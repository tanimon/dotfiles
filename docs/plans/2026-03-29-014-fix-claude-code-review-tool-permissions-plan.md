---
title: "fix: Add allowed tools for Claude Code Review workflow"
type: fix
status: active
date: 2026-03-29
---

# fix: Add allowed tools for Claude Code Review workflow

## Overview

The Claude Code Review workflow (`claude-code-review.yml`) fails internally because the Claude Code agent's tool approval system blocks `gh api` and `gh pr` bash commands. These commands are needed by the `code-review` plugin to fetch PR details, diffs, and post review comments.

## Problem Frame

The workflow runs successfully (exit 0) but the code-review plugin encounters repeated internal errors:
- `"Error: This command requires approval"` — `gh api` and `gh pr` commands blocked
- `"Error: This Bash command contains multiple operations"` — multi-command bash blocked

These are **not** GitHub API permission errors — the GITHUB_TOKEN has correct permissions. The issue is Claude Code's internal `permissionMode: "default"` blocking unapproved bash commands.

## Requirements Trace

- R1. `gh api repos/*/pulls/*/comments` must be allowed (fetching PR comments)
- R2. `gh api repos/*/contents/*` must be allowed (reading file contents via API)
- R3. `gh pr view` must be allowed (fetching PR metadata)
- R4. `gh pr diff` must be allowed (fetching PR diff)

## Scope Boundaries

- Only modify the `claude-code-review.yml` workflow
- Do not change permissions (GITHUB_TOKEN permissions are correct)
- Do not modify the code-review plugin itself

## Key Technical Decisions

- **Use `claude_args` with `--allowedTools`**: The `claude-code-action` supports passing `--allowedTools` via `claude_args` to pre-approve specific bash command patterns. This is the documented approach.
- **Use `Bash(gh *)` pattern**: Allow all `gh` CLI subcommands rather than listing each individually. The `gh` CLI is authenticated with the workflow's GITHUB_TOKEN, so the permission boundary is already enforced by GitHub's token scope.

## Implementation Units

- [ ] **Unit 1: Add `claude_args` with allowed tools**

**Goal:** Pre-approve `gh` CLI commands so the code-review plugin can operate without tool approval errors.

**Files:**
- Modify: `.github/workflows/claude-code-review.yml`

**Approach:**
- Add `claude_args` input to the `claude-code-action` step with `--allowedTools "Bash(gh *)"` pattern

**Verification:**
- Trigger the workflow on a PR with `/review` comment and confirm no "requires approval" errors in logs
