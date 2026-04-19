---
title: "fix: Update enabled plugin name from `ecc` to `everything-claude-code`"
type: fix
status: active
date: 2026-04-19
---

# fix: Update enabled plugin name from `ecc` to `everything-claude-code`

## Overview

The `everything-claude-code` marketplace reorganized its plugin layout: the previous `ecc` plugin is gone, and the marketplace now exposes a single plugin named `everything-claude-code` (v1.10.0). Claude Code now logs the following on startup:

```
ecc @ everything-claude-code (user)
      Plugin "ecc" not found in marketplace "everything-claude-code"
      Plugin may not exist in marketplace "everything-claude-code"
```

Update the chezmoi-managed `dot_claude/settings.json.tmpl` to enable the renamed plugin and stop referencing the missing `ecc` plugin.

## Problem Frame

`dot_claude/settings.json.tmpl` line 238 still has `"ecc@everything-claude-code": true` in `enabledPlugins`. The marketplace manifest (`~/.claude/plugins/marketplaces/everything-claude-code/.claude-plugin/marketplace.json`) now lists only `everything-claude-code` as an installable plugin name. Claude Code is therefore trying to enable a plugin that does not exist anymore.

The runtime install state (`~/.claude/plugins/installed_plugins.json`) currently contains BOTH `ecc@everything-claude-code` (stale) and `everything-claude-code@everything-claude-code` (current, installed 2026-02-09, last-updated 2026-04-19). That file is intentionally NOT managed by chezmoi (per `CLAUDE.md` plugin install/enable state policy), so cleaning it up is a runtime user action, not part of the chezmoi diff.

## Requirements Trace

- R1. `dot_claude/settings.json.tmpl` no longer enables the non-existent `ecc@everything-claude-code` plugin.
- R2. The functionally equivalent plugin (`everything-claude-code@everything-claude-code`) is enabled in its place so the user keeps the same capabilities (rules, agents, skills) on next `chezmoi apply`.
- R3. `chezmoi apply --dry-run` succeeds and `make lint` passes.
- R4. The fix surfaces a clear runtime cleanup note for the user (uninstall the stale `ecc` entry) since chezmoi cannot do it.

## Scope Boundaries

- Out of scope: Modifying `installed_plugins.json` (runtime state, not chezmoi-managed).
- Out of scope: Renaming `run_onchange_after_install-ecc-rules.sh.tmpl` or the `ECC_*` variable names in it. The script targets the marketplace directory (`~/.claude/plugins/marketplaces/everything-claude-code/rules`), not the plugin name. It still works correctly.
- Out of scope: Renaming the `dot_claude/skills/ecc-observer-diagnosis/` skill — its name refers to the ECC continuous-learning observer (a hooks-based system bundled with the marketplace), not the plugin identifier.
- Out of scope: Touching `dot_claude/ecc-rules-languages.txt` — its filename and contents are unaffected by the plugin rename.

## Context & Research

### Relevant Code and Patterns

- `dot_claude/settings.json.tmpl` line 238 — the single line that needs to change.
- `dot_claude/settings.json.tmpl` lines 226–239 — `enabledPlugins` map showing the existing key/value style to mirror.
- `~/.claude/plugins/marketplaces/everything-claude-code/.claude-plugin/marketplace.json` — confirms the new authoritative plugin name.
- `dot_claude/plugins/marketplaces.txt` — declarative marketplace list (already correct, no change needed).
- `.chezmoiscripts/run_onchange_after_install-ecc-rules.sh.tmpl` — copies rules from the marketplace to `~/.claude/rules/`. Verified independent of plugin name (still functional after rename; rules directory exists at the same path).

### Institutional Learnings

- `docs/solutions/integration-issues/ecc-plugin-enablement-and-selective-rules-install-2026-04-03.md` — captures the original ECC plugin enablement approach. Worth a follow-up note that the plugin identifier changed, but not strictly required for this fix.
- `CLAUDE.md` ("declarative marketplace sync"): plugin install/enable state files are explicitly NOT chezmoi-managed; only `enabledPlugins` in `settings.json.tmpl` is.

## Key Technical Decisions

- **Replace the key in place rather than removing it.** The user clearly wants the marketplace's plugin enabled (they had it on before the rename); replacing `ecc@everything-claude-code` with `everything-claude-code@everything-claude-code` preserves intent and keeps the rules/agents/skills available.
- **Do not touch `installed_plugins.json` from chezmoi.** That file is runtime state. Surface the cleanup as a manual step in the PR description and the post-deploy note.

## Open Questions

### Resolved During Planning

- "Does the rule-install script need updating?" — No. It targets the marketplace directory layout, not the plugin name. Verified by reading the script and listing `~/.claude/plugins/marketplaces/everything-claude-code/rules/`.
- "Should the skill `ecc-observer-diagnosis` be renamed?" — No. It refers to the ECC continuous-learning observer feature, not the plugin identifier.

