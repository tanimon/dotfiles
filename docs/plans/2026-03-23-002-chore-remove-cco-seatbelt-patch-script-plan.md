---
title: "chore: remove cco Seatbelt patch script (upstream fix merged)"
type: chore
status: completed
date: 2026-03-23
---

# chore: remove cco Seatbelt patch script (upstream fix merged)

## Overview

Upstream PR [nikvdp/cco#50](https://github.com/nikvdp/cco/pull/50) merged on 2026-03-21. Renovate has already bumped the ref in `.chezmoiexternal.toml` to `42fc44e` (which is ahead of the merge commit `da367dd`). The local patch script `run_onchange_after_patch-cco-sandbox.sh.tmpl` is now self-disabling via its idempotency check and can be removed entirely.

## Acceptance Criteria

- [ ] Delete `.chezmoiscripts/run_onchange_after_patch-cco-sandbox.sh.tmpl`
- [ ] Update `CLAUDE.md` — remove the `run_onchange_after_patch-cco-sandbox.sh.tmpl` reference from the "Claude Code sandbox" paragraph
- [ ] Verify `chezmoi apply --dry-run` shows no errors

## Context

### Verification that upstream fix is live

| Check | Result |
|-------|--------|
| PR #50 state | MERGED (2026-03-21) |
| Merge commit | `da367ddc93f1` |
| Current `.chezmoiexternal.toml` ref | `42fc44e5ecc0` |
| Ref includes fix? | Yes (ahead of merge commit) |
| Renovate PR | `42648f0` — "chore(deps): update nikvdp/cco digest to 42fc44e (#42)" |

### Files to modify

1. **DELETE** `.chezmoiscripts/run_onchange_after_patch-cco-sandbox.sh.tmpl` — the patch script itself
2. **EDIT** `CLAUDE.md:56` — remove `, and \`run_onchange_after_patch-cco-sandbox.sh.tmpl\` patches the Seatbelt profile for Node.js compatibility` from the sandbox description

### What NOT to change

- `run_onchange_after_link-cco.sh.tmpl` — still needed for cco binary symlink
- `.chezmoiexternal.toml` — cco entry still needed for Linux fallback
- `dot_config/safehouse/config.tmpl` — unrelated to this cleanup
- Memory files in `~/.claude/projects/` — update separately if needed

## MVP

### Step 1: Delete patch script

```bash
rm .chezmoiscripts/run_onchange_after_patch-cco-sandbox.sh.tmpl
```

### Step 2: Update CLAUDE.md

In the "Claude Code sandbox" paragraph (line 56), change:

```
cco is still pulled via `.chezmoiexternal.toml` for Linux fallback; `run_onchange_after_link-cco.sh.tmpl` symlinks the binary, and `run_onchange_after_patch-cco-sandbox.sh.tmpl` patches the Seatbelt profile for Node.js compatibility.
```

To:

```
cco is still pulled via `.chezmoiexternal.toml` for Linux fallback; `run_onchange_after_link-cco.sh.tmpl` symlinks the binary.
```

### Step 3: Verify

```bash
chezmoi apply --dry-run
```

## Sources

- Upstream PR: https://github.com/nikvdp/cco/pull/50
- Renovate bump: commit `42648f0` on main
