---
title: "feat: Add PII/sensitive info scanning for docs/plans/ and harness automation"
type: feat
status: completed
date: 2026-04-03
---

# feat: Add PII/sensitive info scanning for docs/plans/ and harness automation

## Overview

Add automated scanning for personally identifiable information (PII) and sensitive data in `docs/plans/` files. This repository's plan files are gitignored but may be committed in the future or shared publicly. Current plan files contain real usernames, email addresses, absolute paths with usernames, and SSH key fragments that should be sanitized. The harness should prevent new sensitive data from being introduced.

## Problem Frame

`docs/plans/` currently contains 62 plan files with multiple categories of sensitive information:
- GitHub username (`tanimon`) in PR/issue references and git config examples
- GitHub noreply email with user ID (`<id>+<user>@users.noreply.github.com`)
- Absolute paths with real usernames (`/Users/<username>/`)
- SSH key type and partial fingerprint
- GitHub Actions run IDs tied to personal account

While `docs/plans/` is currently gitignored, the scanning harness should protect all markdown documentation files (including `docs/solutions/`) to catch sensitive data before it enters version control.

## Requirements Trace

- R1. Scan existing `docs/plans/` files and report all PII/sensitive information findings
- R2. Create a reusable shell script that detects common PII patterns in markdown files
- R3. Add a `make scan-sensitive` target following existing Makefile conventions
- R4. Add a CI job to `lint.yml` that runs the scan on committed documentation
- R5. Add a pre-commit hook to `.pre-commit-config.yaml`
- R6. Document the new check in CLAUDE.md

## Scope Boundaries

- Only scans text/markdown files — not binary files, not templates
- Pattern-based detection (grep) — not ML-based NER or external SaaS
- Focuses on this repository's known PII patterns — not a general-purpose PII scanner
- `docs/plans/` is gitignored so CI won't scan it, but the Makefile target and pre-commit hook will catch files if they are staged
- Does NOT auto-fix existing files — the scan reports findings for manual review

## Context & Research

### Relevant Code and Patterns

- `Makefile` — All lint targets follow a consistent pattern: file discovery, tool guard, execution
- `.pre-commit-config.yaml` — All hooks use `bash -c` wrapper with `command -v` guard
- `.github/workflows/lint.yml` — Each job runs a `make` target, no tool installation needed for pure shell scripts
- `scripts/` — Repo-only helper scripts directory

### Existing Sensitive Info Findings in docs/plans/

| Category | Files Affected | Examples |
|----------|---------------|----------|
| GitHub username | 7 files | `tanimon/dotfiles#110`, `name = tanimon` |
| Noreply email | 1 file | `<id>+<user>@users.noreply.github.com` |
| Absolute paths | 3 files | `$HOME/.codex/config.toml`, `$HOME/ghq` (20+ paths) |
| SSH key fragment | 1 file | `signingkey = ssh-ed25519 <key>` |
| GitHub Actions run IDs | 1 file | `actions/runs/23712787643` |

## Key Technical Decisions

- **Pure shell script (grep-based)**: No external dependencies needed. The patterns are well-defined and finite. This keeps the toolchain lightweight, matching the repo's philosophy of minimal dependencies for linting.
- **Configurable patterns file**: Store patterns in a separate file (`scripts/sensitive-patterns.txt`) so they can be updated without modifying the script. Each line is a grep extended regex with a comment describing what it detects.
- **Exit code contract**: Exit 0 if no findings, exit 1 with findings printed to stderr — matches existing lint target conventions.
- **Scan scope**: Default to `docs/` directory. The Makefile target scans `docs/` (which includes `docs/solutions/` that IS committed). Pre-commit hook scans only staged markdown files.

## Open Questions

### Resolved During Planning

- **Should we scan only docs/plans/ or broader?** → Scan all `docs/` since `docs/solutions/` is committed and could also contain sensitive data.
- **Should we auto-fix?** → No. Auto-replacement risks breaking context. Report only; human reviews and fixes.
- **External tool vs shell script?** → Shell script. No new dependencies, matches repo conventions.

### Deferred to Implementation

- Exact regex patterns will be refined during implementation based on actual false positive rates
- Whether to add a `.sensitive-scan-ignore` allowlist file for intentional exceptions (implement if needed)

## Implementation Units

- [ ] **Unit 1: Create sensitive info scanning script**

  **Goal:** Create a reusable shell script that scans markdown files for PII/sensitive patterns

  **Requirements:** R2

  **Dependencies:** None

  **Files:**
  - Create: `scripts/scan-sensitive-info.sh`
  - Create: `scripts/sensitive-patterns.txt`

  **Approach:**
  - Script accepts file paths as arguments (for pre-commit) or defaults to scanning `docs/` directory
  - Reads patterns from `sensitive-patterns.txt` (one extended regex per line, `#` comments allowed)
  - Uses `grep -En` for each pattern, collects all matches, prints report to stderr
  - Exits 1 if any match found, 0 if clean
  - Patterns to detect:
    - Absolute paths with usernames: `/Users/[a-zA-Z][a-zA-Z0-9._-]+/`
    - Email addresses: `[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}` (excluding obvious template/example patterns like `user@example.com`)
    - SSH key material: `ssh-(rsa|ed25519|ecdsa) AAAA`
    - GitHub noreply with user ID: `[0-9]+\+[a-zA-Z0-9]+@users\.noreply\.github\.com`
    - Windows user paths: `C:\\Users\\[a-zA-Z]`

  **Patterns to follow:**
  - `scripts/update-brewfile.sh`, `scripts/update-marketplaces.sh` for script structure
  - Existing Makefile targets for exit code conventions

  **Test scenarios:**
  - Happy path: script exits 0 on a clean markdown file with no PII
  - Happy path: script exits 1 and reports findings when scanning a file with `/Users/<realname>/` path
  - Edge case: script handles empty file list gracefully (exit 0)
  - Edge case: `user@example.com` and template placeholders like `{{ .chezmoi.homeDir }}` are NOT flagged
  - Error path: missing patterns file produces clear error message

  **Verification:**
  - `echo '/Users/<name>/foo' | scripts/scan-sensitive-info.sh /dev/stdin` exits 1
  - `echo 'clean text' | scripts/scan-sensitive-info.sh /dev/stdin` exits 0

