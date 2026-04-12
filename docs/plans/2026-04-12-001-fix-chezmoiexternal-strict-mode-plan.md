---
title: "fix: Migrate .chezmoiexternal.toml from git-repo to archive for chezmoi v2.70.1 strict mode"
type: fix
status: active
date: 2026-04-12
---

# fix: Migrate .chezmoiexternal.toml from git-repo to archive for chezmoi v2.70.1 strict mode

## Overview

chezmoi v2.70.1 introduced strict TOML parsing (commit `dd03362`) that rejects unknown fields in config files. The `ref` field used in `.chezmoiexternal.toml` is not a recognized field for `git-repo` type entries — it was silently ignored in prior versions. Migrate both entries from `type = "git-repo"` + `ref` to `type = "archive"` with SHA-pinned GitHub archive URLs, and update Renovate's regex custom manager to match the new URL pattern.

## Problem Frame

`chezmoi diff` (and all other chezmoi commands) fail with:
```
chezmoi: .chezmoiexternal.toml: strict mode: fields in the document are missing in the target struct
```

The `ref` field was never functional — chezmoi always cloned the default branch HEAD regardless of the `ref` value. This migration fixes the error and achieves actual SHA pinning for the first time.

## Requirements Trace

- R1. `chezmoi diff` and `chezmoi apply` must succeed without errors
- R2. External entries must be pinned to specific commit SHAs (supply-chain safety)
- R3. Renovate must continue auto-updating SHAs via the regex custom manager
- R4. Target file paths must remain unchanged (`~/.claude/skills/claudeception/`, `~/.local/share/cco/`)
- R5. `run_onchange_after_link-cco.sh.tmpl` must continue to work (it tracks `.chezmoiexternal.toml` hash)

## Scope Boundaries

- Only changing file format/type — not adding or removing external entries
- Not modifying the `run_onchange_after_link-cco.sh.tmpl` script (it works as-is since it tracks the `.chezmoiexternal.toml` hash)
- Not filing a chezmoi feature request for `git-repo` ref support (separate concern)

## Context & Research

### Relevant Code and Patterns

- `.chezmoiexternal.toml` — current git-repo entries with invalid `ref` field
- `renovate.json` — regex custom manager matching `url + # renovate: branch= + ref` pattern
- `.claude/rules/renovate-external.md` — documents the adjacency contract
- `.chezmoiscripts/run_onchange_after_link-cco.sh.tmpl` — symlinks cco, tracks `.chezmoiexternal.toml` hash

### Institutional Learnings

- `docs/solutions/integration-issues/chezmoi-external-script-repo-with-renovate-sha-pinning.md` — original solution record for the `ref` pattern. Documents the Renovate adjacency contract, which needs updating.

## Key Technical Decisions

- **`type = "archive"` over alternative approaches**: Archive URLs embed the SHA directly in the URL, achieving actual pinning (unlike the broken `ref` field). `clone.args` cannot accept SHAs (`git clone --branch` only supports branches/tags). Archive type also eliminates `.git/` overhead in target directories.
- **`stripComponents = 1`**: GitHub archive tarballs wrap contents in a `owner-repo-sha/` directory. `stripComponents = 1` strips this so files land directly in the target path, matching the previous `git-repo` layout.
- **New Renovate adjacency contract**: URL line (containing SHA) + `# renovate: branch=` comment must remain adjacent. The `ref` line is removed entirely.

## Implementation Units

- [ ] **Unit 1: Migrate .chezmoiexternal.toml to archive type**

**Goal:** Replace `type = "git-repo"` + `ref` with `type = "archive"` + SHA-embedded URL for both entries.

**Requirements:** R1, R2, R4

**Dependencies:** None

**Files:**
- Modify: `.chezmoiexternal.toml`

**Approach:**
- Change `type` from `"git-repo"` to `"archive"` for both entries
- Replace `url` with GitHub archive URL: `https://github.com/{owner}/{repo}/archive/{sha}.tar.gz`
- Remove `.git` suffix from URL (archive URLs don't use it)
- Remove `ref` field entirely
- Add `stripComponents = 1` to preserve target directory structure
- Keep `refreshPeriod` unchanged
- Keep `# renovate: branch=` comment (now immediately after `url` line)

**Test scenarios:**
- Happy path: `chezmoi diff` completes without strict mode error
- Happy path: `chezmoi apply --dry-run` shows no unexpected changes (or shows expected archive download)
- Edge case: Verify target paths remain `~/.claude/skills/claudeception/` and `~/.local/share/cco/`

**Verification:**
- `chezmoi diff` succeeds without error
- `chezmoi managed --path-style absolute | grep -E 'claudeception|cco'` shows expected paths

- [ ] **Unit 2: Update Renovate regex custom manager**

**Goal:** Update the regex pattern to extract depName, currentDigest, and currentValue from the new archive URL format.

**Requirements:** R3

**Dependencies:** Unit 1

**Files:**
- Modify: `renovate.json`

**Approach:**
- New regex matches: `url = "https://github.com/{depName}/archive/{currentDigest}.tar.gz"` followed by `# renovate: branch={currentValue}`
- `depName`: extracted from URL path (`owner/repo`)
- `currentDigest`: SHA extracted from URL path (before `.tar.gz`)
- `currentValue`: branch name from the `# renovate: branch=` comment
- `datasourceTemplate` and `packageNameTemplate` remain unchanged (`git-refs`)

**Test scenarios:**
- Happy path: Renovate regex matches both entries in `.chezmoiexternal.toml` (verify via Renovate dry-run or local regex test)

**Verification:**
- Regex pattern correctly matches the new TOML format (testable locally with a regex tool)

- [ ] **Unit 3: Update adjacency contract documentation**

**Goal:** Update rule file and solution document to reflect the new archive-based format.

**Requirements:** Accuracy of agent-facing documentation

**Dependencies:** Unit 1, Unit 2

**Files:**
- Modify: `.claude/rules/renovate-external.md`
- Modify: `docs/solutions/integration-issues/chezmoi-external-script-repo-with-renovate-sha-pinning.md`

**Approach:**
- Update the adjacency contract example in `renovate-external.md` to show the new URL + comment format
- Update the "Adding a New External Entry" instructions
- Add a note to the solution document about the v2.70.1 migration
- Remove references to the `ref` field being functional

**Test scenarios:**
- Test expectation: none — documentation-only changes

**Verification:**
- Contract example in rule file matches actual `.chezmoiexternal.toml` format
- `make lint` passes (no linting regressions)

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Existing git-cloned targets may conflict with archive extraction | If `chezmoi apply` fails, remove old targets (`~/.claude/skills/claudeception/`, `~/.local/share/cco/`) and re-apply |
| Archive URL may behave differently from git-clone for large repos | Both repos are small; verified HTTP 200 for both archive URLs |
| Renovate regex may not match on first try | Test regex locally before merging; Renovate dashboard shows match status |
