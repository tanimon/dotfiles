---
title: "feat: Launch Claude Code in auto permission mode by default"
type: feat
date: 2026-06-19
status: ready
depth: lightweight
---

# feat: Launch Claude Code in auto permission mode by default

## Summary

Change the chezmoi-managed Claude Code settings template so that new sessions
start in the **`auto`** permission mode instead of the standard `default` mode.
This is a one-line value change to `permissions.defaultMode` in
`dot_claude/settings.json.tmpl`.

---

## Problem Frame

Today every Claude Code session starts in `default` mode, which prompts for
permission on the first use of each tool. The user wants sessions to start in
`auto` mode — auto-approves tool calls with background safety checks that verify
actions align with the request (currently a Claude Code research-preview mode).

The setting lives in the chezmoi source template, so the change must be made to
the source (`dot_claude/settings.json.tmpl`), not the deployed target
(`~/.claude/settings.json`), per the repo's "never edit deployed targets
directly" rule.

---

## Requirements

- **R1.** `permissions.defaultMode` resolves to `"auto"` after `chezmoi apply`.
- **R2.** The rendered settings file remains valid JSON and validates against the
  declared `$schema`.
- **R3.** No other settings (env, permissions allow/deny, hooks, plugins) are
  altered.

---

## Key Technical Decisions

- **Use `"auto"` as the exact value.** Verified against the Claude Code
  permissions documentation and the JSON schema
  (`https://json.schemastore.org/claude-code-settings.json`): `auto` is a valid
  `defaultMode` enum value ("Auto-approves tool calls with background safety
  checks", research preview). No fallback to `acceptEdits`/`bypassPermissions`
  is needed because `auto` is supported.
- **Edit the template source, not the target.** Change
  `dot_claude/settings.json.tmpl` line `"defaultMode": "default"`. The `.tmpl`
  file is a regular Go template chezmoi fully owns (no `modify_`/external-tool
  concerns), so a direct value edit is correct.

---

## Implementation Units

### U1. Switch `defaultMode` to `auto` in the settings template

**Goal:** Make `auto` the default permission mode for all Claude Code sessions.

**Requirements:** R1, R2, R3

**Dependencies:** none

**Files:**
- `dot_claude/settings.json.tmpl` (modify) — change `"defaultMode": "default"`
  to `"defaultMode": "auto"` (currently around line 146).

**Approach:** Single-token value replacement inside the existing `permissions`
object. Leave surrounding keys (`allow`, `deny`, `additionalDirectories`)
untouched. This file is not a `modify_` script and has no OS guards, so a plain
value edit is safe.

**Patterns to follow:** Existing key/value style in the same `permissions` block.

**Test scenarios:**
- Covers R2. `make check-templates` — the template renders without error and the
  output is valid JSON. (This is the repo's standard template validation gate.)
- Covers R1. Manual verification: `chezmoi execute-template` / `chezmoi apply
  --dry-run` (or `chezmoi cat ~/.claude/settings.json`) shows
  `"defaultMode": "auto"` in the rendered output.

**Verification:** `make lint` passes (includes `check-templates`), and a dry-run
render of the settings file shows `defaultMode` equal to `auto` with all other
keys unchanged.

---

## Scope Boundaries

**In scope:** The single `defaultMode` value change in
`dot_claude/settings.json.tmpl`.

**Out of scope / non-goals:**
- Changing the `sandbox.enabled` flag or any permission `allow`/`deny` rules.
- Adding documentation about the `auto` research-preview mode to `CLAUDE.md`
  (could be a follow-up if the mode graduates from preview).

### Deferred to Follow-Up Work

- None.

---

## Risks & Dependencies

- **`auto` is a research-preview mode.** Behavior may change in future Claude
  Code releases, and older Claude Code versions may not recognize the value. If
  an installed version does not support `auto`, Claude Code may fall back to
  `default` or warn. Low risk for this user's setup; revertible by changing the
  value back. No code dependency.
