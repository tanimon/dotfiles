---
title: "feat: Introduce gstack Claude Code skills"
type: feat
status: active
date: 2026-04-13
---

# feat: Introduce gstack Claude Code skills

## Overview

Add [gstack](https://github.com/garrytan/gstack) — a collection of 23 Claude Code skills (slash commands) by Garry Tan — to the chezmoi-managed dotfiles. gstack provides structured sprint methodology skills (`/office-hours`, `/plan-ceo-review`, `/review`, `/qa`, `/ship`, `/cso`, `/retro`, `/browse`, etc.) that transform Claude Code into a virtual engineering team.

## Problem Frame

Issue [#151](https://github.com/tanimon/dotfiles/issues/151) requests gstack setup. gstack requires `bun` for building its browser automation binary and a `./setup` script to register skills. The dotfiles repo already manages Claude Code skills (Claudeception via `.chezmoiexternal.toml`), so gstack should follow the same established pattern for declarative, SHA-pinned, Renovate-auto-updated external dependency management.

## Requirements Trace

- R1. gstack source is pulled into `~/.claude/skills/gstack/` declaratively via chezmoi
- R2. gstack's `./setup` script runs automatically after extraction to register skills and compile the browse binary
- R3. `bun` is available as a build dependency (required by gstack for compilation)
- R4. Renovate auto-updates the pinned SHA when new commits land on `main`
- R5. Runtime state (`~/.gstack/`) is excluded from chezmoi management
- R6. The setup is idempotent and safe for repeated `chezmoi apply` runs

## Scope Boundaries

- gstack team mode is NOT enabled — chezmoi + Renovate manages updates, not gstack's auto-upgrade hook
- No custom shell init or PATH changes — gstack skills are invoked through Claude Code's skill system directly
- Individual gstack skill symlinks created by `./setup` under `~/.claude/skills/` are NOT managed by chezmoi — they are created at the target by the setup script
- Playwright Chromium installation is handled by gstack's setup script (not separately managed)

## Context & Research

### Relevant Code and Patterns

- `.chezmoiexternal.toml` — existing Claudeception entry is the direct pattern to follow (archive type, SHA-pinned, Renovate comment)
- `.chezmoiscripts/run_onchange_after_link-cco.sh.tmpl` — reference pattern for post-extraction lifecycle script with hash tracking
- `.chezmoiscripts/run_onchange_darwin-install-packages.sh.tmpl` — Brewfile installer with darwin guard and hash tracking
- `darwin/Brewfile` — alphabetical convention for brew entries
- `.chezmoiignore` — existing `.claude/skills/*` exclusions for runtime-managed skills

### Institutional Learnings

- `docs/solutions/integration-issues/chezmoi-v2701-strict-mode-chezmoiexternal-migration-2026-04-12.md` — always use `type = "archive"` (never `git-repo` with `ref`), SHA embedded in URL
- `docs/solutions/integration-issues/chezmoi-external-script-repo-with-renovate-sha-pinning.md` — `url` and `# renovate:` must be adjacent (no intervening TOML keys)
- `docs/solutions/integration-issues/renovate-managerfilepatterns-regex-delimiter.md` — Renovate regex already configured correctly in `renovate.json`

## Key Technical Decisions

- **Archive type over git-repo**: chezmoi v2.70.1 strict mode rejects `git-repo` with `ref`. Archive with SHA in URL is the only valid pinning method (see origin: `docs/solutions/integration-issues/chezmoi-v2701-strict-mode-chezmoiexternal-migration-2026-04-12.md`)
- **`--no-team` flag**: Disable gstack's SessionStart auto-upgrade hook. Renovate handles SHA updates; team mode would conflict with chezmoi's declarative model
- **darwin guard on setup script**: gstack's `./setup` uses `bun` which is macOS-installed via Brewfile. The setup script should be darwin-guarded
- **Hash tracking on `.chezmoiexternal.toml`**: The `run_onchange_after_` script tracks the `.chezmoiexternal.toml` hash (same pattern as cco link script) so setup re-runs when the SHA changes

## Open Questions

### Resolved During Planning

- **Q: Should gstack use team mode?** No — team mode adds a SessionStart hook for auto-upgrade, which conflicts with chezmoi's declarative management. Renovate auto-updates the SHA instead
- **Q: Should individual gstack skill directories be in `.chezmoiignore`?** No — they only exist at the target (created by `./setup`), not in the source tree. chezmoi won't touch them unless explicitly added. Only `~/.gstack/` runtime state needs exclusion
- **Q: Flat vs prefixed skill naming?** Use gstack's default (which creates unprefixed skill names like `/qa`, `/ship`). The user can reconfigure later by re-running setup with `--prefix`

### Deferred to Implementation

- **Exact gstack skill list**: The skills registered depend on the gstack version. The setup script handles this dynamically
- **Playwright Chromium install behavior**: The setup script handles this; no chezmoi intervention needed

## Implementation Units

- [x] **Unit 1: Add bun to Brewfile**

**Goal:** Ensure `bun` is available as a build dependency for gstack's browse binary compilation.

**Requirements:** R3

**Dependencies:** None

**Files:**
- Modify: `darwin/Brewfile`

**Approach:**
- Add `brew "bun"` in alphabetical order among the `brew` entries (after `bat`, before `carapace`)

**Patterns to follow:**
- `darwin/Brewfile` — existing alphabetical ordering convention for `brew` entries

**Test scenarios:**
- Happy path: `brew "bun"` appears in correct alphabetical position; `make lint` passes (oxfmt checks JSON/formatting)

**Verification:**
- `bun` entry is in Brewfile at the correct alphabetical position
- `make lint` passes

- [x] **Unit 2: Add gstack entry to .chezmoiexternal.toml**

**Goal:** Declare gstack as an external archive dependency so chezmoi pulls it to `~/.claude/skills/gstack/`.

**Requirements:** R1, R4

**Dependencies:** None (parallel with Unit 1)

**Files:**
- Modify: `.chezmoiexternal.toml`

**Approach:**
- Add a new TOML section `[".claude/skills/gstack"]` with `type = "archive"`, SHA-pinned URL, `# renovate: branch=main` comment (immediately after `url` — adjacency contract), `stripComponents = 1`, and `refreshPeriod = "168h"`
- Current latest SHA: `c6e6a21d1a9a58e771403260ff6a134898f2dd02`

**Patterns to follow:**
- `.chezmoiexternal.toml` Claudeception entry (exact same structure)
- `.claude/rules/renovate-external.md` — Renovate adjacency contract

**Test scenarios:**
- Happy path: Entry follows the archive pattern with correct TOML syntax; `url` and `# renovate:` comment are adjacent with no intervening keys
- Edge case: Renovate regex in `renovate.json` matches the new entry (verify by pattern inspection — the `matchStrings` regex expects `github.com/<depName>/archive/<sha>.tar.gz` followed by `# renovate: branch=<branch>`)

**Verification:**
- `.chezmoiexternal.toml` has the new gstack entry
- `chezmoi apply --dry-run` shows the gstack extraction (or no error)
- Renovate adjacency contract is preserved (visual inspection)

- [x] **Unit 3: Create run_onchange_after setup script**

**Goal:** Run gstack's `./setup --no-team` after chezmoi extracts the archive, so skills are registered and the browse binary is compiled.

**Requirements:** R2, R6

**Dependencies:** Unit 2

**Files:**
- Create: `.chezmoiscripts/run_onchange_after_setup-gstack.sh.tmpl`

**Approach:**
- darwin guard (`{{ if eq .chezmoi.os "darwin" }}`) wrapping the entire script
- Track `.chezmoiexternal.toml` hash in a comment so the script re-runs when the SHA changes
- Guard for `bun` availability (`command -v bun`) — graceful skip on fresh machines before Brewfile runs
- `cd` to the extracted gstack directory and run `./setup --no-team`
- `set -euo pipefail` for safety

**Patterns to follow:**
- `.chezmoiscripts/run_onchange_after_link-cco.sh.tmpl` — hash tracking on `.chezmoiexternal.toml`, graceful skip pattern
- `.chezmoiscripts/run_onchange_darwin-install-packages.sh.tmpl` — darwin guard, `set -euo pipefail`

**Test scenarios:**
- Happy path: Script runs `./setup --no-team` in the gstack directory; skills are registered
- Edge case: `bun` not installed yet (fresh machine) → script prints warning and exits 0 (graceful skip)
- Edge case: gstack directory doesn't exist (archive extraction failed) → script prints warning and exits 0
- Integration: Script re-runs when `.chezmoiexternal.toml` hash changes (Renovate updates SHA)

**Verification:**
- Script file exists in `.chezmoiscripts/` with correct naming convention
- Script passes `chezmoi execute-template` validation (template syntax is valid)
- `make lint` passes (`.tmpl` files are excluded from shellcheck/shfmt, but template validation catches syntax errors)

- [x] **Unit 4: Update .chezmoiignore for gstack runtime state**

**Goal:** Exclude gstack's runtime state directory from chezmoi management to prevent accidental `chezmoi add`.

**Requirements:** R5

**Dependencies:** None (parallel with other units)

**Files:**
- Modify: `.chezmoiignore`

**Approach:**
- Add `.gstack` entry under the `# ~/.claude/ auto-managed` section (or as a separate commented section for gstack runtime state)
- This prevents `~/.gstack/` (global state, projects, config) from being accidentally added to chezmoi

**Patterns to follow:**
- `.chezmoiignore` — existing `.claude/*` exclusion pattern with comment headers

**Test scenarios:**
- Happy path: `.gstack` entry present in `.chezmoiignore`; `chezmoi managed | grep gstack` shows only `.claude/skills/gstack` (from `.chezmoiexternal.toml`), not `.gstack`

**Verification:**
- `.chezmoiignore` includes `.gstack` exclusion
- `chezmoi managed` does not include `.gstack` paths

## System-Wide Impact

- **Interaction graph:** `chezmoi apply` → extracts archive → `run_onchange_after_` triggers → `./setup` creates skill symlinks under `~/.claude/skills/` and compiles browse binary. Brewfile installer runs separately and provides `bun`
- **Error propagation:** If `bun` is missing, the setup script skips gracefully. If archive extraction fails, chezmoi reports the error and the setup script has no directory to operate on (graceful skip)
- **State lifecycle risks:** Archive re-extraction resets the gstack directory (including compiled `browse/dist/browse`). The setup script is idempotent and recompiles as needed. User preferences in `bin/gstack-config` are reset on re-extraction — this is acceptable since we use `--no-team` explicitly
- **Unchanged invariants:** Existing Claudeception and cco entries in `.chezmoiexternal.toml` are not modified. Existing `.chezmoiignore` patterns are preserved. No changes to Renovate regex configuration (it already matches the pattern)

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| `bun` not installed when setup runs (fresh machine ordering) | Guard with `command -v bun` — skip gracefully. Next `chezmoi apply` after Brewfile runs will succeed |
| gstack `./setup` modifies Claude Code settings (team mode hooks) | Use `--no-team` flag to prevent settings modification |
| Archive re-extraction resets compiled artifacts | Setup script is idempotent; recompilation is fast (~seconds) |
| gstack individual skill names may conflict with existing skills | gstack uses distinctive names; check for conflicts post-setup |

## Sources & References

- Related issue: [#151](https://github.com/tanimon/dotfiles/issues/151)
- External: [garrytan/gstack](https://github.com/garrytan/gstack)
- Related code: `.chezmoiexternal.toml`, `.chezmoiscripts/run_onchange_after_link-cco.sh.tmpl`
- Related solution: `docs/solutions/integration-issues/chezmoi-v2701-strict-mode-chezmoiexternal-migration-2026-04-12.md`
- Related solution: `docs/solutions/integration-issues/chezmoi-external-script-repo-with-renovate-sha-pinning.md`
