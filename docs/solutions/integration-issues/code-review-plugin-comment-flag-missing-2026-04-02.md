---
title: "Code-review plugin posts no PR comments without --comment flag"
date: 2026-04-02
category: integration-issues
module: ci-cd
problem_type: integration_issue
component: claude-code-review-workflow
symptoms:
  - "@claude /review completes successfully but no review comment appears on the PR"
  - "result field is empty string in Claude Code final JSON output"
  - "Plugin outputs: No --comment flag was provided, so no GitHub comments will be posted"
  - "Workflow costs $1+ per run with no visible output"
root_cause: config_error
resolution_type: config_change
severity: medium
tags:
  - github-actions
  - claude-code-action
  - code-review-plugin
  - claude-code-plugins
  - silent-failure
  - workflow-configuration
related_files:
  - .github/workflows/claude.yml
related_issues:
  - "#94"
  - "#109"
  - "#83"
---

# Code-review plugin posts no PR comments without --comment flag

## Problem

The `@claude /review` command on PRs completed successfully (20 turns, 4 issues found, $1.44 cost) but posted no review comment. The code-review plugin from the `claude-code-plugins` marketplace returned `result: ""` (empty string), so `claude-code-action` had nothing to post as a PR comment.

## Symptoms

- `@claude /review` workflow runs show `conclusion: success` on all steps including "Run Claude Code Review"
- No review comment appears on the PR despite the plugin finding multiple issues
- The final Claude Code JSON output shows `"result": ""`
- The plugin outputs an intermediate message: `"No --comment flag was provided, so no GitHub comments will be posted."`
- Both diagnostic messages are only visible when `show_full_output: true` is enabled — with default settings, the failure is completely silent

## What Didn't Work

- **Previous infrastructure fixes (PRs #83, #92, #93)** resolved permissions, tool access, and trigger configuration but did not address the comment-posting mechanism itself
- **Testing on trivial PRs** (Renovate version bumps) where the plugin skipped review as "trivially correct" — masked the issue because the expected behavior (no comment) matched the broken behavior (no comment)
- **Checking workflow permissions** — `pull-requests: write` was correctly set, but the issue was in the plugin invocation, not the GitHub token permissions

## Solution

Added `--comment` flag to the code-review plugin prompt in `.github/workflows/claude.yml`:

```yaml
# Before (broken — review runs but result is empty)
prompt: '/code-review:code-review ${{ github.repository }}/pull/${{ github.event.issue.number || github.event.pull_request.number }}'

# After (working — plugin posts review as PR comment)
prompt: '/code-review:code-review ${{ github.repository }}/pull/${{ github.event.issue.number || github.event.pull_request.number }} --comment'
```

The `--comment` flag requires:
- `Bash(gh *)` in the `claude_args` allowed tools (already configured)
- `pull-requests: write` in the workflow permissions (already set)

## Why This Works

The `code-review@claude-code-plugins` plugin has two operating modes:

1. **Without `--comment`** (default): The plugin generates review findings as intermediate text messages in the conversation but returns an empty string as the final result. This mode is designed for local CLI use where the output appears in the terminal.

2. **With `--comment`**: The plugin posts its findings as a PR comment via the `gh` CLI. This is the mode needed for GitHub Actions where the output must be posted to the PR.

When `claude-code-action` receives the result from Claude Code, it uses the `result` field to determine what to post. An empty result means nothing is posted. The review findings existed only in intermediate conversation turns, which `claude-code-action` does not extract for comment posting.

## Prevention

### Always test code-review with non-trivial PRs

Trivial PRs (dependency bumps, formatting) are often skipped by the plugin as "trivially correct." This produces the same output (no comment) as the broken configuration, masking the real issue. Validate on PRs with 5+ changed files containing meaningful logic.

### Keep `show_full_output: true` until confirmed working

The diagnostic message `"No --comment flag was provided"` is only visible in full output mode. Without it, the failure is completely silent — the workflow succeeds, costs money, and produces no visible result. Only revert to `show_full_output: false` after confirming end-to-end comment posting.

### Check `result` field when debugging missing comments

When `@claude /review` runs but no comment appears, check the workflow logs for the final JSON output:

```json
{
  "type": "result",
  "result": "",          // ← Empty means nothing will be posted
  "is_error": false,
  "duration_ms": 253667
}
```

A non-empty `result` field with no comment indicates a `claude-code-action` posting issue. An empty `result` field indicates the plugin itself did not produce output for posting.

### Search for plugin-specific diagnostic messages

The code-review plugin emits specific messages about its behavior. Search the full logs for:
- `"No --comment flag was provided"` — missing flag
- `"trivially correct"` — PR skipped as too simple
- `"No buffered inline comments"` — classify_inline_comments filter (see related doc)

## Related Issues

- [Claude Code Review no PR comments due to classify_inline_comments](claude-code-review-no-pr-comments-classify-inline-filter-2026-03-29.md) — Different root cause (comment classification filter), same symptom (no comments posted)
- [claude-code-action v1 parameter migration](claude-code-action-v1-parameter-migration-2026-03-29.md) — Related silent failure pattern from configuration issues
- [GitHub Actions security alert workflow pitfalls](github-actions-security-alert-workflow-pitfalls-2026-04-02.md) — Same PR, different issue (GITHUB_TOKEN limitations)
- PR #109: feat: add automated GitHub Security Alert handling workflow
- Issue #94: chore: validate Claude Code Review with non-trivial PR and revert debug settings