### Deferred to Implementation

- Whether to additionally update `docs/solutions/integration-issues/ecc-plugin-enablement-and-selective-rules-install-2026-04-03.md` with a postscript noting the rename. Decide during implementation; out of scope for the minimum fix but a candidate for a small follow-up.

## Implementation Units

- [ ] **Unit 1: Replace `ecc@everything-claude-code` with `everything-claude-code@everything-claude-code` in enabledPlugins**

**Goal:** Stop trying to enable the non-existent `ecc` plugin; enable the renamed `everything-claude-code` plugin instead.

**Requirements:** R1, R2

**Dependencies:** None

**Files:**
- Modify: `dot_claude/settings.json.tmpl`

**Approach:**
- Edit line 238: change the key `"ecc@everything-claude-code"` to `"everything-claude-code@everything-claude-code"`. Keep the value `true` and the surrounding formatting unchanged.
- Keep the entry's position in the map (preserves diff readability).

**Patterns to follow:**
- Match the existing two-segment `<plugin>@<marketplace>: <bool>` style used elsewhere in the same `enabledPlugins` block (e.g., `"superpowers@claude-plugins-official": true`).

**Test scenarios:**
- Happy path: `make check-templates` succeeds — the template still parses with valid JSON output for all profiles.
- Happy path: `chezmoi apply --dry-run` succeeds and shows the single expected diff for `~/.claude.json` (or whatever the deployed target is).
- Happy path: After `chezmoi apply`, opening Claude Code no longer prints the `Plugin "ecc" not found` warning, and the `everything-claude-code` plugin is listed as enabled by `claude plugin list`.
- Edge case: `make lint` continues to pass (no new shellcheck/oxfmt/etc. regressions, since the change is JSON template content, not script logic).

**Verification:**
- `grep -n 'ecc@everything-claude-code' dot_claude/settings.json.tmpl` returns no matches.
- `grep -n 'everything-claude-code@everything-claude-code' dot_claude/settings.json.tmpl` returns exactly one match in the `enabledPlugins` block.

## System-Wide Impact

- **Interaction graph:** `dot_claude/settings.json.tmpl` is rendered by chezmoi into the user's Claude Code settings; the `enabledPlugins` map is read by Claude Code at startup. No other systems depend on the specific key `ecc@everything-claude-code`.
- **State lifecycle risks:** None from chezmoi's side. However, `~/.claude/plugins/installed_plugins.json` retains a stale `ecc@everything-claude-code` entry. Until the user runs `claude plugin uninstall ecc@everything-claude-code` (or deletes the stale entry), Claude Code may continue to log the warning even after `chezmoi apply` because runtime install state and enable state are separate. Surface this in the PR description / runtime cleanup note.
- **Unchanged invariants:**
  - `dot_claude/plugins/marketplaces.txt` is unchanged — `affaan-m/everything-claude-code` was and still is the correct marketplace.
  - `.chezmoiscripts/run_onchange_after_install-ecc-rules.sh.tmpl` is unchanged — its hash remains stable, so it does not re-run; the rules directory layout is unaffected by the plugin rename.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| User assumes `chezmoi apply` alone clears the warning, but stale runtime state in `installed_plugins.json` keeps it firing. | Call out the manual `claude plugin uninstall ecc@everything-claude-code` (and/or `claude plugin disable`) step in the PR description and runtime note. |
| Future marketplace renames could repeat this issue. | Out of scope for this fix, but a future improvement could be a Make target that diffs `enabledPlugins` keys against the actual marketplace manifests. Note as a follow-up, not a blocker. |

## Documentation / Operational Notes

- After merge and `chezmoi apply`, advise the user to run `claude plugin uninstall ecc@everything-claude-code` to remove the stale entry from `installed_plugins.json` and silence the warning permanently.
- Optional follow-up: append a postscript to `docs/solutions/integration-issues/ecc-plugin-enablement-and-selective-rules-install-2026-04-03.md` recording the 2026-04 rename so future readers understand the plugin identifier change.

## Sources & References

- Affected file: `dot_claude/settings.json.tmpl` (line 238)
- Marketplace manifest (runtime, not in repo): `~/.claude/plugins/marketplaces/everything-claude-code/.claude-plugin/marketplace.json`
- Runtime state (not chezmoi-managed): `~/.claude/plugins/installed_plugins.json`
- Related solution doc: `docs/solutions/integration-issues/ecc-plugin-enablement-and-selective-rules-install-2026-04-03.md`
- Related script (no change required): `.chezmoiscripts/run_onchange_after_install-ecc-rules.sh.tmpl`
