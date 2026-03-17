---
title: "chezmoi full-template files silently drift from deployed target"
date: 2026-03-18
category: integration-issues
tags: [chezmoi, settings.json, drift, template, sync]
module: chezmoi template management
symptom: "chezmoi apply overwrites runtime changes to settings.json (statusLine, skipDangerousModePermissionPrompt lost)"
root_cause: "Full .tmpl files overwrite target entirely on apply; runtime changes not synced back to source"
---

# chezmoi full-template files silently drift from deployed target

## Problem

`dot_claude/settings.json.tmpl` is a full chezmoi template — every `chezmoi apply` overwrites `~/.claude/settings.json` entirely. When Claude Code or the user changes the target file at runtime (e.g., via `/config`, CLI commands), those changes are silently lost on the next apply unless manually synced back to the source template.

In this case, two fields had drifted:
- `statusLine.command` changed from `bash statusline-wrapper.sh` to `node --experimental-strip-types statusline-command.ts`
- `skipDangerousModePermissionPrompt: true` was added via CLI

## Root Cause

Full `.tmpl` files are "source wins" — chezmoi renders the template and writes the result, ignoring the current target content. Unlike `modify_` scripts (which receive the current target on stdin), templates have no awareness of runtime state.

This is by design for most files, but problematic for files that are mutated by their own applications (like `settings.json` which Claude Code modifies via `/config`).

## Solution

Manually sync the source template with the deployed target:

```bash
# Compare rendered source vs actual target
diff <(chezmoi cat ~/.claude/settings.json) ~/.claude/settings.json

# Update the .tmpl source to match, then commit
```

## Prevention

1. **After changing settings via CLI or `/config`**: run `chezmoi diff` to check for drift, then update the source template
2. **Before modifying a `.tmpl` file**: compare with the deployed target first to catch accumulated drift
3. **Consider `modify_` pattern**: for files with many runtime-mutable keys, a `modify_` script (like `modify_dot_claude.json`) preserves target state while managing specific keys

## Related

- [modify_dot_claude.json pattern](../../CLAUDE.md) — partial JSON management for runtime-mutable files
