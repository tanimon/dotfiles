---
title: "feat: Declarative ECC rules installation via chezmoi"
type: feat
status: completed
date: 2026-04-03
---

# feat: Declarative ECC rules installation via chezmoi

## Overview

Replace user-curated rules in `dot_claude/rules/` with ECC-provided rules for common, typescript, golang, and web categories. Manage the installation declaratively via chezmoi's `run_onchange_` pattern, copying specific rule directories from the ECC marketplace directory to `~/.claude/rules/`. Retain user-specific rules that ECC does not provide.

## Problem Frame

The user currently maintains hand-curated rules in `dot_claude/rules/` that overlap significantly with ECC's rules. ECC rules are more comprehensive (e.g., ECC's `common/` has 10 files vs user's 7, and ECC provides `web/` rules the user lacks entirely). The user wants ECC rules as the primary source while preserving user-specific rules (harness-engineering, documentation-language, github-actions) that ECC does not offer.

## Requirements Trace

- R1. Install ECC rules for common, typescript, golang, and web to `~/.claude/rules/`
- R2. Manage the installation configuration declaratively via chezmoi
- R3. Preserve user-specific rules that ECC does not provide (documentation-language.md, github-actions.md, harness-engineering.md)
- R4. Re-install rules when ECC marketplace updates or rule language config changes
- R5. Follow the existing declarative sync pattern (text list + `run_onchange_` script)

## Scope Boundaries

- NOT running ECC's `install.sh` — it installs ALL rules + agents + commands via module system, not selective rule directories
- NOT adding new languages beyond what the user requested (common, typescript, golang, web)
- NOT modifying ECC's own rule content — rules are used as-is from the marketplace

## Context & Research

### Relevant Code and Patterns

- `dot_claude/plugins/marketplaces.txt` + `.chezmoiscripts/run_onchange_after_add-marketplaces.sh.tmpl` — declarative sync pattern
- `dot_config/gh/extensions.txt` + `.chezmoiscripts/run_onchange_after_install-gh-extensions.sh.tmpl` — same pattern
- ECC rules source: `~/.claude/plugins/marketplaces/everything-claude-code/rules/`
- ECC rules structure: `rules/{common,golang,typescript,web}/*.md`

### Rule Overlap Analysis

| File | User has | ECC has | Action |
|------|----------|---------|--------|
| `common/coding-style.md` | Yes | Yes | Remove user's, use ECC's |
| `common/git-workflow.md` | Yes | Yes | Remove user's, use ECC's |
| `common/security.md` | Yes | Yes | Remove user's, use ECC's |
| `common/testing.md` | Yes | Yes | Remove user's, use ECC's |
| `common/documentation-language.md` | Yes | No | **Keep** — user-specific |
| `common/github-actions.md` | Yes | No | **Keep** — user-specific |
| `common/harness-engineering.md` | Yes | No | **Keep** — user-specific |
| `common/agents.md` | No | Yes | Installed by ECC |
| `common/code-review.md` | No | Yes | Installed by ECC |
| `common/development-workflow.md` | No | Yes | Installed by ECC |
| `common/hooks.md` | No | Yes | Installed by ECC |
| `common/patterns.md` | No | Yes | Installed by ECC |
| `common/performance.md` | No | Yes | Installed by ECC |
| `golang/*` (5 files) | Yes | Yes (5 files) | Remove user's, use ECC's |
| `typescript/coding-style.md` | Yes | Yes | Remove user's, use ECC's |
| `typescript/{hooks,patterns,security,testing}.md` | No | Yes | Installed by ECC |
| `web/*` (7 files) | No | Yes | New — installed by ECC |

### Coexistence Model

chezmoi and the `run_onchange_` script write to the same `~/.claude/rules/` directory but manage different files:
- **chezmoi manages**: user-specific files (documentation-language.md, github-actions.md, harness-engineering.md)
- **ECC script manages**: all other rule files in the configured directories

chezmoi does not delete files absent from the source tree — it only manages files present in `dot_claude/rules/`. ECC-installed files coexist safely.

### Institutional Learnings

- `docs/solutions/integration-issues/chezmoi-declarative-marketplace-sync-over-bidirectional.md` — declarative list + `run_onchange_` + CLI is the canonical pattern
- `docs/solutions/integration-issues/chezmoi-apply-overwrites-runtime-plugin-changes.md` — never use regular templates for externally-managed files

## Key Technical Decisions

