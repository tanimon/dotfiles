---
title: "chezmoi add fails with EPERM in sandbox — use direct cp to source directory"
category: integration-issues
date: 2026-04-03
tags: [chezmoi, sandbox, seatbelt, cco, plugin-management, harness-engineering]
module: chezmoi
problem_type: integration_issue
component: tooling
severity: low
symptoms:
  - "chezmoi add fails with 'open chezmoistate.boltdb: operation not permitted' inside cco/Seatbelt sandbox"
  - "chezmoi unmanaged ~/.claude returns files that overlap with installed plugin functionality"
root_cause: "chezmoi add requires write access to ~/.config/chezmoi/chezmoistate.boltdb which is blocked by cco --safe sandbox deny rules"
resolution_type: workaround
---

# chezmoi add fails with EPERM in sandbox — use direct cp to source directory

## Problem

When running inside a cco/Seatbelt sandbox (`claude` wrapper), `chezmoi add <file>` fails with:

```
open /Users/<user>/.config/chezmoi/chezmoistate.boltdb: operation not permitted
```

This blocks the normal workflow for adding files to chezmoi management during agent sessions.

## Symptoms

- `chezmoi add ~/.claude/commands/foo.md` exits with code 1
- Error references `chezmoistate.boltdb`
- Only occurs inside sandboxed `claude` sessions (not in unsandboxed shell)

## What Didn't Work

- Adding `~/.config/chezmoi/` to cco allow-paths as read-only — `chezmoi add` needs write access to the state DB, not just read
- Using `chezmoi add --template` — same EPERM on boltdb

## Solution

Bypass `chezmoi add` by copying files directly to the chezmoi source directory using `cp`:

```bash
# Instead of: chezmoi add ~/.claude/commands/foo.md
# Do:
cp ~/.claude/commands/foo.md ~/.local/share/chezmoi/dot_claude/commands/foo.md

# For skill directories:
mkdir -p ~/.local/share/chezmoi/dot_claude/skills/my-skill
cp ~/.claude/skills/my-skill/SKILL.md ~/.local/share/chezmoi/dot_claude/skills/my-skill/SKILL.md
```

Key points:
- Follow chezmoi naming conventions (`dot_` prefix for dotfiles)
- No template rendering needed for plain markdown files
- Verify with `chezmoi managed | grep <pattern>` after copying

## Why This Works

`chezmoi add` does two things: (1) copies the file to the source directory with correct naming, and (2) updates the state database. When the state DB is inaccessible, we can do step (1) manually. chezmoi discovers source files by scanning the directory tree, not solely from the state DB, so manually placed files are picked up on the next `chezmoi managed` or `chezmoi apply`.

## Prevention

- When working inside a sandboxed Claude Code session, always use `cp` instead of `chezmoi add`
- For `.tmpl` files, manual placement still works but template rendering must be verified with `chezmoi execute-template`
- Consider adding `~/.config/chezmoi/:rw` to sandbox allow-paths if `chezmoi add` is frequently needed (security tradeoff)

## Related

- `docs/solutions/integration-issues/cco-sandbox-chezmoi-read-only-access.md` — Enabling chezmoi read-only commands in sandbox
- `docs/solutions/integration-issues/safehouse-daily-dev-paths-and-chezmoi-diff-eperm.md` — Safehouse path configuration for chezmoi

## Appendix: Plugin Overlap Detection Methodology

When auditing `chezmoi unmanaged` files for plugin overlap, use this approach:

1. **List unmanaged files**: `chezmoi unmanaged ~/.claude`
2. **Check plugin marketplace directories**: `find ~/.claude/plugins/marketplaces -name "SKILL.md"` to see what each marketplace provides
3. **Cross-reference installed plugins**: Read `~/.claude/plugins/installed_plugins.json` for installed plugin list
4. **Check enabled plugins**: Read `settings.json` `enabledPlugins` to confirm which plugins are active
5. **Compare purposes**: For each unmanaged skill/command, check if an enabled plugin provides equivalent functionality
6. **Classify disposition**: DELETE (overlap/superseded), MANAGE (unique/useful), or IGNORE (runtime state)
