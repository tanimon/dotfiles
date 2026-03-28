---
title: claude-code-action v1 parameter migration — direct_prompt and allowed_tools replaced
date: 2026-03-29
category: integration-issues
module: GitHub Actions / Claude Code Action
problem_type: workflow_issue
component: development_workflow
symptoms:
  - "Workflow YAML validates without errors but action ignores custom prompt"
  - "Claude Code runs with default behavior instead of intended automation parameters"
  - "No error messages indicate parameter rejection"
root_cause: missing_workflow_step
resolution_type: workflow_improvement
severity: high
tags:
  - github-actions
  - claude-code-action
  - ci-cd
  - silent-failure
---

# claude-code-action v1 parameter migration — direct_prompt and allowed_tools replaced

## Problem

`anthropics/claude-code-action` v1 renamed two key input parameters from v0.x without backward compatibility. Using the old parameter names (`direct_prompt`, `allowed_tools`) produces no error — the workflow YAML is syntactically valid and GitHub Actions runs the job — but Claude Code silently ignores the unrecognized inputs.

## Symptoms

- Workflow runs complete without errors in GitHub Actions logs
- Claude Code executes with default behavior instead of the intended custom prompt
- Tool restrictions specified via `allowed_tools` are not applied
- No warning or error indicates that parameters were rejected or ignored

## What Didn't Work

- Writing workflow YAML based on older documentation or LLM training data referencing v0.x parameter names
- Relying on YAML syntax validation to catch semantic API mismatches — GitHub Actions accepts any `with:` key without validating against the action's `action.yml`
- Following patterns from existing repository workflows — the existing `claude.yml` and `claude-code-review.yml` used different parameters (`claude_code_oauth_token`, `plugin_marketplaces`, `plugins`) and didn't exercise `direct_prompt` or `allowed_tools`

## Solution

**Before (broken — v0.x parameter names):**
```yaml
- uses: anthropics/claude-code-action@aee99972d0cfa0c47a4563e6fca42d7a5a0cb9bd # v1
  with:
    claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
    direct_prompt: |
      Your prompt here...
    allowed_tools: "Bash(git status),Read,Glob,Grep"
```

**After (correct — v1 parameter names):**
```yaml
- uses: anthropics/claude-code-action@aee99972d0cfa0c47a4563e6fca42d7a5a0cb9bd # v1
  with:
    claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
    prompt: |
      Your prompt here...
    claude_args: '--allowedTools "Bash(git status),Read,Glob,Grep"'
```

Key changes:
- `direct_prompt` → `prompt` (for automation mode without PR/issue context)
- `allowed_tools` → `claude_args` with `--allowedTools` flag (tool restrictions passed as CLI args)

## Why This Works

claude-code-action v1 refactored its input schema. The `prompt` parameter triggers automation mode (running Claude Code with a direct prompt instead of responding to a PR/issue event). Tool restrictions moved from a dedicated input to `claude_args`, which passes arbitrary CLI flags to the underlying Claude Code process. This design allows the action to support any CLI flag without hardcoding each one as a separate input.

GitHub Actions does not validate `with:` keys against the action's `action.yml` — unrecognized keys are silently ignored. This means the old parameter names produce zero errors but have zero effect, making this a particularly dangerous silent failure.

## Prevention

- **Check the action's `action.yml`** before using parameters — not documentation or training data. The `action.yml` in the action's repository is the authoritative source for available inputs
- **Test scheduled/automation workflows with `workflow_dispatch`** — run manually after creation to verify Claude Code receives the intended prompt and tool restrictions
- **Enable debug logging** (`ACTIONS_RUNNER_DEBUG: true`) to inspect actual parameter values being passed to the action
- **Cross-reference SHA-pinned versions** — when using a SHA pin, verify it corresponds to v1 and check the `action.yml` at that specific commit

## Related Issues

- `docs/solutions/integration-issues/github-actions-expression-in-operator-does-not-exist-2026-03-29.md` — Same pattern: GitHub Actions silently accepts invalid syntax without errors. The `in` operator evaluates to `false` silently, just as unrecognized `with:` keys are silently ignored
- `docs/solutions/integration-issues/renovate-managerfilepatterns-regex-delimiter.md` — Similar "silent syntax misinterpretation" pattern where tools accept input without error but misinterpret intent
- `.claude/rules/common/github-actions.md` — Repository rules for GitHub Actions security hardening