- **Direct copy instead of install.sh**: ECC's `install.sh` installs entire modules (all languages, agents, commands). Direct `cp -r` from the marketplace directory gives selective control over which rule categories to install.
- **Text list for language config**: A `dot_claude/ecc-rules-languages.txt` file lists which rule categories to install (one per line). This follows the existing declarative sync pattern and triggers re-installation when languages change.
- **Hash tracking on marketplace directory**: The `run_onchange_` script tracks both the language list hash AND a marker for ECC marketplace content changes, ensuring rules update when ECC updates.
- **Remove overlapping user rules, keep unique ones**: Files that ECC provides are removed from `dot_claude/rules/`. Files ECC doesn't provide stay and coexist.

## Open Questions

### Resolved During Planning

- **Q: Should we use install.sh or direct copy?** → Direct copy. install.sh is too coarse-grained (installs all rules, not selective categories).
- **Q: Will chezmoi delete ECC-installed files?** → No. chezmoi only manages files in the source tree. ECC-installed files are not in `dot_claude/rules/` and are not tracked.
- **Q: Should we track ECC marketplace version?** → Track a content hash marker. The marketplace auto-updates, and the script should re-run when content changes.

### Deferred to Implementation

- **Exact hash marker for ECC marketplace**: Whether to hash a VERSION file, the rules directory listing, or a specific file from the marketplace. Will be determined based on what's stable and available.

## Implementation Units

- [ ] **Unit 1: Create ECC rules language list**

**Goal:** Create a text list of rule categories to install from ECC

**Requirements:** R2, R5

**Dependencies:** None

**Files:**
- Create: `dot_claude/ecc-rules-languages.txt`

**Approach:**
- One rule category per line: `common`, `typescript`, `golang`, `web`
- Same format as `dot_claude/plugins/marketplaces.txt` and `dot_config/gh/extensions.txt`

**Patterns to follow:**
- `dot_claude/plugins/marketplaces.txt`
- `dot_config/gh/extensions.txt`

**Test scenarios:**
- Test expectation: none -- pure config file, no behavioral change

**Verification:**
- File exists with 4 entries (common, typescript, golang, web)
- `chezmoi managed` shows the file

- [ ] **Unit 2: Create run_onchange_ script for ECC rules installation**

**Goal:** Create a script that copies ECC rules from marketplace to `~/.claude/rules/`

**Requirements:** R1, R2, R4, R5

**Dependencies:** Unit 1

**Files:**
- Create: `.chezmoiscripts/run_onchange_after_install-ecc-rules.sh.tmpl`

**Approach:**
- Track hash of `dot_claude/ecc-rules-languages.txt` for re-run on language changes
- Track hash of ECC marketplace `rules/` content (use VERSION file or directory listing) for re-run on ECC updates
- Source: `~/.claude/plugins/marketplaces/everything-claude-code/rules/<category>/`
- Destination: `~/.claude/rules/<category>/`
- Use `cp -r` for each category listed in the language file
- Include tool guard for marketplace directory existence
- Use `set -euo pipefail` and the standard script header

**Patterns to follow:**
- `.chezmoiscripts/run_onchange_after_add-marketplaces.sh.tmpl` — hash tracking, tool guards, iteration over list
- `.chezmoiscripts/run_onchange_after_install-gh-extensions.sh.tmpl` — same pattern

**Test scenarios:**
- Happy path: Script copies rules from marketplace to `~/.claude/rules/` for each listed category
- Happy path: Adding a new language to the list triggers re-installation on next `chezmoi apply`
- Edge case: Marketplace directory doesn't exist (new machine before first plugin sync) → script exits 0 with warning
- Edge case: Empty language list → script does nothing, exits 0
- Integration: `chezmoi apply` runs the script after marketplace sync (ordering via `_after_` prefix)

**Verification:**
- `chezmoi apply` copies ECC rules to `~/.claude/rules/{common,typescript,golang,web}/`
- Modifying `ecc-rules-languages.txt` triggers re-installation on next apply
- Missing marketplace directory produces a warning but no error