- [ ] **Unit 2: Add Makefile target and integrate into lint pipeline**

  **Goal:** Add `scan-sensitive` target to Makefile and include it in the `lint` target

  **Requirements:** R3

  **Dependencies:** Unit 1

  **Files:**
  - Modify: `Makefile`

  **Approach:**
  - Add `DOCS_MD_FILES` variable using find for `docs/` markdown files
  - Add `scan-sensitive` target that calls `scripts/scan-sensitive-info.sh` with discovered files
  - Add `scan-sensitive` to the `lint` phony target list and dependency chain
  - Follow existing pattern: echo status, file count check, tool guard (script existence)

  **Patterns to follow:**
  - `shellcheck` target structure in Makefile (lines 29-38)

  **Test scenarios:**
  - Happy path: `make scan-sensitive` runs and reports findings on current docs/
  - Happy path: `make lint` includes `scan-sensitive` in its execution
  - Edge case: no markdown files in docs/ → prints "No docs files found" and exits 0

  **Verification:**
  - `make scan-sensitive` executes without errors
  - `make lint` includes the new target

- [ ] **Unit 3: Add CI job to lint.yml**

  **Goal:** Add a GitHub Actions job that runs the sensitive info scan on PRs

  **Requirements:** R4

  **Dependencies:** Unit 2

  **Files:**
  - Modify: `.github/workflows/lint.yml`

  **Approach:**
  - Add `scan-sensitive` job following existing job patterns (checkout + `make scan-sensitive`)
  - No tool installation needed — pure shell script
  - Pin actions to same SHAs as other jobs

  **Patterns to follow:**
  - `shellcheck` job in `lint.yml` (lines 26-33) — simplest pattern, no tool install needed

  **Test scenarios:**
  - Happy path: CI job runs `make scan-sensitive` and passes on clean docs
  - Error path: CI job fails if committed docs contain PII patterns

  **Verification:**
  - Workflow YAML passes `actionlint`
  - Job structure matches existing patterns

- [ ] **Unit 4: Add pre-commit hook**

  **Goal:** Add pre-commit hook that scans staged markdown files for sensitive info

  **Requirements:** R5

  **Dependencies:** Unit 1

  **Files:**
  - Modify: `.pre-commit-config.yaml`

  **Approach:**
  - Add `scan-sensitive` hook entry following existing pattern
  - Use `bash -c` wrapper for consistency
  - Scope to markdown files: `files: '\.md$'`
  - Pass staged files as arguments to the script

  **Patterns to follow:**
  - `shellcheck` hook entry (lines 9-14) for structure

  **Test scenarios:**
  - Happy path: committing a clean markdown file passes the hook
  - Error path: committing a markdown file with `/Users/<realname>/` triggers hook failure

  **Verification:**
  - `.pre-commit-config.yaml` is valid YAML
  - Hook entry matches established pattern

- [ ] **Unit 5: Update CLAUDE.md documentation**

  **Goal:** Document the new scan-sensitive check in CLAUDE.md

  **Requirements:** R6

  **Dependencies:** Units 2, 3, 4

  **Files:**
  - Modify: `CLAUDE.md`

  **Approach:**
  - Add `make scan-sensitive` to the Verification section's individual targets list
  - Add brief description in the lint target comment

  **Test expectation:** none -- documentation-only change

  **Verification:**
  - CLAUDE.md mentions `scan-sensitive` in the Verification section

## System-Wide Impact

- **Interaction graph:** New Makefile target → called by CI job and pre-commit hook. No callbacks or observers.
- **Error propagation:** Script exit code propagates through make → CI/pre-commit as expected
- **State lifecycle risks:** None — stateless scan
- **API surface parity:** Makefile target, CI job, and pre-commit hook all call the same script
- **Integration coverage:** `make lint` integration tested by running it locally
- **Unchanged invariants:** All existing lint targets, CI jobs, and pre-commit hooks unchanged

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| False positives on example.com emails or template paths | Patterns file includes exclusion comments; script can be extended with allowlist |
| docs/plans/ is gitignored so CI won't catch it | Makefile target scans locally; pre-commit catches staged files; document this limitation |
| New patterns needed over time | Patterns in separate file, easy to update without script changes |

## Sources & References

- Related: Existing `secretlint` configuration for secrets detection
- Pattern: `Makefile` lint target structure, `.pre-commit-config.yaml` hook structure
