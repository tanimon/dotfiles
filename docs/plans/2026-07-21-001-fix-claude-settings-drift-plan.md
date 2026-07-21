---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
title: "fix: Reflect ~/.claude/settings.json drift into source template"
created: 2026-07-21
type: fix
depth: lightweight
---

# fix: Reflect ~/.claude/settings.json drift into source template

## Summary

The deployed target `~/.claude/settings.json` has drifted from its chezmoi source
template `dot_claude/settings.json.tmpl`. Claude Code enabled two plugins at runtime
that the source template does not declare. Reflect that substantive drift back into
the source so `chezmoi apply` stops trying to revert it.

**Product Contract preservation:** N/A — solo bootstrap, no upstream requirements doc.

---

## Problem Frame

`dot_claude/settings.json.tmpl` is a fully-owned chezmoi `.tmpl` file, but Claude Code
also writes to the deployed `~/.claude/settings.json` at runtime (e.g. when a plugin is
enabled). This creates inherent drift. `chezmoi diff ~/.claude/settings.json` currently
reports two distinct differences:

1. **Substantive drift (in scope).** The deployed target's `enabledPlugins` map contains
   two entries absent from the source template:
   - `skill-creator@claude-plugins-official`
   - `sentry@claude-plugins-official`

   These reflect a real user intent (plugins were enabled) that the source has not
   captured. On the next `chezmoi apply`, the source would disable them — reverting a
   deliberate change.

2. **Cosmetic diff (out of scope).** Within the `sandbox` block, the deployed file orders
   keys as `network, filesystem, excludedCommands` (and `network` as
   `allowedDomains, allowLocalBinding`), whereas the source template orders them
   `excludedCommands, filesystem, network` (and `network` as
   `allowLocalBinding, allowedDomains`). The JSON is **semantically identical** — only key
   order differs, produced by Claude Code's re-serialization. Reflecting this into the
   source would fight the template's intentional ordering and inline `{{/* … */}}` comments,
   and Claude Code would likely re-drift it on the next write. See Scope Boundaries.

The task ("source file に変更を反映して") is to bring the source template up to date with
the deployed state, i.e. the reverse of `chezmoi apply`.

---

## Requirements

- **R1.** The source template `dot_claude/settings.json.tmpl` must declare
  `skill-creator@claude-plugins-official: true` and `sentry@claude-plugins-official: true`
  in `enabledPlugins`.
- **R2.** After the change, `chezmoi diff ~/.claude/settings.json` must report no
  substantive difference in `enabledPlugins` (only the cosmetic sandbox key-order diff may
  remain).
- **R3.** The template must still render as valid JSON (`make check-templates` passes).

---

## Key Technical Decisions

- **KTD1: Edit only the `enabledPlugins` block; leave `sandbox` untouched.** The sandbox
  diff is a pure key-order artifact of Claude Code's serializer, semantically a no-op.
  Rewriting the template to match it would churn hand-authored ordering + comments for no
  behavioral gain and would not durably stop the drift (Claude Code owns that serialization
  order). Focusing on the plugins keeps the change minimal and meaningful.
- **KTD2: Append the two entries after `ecc@ecc`.** Preserve the existing ordering
  convention of the map (new entries appended last), matching how the deployed file grew.
  Note the trailing-comma shift: `ecc@ecc` gains a comma when it is no longer the last key.

---

## Implementation Units

### U1. Add the two drifted plugins to the source template

**Goal:** Declare `skill-creator@claude-plugins-official` and
`sentry@claude-plugins-official` as enabled in the source template's `enabledPlugins` map.

**Requirements:** R1, R2, R3

**Dependencies:** none

**Files:**
- `dot_claude/settings.json.tmpl` (modify — `enabledPlugins` block, around line 375)

**Approach:**
Change the final map entry so `ecc@ecc` gains a trailing comma, then append the two new
`true` entries as the last keys:

```
    "ecc@ecc": true,
    "skill-creator@claude-plugins-official": true,
    "sentry@claude-plugins-official": true
```

Do not touch the `sandbox` block or any other section.

**Patterns to follow:** Existing `enabledPlugins` entries in the same block (bare
`"name@marketplace": true|false` lines). Both new plugins come from the
`claude-plugins-official` marketplace, which is already registered in the deployed state —
no `extraKnownMarketplaces` change needed.

**Test expectation: none — configuration/template-only change.** Verified by lint + diff,
not unit tests.

**Verification:**
- `make check-templates` passes (template renders as valid JSON).
- `chezmoi diff ~/.claude/settings.json` shows the `enabledPlugins` entries no longer
  differ; only the cosmetic sandbox key-order diff may remain.
- Optionally `chezmoi apply --dry-run ~/.claude/settings.json` shows no plugin-disabling
  change.

---

## Scope Boundaries

**In scope:**
- Adding the two enabled plugins to `dot_claude/settings.json.tmpl` (U1).

**Out of scope (non-goals):**
- The `sandbox` block key-ordering diff — semantically identical JSON; reflecting it is
  churn that Claude Code would re-drift. Left as-is deliberately (KTD1).

### Deferred to Follow-Up Work
- If the cosmetic sandbox key-order diff becomes noisy enough to warrant it, a separate
  follow-up could investigate normalizing the template ordering to match Claude Code's
  serializer — but only if the churn proves worthwhile.

---

## Verification Contract

1. `make check-templates` — template renders as valid JSON.
2. `chezmoi diff ~/.claude/settings.json` — no substantive `enabledPlugins` diff remains.
3. `make lint` (or at minimum the template + secret checks) before commit, per repo CI parity.

## Definition of Done

- `dot_claude/settings.json.tmpl` declares both drifted plugins as enabled.
- Template checks and repo lint pass.
- `chezmoi diff` confirms the substantive plugin drift is resolved.