- [ ] **Unit 3: Remove overlapping user rules from dot_claude/rules/**

**Goal:** Remove user rules that overlap with ECC-provided rules, keeping user-specific files

**Requirements:** R1, R3

**Dependencies:** Unit 2

**Files:**
- Delete: `dot_claude/rules/common/coding-style.md`
- Delete: `dot_claude/rules/common/git-workflow.md`
- Delete: `dot_claude/rules/common/security.md`
- Delete: `dot_claude/rules/common/testing.md`
- Delete: `dot_claude/rules/golang/coding-style.md`
- Delete: `dot_claude/rules/golang/hooks.md`
- Delete: `dot_claude/rules/golang/patterns.md`
- Delete: `dot_claude/rules/golang/security.md`
- Delete: `dot_claude/rules/golang/testing.md`
- Delete: `dot_claude/rules/typescript/coding-style.md`
- Keep: `dot_claude/rules/common/documentation-language.md`
- Keep: `dot_claude/rules/common/github-actions.md`
- Keep: `dot_claude/rules/common/harness-engineering.md`

**Approach:**
- Delete the 10 files that ECC provides equivalents for
- Keep the 3 user-specific files that have no ECC equivalent
- The `dot_claude/rules/golang/` and `dot_claude/rules/typescript/` directories become empty (chezmoi still needs `dot_claude/rules/common/` for the 3 remaining files)
- Remove empty directories if all files are deleted from them
- Verify with `chezmoi managed | grep rules` that remaining files are correct

**Patterns to follow:**
- Previous rule removal in the repo (standard file deletion)

**Test scenarios:**
- Happy path: After deletion, only 3 user-specific files remain in `dot_claude/rules/`
- Integration: `chezmoi apply` deploys user-specific rules alongside ECC-installed rules without conflict
- Edge case: `~/.claude/rules/common/` has both chezmoi-managed and ECC-installed files → no conflict

**Verification:**
- `dot_claude/rules/common/` contains only documentation-language.md, github-actions.md, harness-engineering.md
- `dot_claude/rules/golang/` and `dot_claude/rules/typescript/` directories are removed or empty
- `chezmoi apply --dry-run` shows no errors

- [ ] **Unit 4: Update .chezmoiignore for ECC-managed rule paths**

**Goal:** Ensure `.chezmoiignore` does not interfere with ECC-installed rules and that chezmoi-managed rule files remain tracked

**Requirements:** R2, R3

**Dependencies:** Unit 3

**Files:**
- Modify: `.chezmoiignore` (if needed)

**Approach:**
- Verify that the current `.chezmoiignore` does not match paths under `.claude/rules/` that should be managed
- The text list file `dot_claude/ecc-rules-languages.txt` must NOT be ignored — verify it's managed
- No new ignores needed: chezmoi only manages what's in the source tree, so ECC files that aren't in `dot_claude/rules/` are automatically invisible to chezmoi

**Patterns to follow:**
- Existing `.chezmoiignore` patterns for marketplace files

**Test scenarios:**
- Test expectation: none -- verification-only unit, no behavioral change expected

**Verification:**
- `chezmoi managed | grep ecc-rules-languages.txt` shows the file
- `chezmoi managed | grep 'rules/common'` shows only user-specific files

## System-Wide Impact

- **Interaction graph:** `chezmoi apply` triggers marketplace sync (add-marketplaces script) THEN rule installation (install-ecc-rules script). The `_after_` prefix ensures ordering. User-specific rules are deployed by chezmoi's normal file targeting before `run_onchange_` scripts run.
- **Error propagation:** If ECC marketplace is missing, the script warns and exits 0 — it does not fail the entire `chezmoi apply`
- **State lifecycle risks:** On first `chezmoi apply` on a new machine, the marketplace may not exist yet (added by add-marketplaces script, which runs at the same time). The `_after_` prefix and tool guard handle this gracefully.
- **Unchanged invariants:** User's 3 specific rule files continue to deploy to `~/.claude/rules/common/`. CLAUDE.md references to rules directories remain valid. Project-specific rules in `.claude/rules/` (repo-level) are unaffected.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| ECC marketplace not present on first apply | Tool guard exits 0 with warning; rules install on subsequent apply after marketplace sync |
| ECC updates break rule format | Rules are plain markdown; low risk. User can pin to specific hash if needed |
| User-specific rules conflict with ECC rules in same directory | Different filenames — coexistence confirmed by overlap analysis |
| Removing user rules loses custom content | User rules are in git history; ECC rules are more comprehensive |

## Sources & References

- ECC repository: https://github.com/affaan-m/everything-claude-code
- ECC rules directory structure: `rules/{common,golang,typescript,web}/*.md`
- Declarative sync pattern: `docs/solutions/integration-issues/chezmoi-declarative-marketplace-sync-over-bidirectional.md`
