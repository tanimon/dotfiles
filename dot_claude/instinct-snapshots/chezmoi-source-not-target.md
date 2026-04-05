---
id: chezmoi-source-not-target
trigger: when editing chezmoi-managed configuration files
confidence: 0.7
domain: file-patterns
source: session-observation
scope: project
project_id: 23e6ae2f0a00
project_name: chezmoi
---

# Edit Source Files, Not Deployed Targets

## Action
Always edit files under `~/.local/share/chezmoi/` (the source directory), never the deployed targets under `~/`. Changes to deployed targets are overwritten on next `chezmoi apply` and are not version-controlled. Use `chezmoi source-path <target>` to find the source file.

## Evidence
- Observed 5+ times in session 4937b2e4 (2026-04-05)
- Pattern: All edits consistently target dot_claude/settings.json.tmpl, not ~/.claude/settings.json; scripts/ not deployed paths
- Observer-loop.sh is an exception — it lives in plugin directory, not chezmoi source
- Last observed: 2026-04-05
