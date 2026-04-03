---
title: "feat: Add GitHub Actions workflow linting with actionlint and zizmor"
type: feat
status: completed
date: 2026-04-02
---

# feat: Add GitHub Actions workflow linting with actionlint and zizmor

## Overview

Add static analysis and security auditing for GitHub Actions workflow files using actionlint (syntax/type checking) and zizmor (security auditing). This closes a coverage gap — the 5 workflow files in `.github/workflows/` are currently not linted by any tool.

## Problem Frame

The repository has a mature linting pipeline (shellcheck, shfmt, oxlint, oxfmt, secretlint) but no workflow-specific linting. A past incident (`docs/solutions/integration-issues/github-actions-expression-in-operator-does-not-exist-2026-03-29.md`) explicitly recommended actionlint as prevention. Supply chain security risks in GHA are increasing, making security auditing valuable.

Relates to: tanimon/dotfiles#110

## Requirements Trace

- R1. Lint GitHub Actions workflows for syntax errors, type mismatches, and expression issues
- R2. Audit workflows for security vulnerabilities (template injection, unpinned actions, excessive permissions)
- R3. Integrate into the existing 3-layer lint pipeline (Makefile, CI, pre-commit) following established patterns
- R4. Maximize error detection coverage while keeping the tool count minimal

## Scope Boundaries

- ghalint is excluded — its unique checks (job timeout, container tag) are niche, and zizmor covers most of its security policies. The lintnet migration adds maintenance risk
- YAML general-purpose linting (yamlfmt) is out of scope — it is installed but unused and is a separate concern
- No `.tmpl` workflow files exist, so template exclusion patterns are not needed for these tools

## Context & Research

### Relevant Code and Patterns

- `Makefile`: System-binary tools use `command -v` guard pattern (shellcheck, shfmt). pnpm tools use `pnpm exec` without guard
- `.github/workflows/lint.yml`: 8 parallel jobs, all call `make <target>`. System-binary CI jobs download binaries directly (shfmt pattern)
- `.pre-commit-config.yaml`: Local hooks with `language: system`, `bash -c` wrapper with `command -v` guard
- `darwin/Brewfile`: Homebrew formulae for system tools

### Institutional Learnings

- `docs/solutions/developer-experience/chezmoi-oxlint-oxfmt-lint-pipeline-gotchas-2026-03-29.md`: Two tool-guard patterns — system binaries (`command -v`) vs pnpm binaries (`pnpm exec`). Exclude `modify_*` from file-type linters
- `docs/solutions/developer-experience/chezmoi-project-harness-rules-and-ci-2026-03-28.md`: Mirror contract — every `make` target in `lint` must have a corresponding CI job
- `docs/solutions/integration-issues/github-actions-expression-in-operator-does-not-exist-2026-03-29.md`: Explicitly recommended actionlint as prevention

### Tool Selection Rationale

| Tool | Focus | Unique Value |
|------|-------|-------------|
| **actionlint** | Syntax, types, expression checking, shellcheck-in-run | Only tool with expression type checking and embedded `run:` block linting |
| **zizmor** | Security (35+ audits) | Vulnerable action detection, impostor commits, template injection, auto-fix |

Together they provide comprehensive coverage with minimal overlap. actionlint handles correctness; zizmor handles security.

## Key Technical Decisions

- **actionlint + zizmor, not ghalint**: zizmor covers most ghalint policies (SHA pinning, permissions, secrets-inherit) with deeper analysis. ghalint lacks Homebrew, has a smaller community (222 vs 4k+ stars), and is migrating to lintnet
- **System-binary pattern**: Both tools are standalone binaries (Go/Rust), installed via Homebrew locally. CI downloads binaries directly — no pnpm/node dependency needed
- **actionlint official installer script for CI**: Uses the maintained `download-actionlint.bash` script rather than hardcoding a version URL
- **zizmor via pip in CI**: The simplest cross-platform install method for CI (Rust binary via PyPI)

## Open Questions

### Resolved During Planning

- **Which tools to use?** actionlint + zizmor — broadest coverage with 2 tools. ghalint adds marginal value over zizmor
- **How to install in CI?** actionlint: official installer script. zizmor: `pip install`
- **Pre-commit for actionlint?** Yes — actionlint is fast and catches high-value errors early. zizmor is also fast but security audits are better suited for CI (may have false positives to configure)

### Deferred to Implementation

- **zizmor configuration**: May need a `.zizmor.yml` to suppress false positives or adjust audit severity. Determine after first run against actual workflows
- **actionlint configuration**: May need `.github/actionlint.yaml` if specific checks produce noise. Determine after first run

## Implementation Units

- [ ] **Unit 1: Add Brewfile entries and Makefile targets**

**Goal:** Make `make actionlint` and `make zizmor` work locally

**Requirements:** R1, R2, R3

**Dependencies:** None

**Files:**
- Modify: `darwin/Brewfile`
- Modify: `Makefile`

**Approach:**
- Add `brew "actionlint"` and `brew "zizmor"` to Brewfile (near existing lint tools)
- Add `actionlint` and `zizmor` targets to Makefile following the `command -v` guard pattern (same as shellcheck/shfmt)
- actionlint needs no file arguments — it auto-discovers `.github/workflows/*.yml`
- zizmor takes a directory argument: `zizmor .github/workflows/`
- Add both to the `lint:` dependency list and `.PHONY` declaration

**Patterns to follow:**
- `shellcheck` / `shfmt` targets in `Makefile` (system-binary with `command -v` guard)

**Test scenarios:**
- Happy path: `make actionlint` runs successfully when actionlint is installed and workflows are valid
- Happy path: `make zizmor` runs successfully when zizmor is installed
- Edge case: `make actionlint` prints warning and exits 0 when actionlint is not installed
- Edge case: `make zizmor` prints warning and exits 0 when zizmor is not installed
- Happy path: `make lint` includes both new targets

**Verification:**
- `make actionlint` and `make zizmor` complete without errors
- `make lint` runs all checks including the new targets

- [ ] **Unit 2: Add CI jobs to lint.yml**

**Goal:** Run actionlint and zizmor in CI on push/PR

**Requirements:** R1, R2, R3

**Dependencies:** Unit 1 (Makefile targets must exist)

**Files:**
- Modify: `.github/workflows/lint.yml`

**Approach:**
- Add two new parallel jobs following the standalone-binary pattern (no pnpm/node setup)
- actionlint job: use official installer script (`download-actionlint.bash`), then `make actionlint`
- zizmor job: `pip install zizmor`, then `make zizmor`
- Pin `actions/checkout` to the same SHA already used in the file (`de0fac2e...`)
- Maintain the mirror contract: CI calls `make` targets, not inline commands

**Patterns to follow:**
- `shfmt` job in `lint.yml` (standalone binary download + make target)
- `shellcheck` job (minimal, no extra setup)

**Test scenarios:**
- Happy path: Both CI jobs pass on current workflows
- Error path: actionlint job fails when a workflow has a syntax error (validated by CI catching real issues)
- Integration: New jobs appear as required checks on PRs

**Verification:**
- `lint.yml` has `actionlint` and `zizmor` jobs
- Both jobs call their respective `make` targets
- Actions are pinned to full commit SHAs

- [ ] **Unit 3: Add pre-commit hooks**

**Goal:** Catch workflow issues before commit

**Requirements:** R3

**Dependencies:** Unit 1 (tools must be installable)

**Files:**
- Modify: `.pre-commit-config.yaml`

**Approach:**
- Add `actionlint` hook with `command -v` guard, targeting `.github/workflows/*.yml`
- Add `zizmor` hook with same pattern
- Use `files: '\.github/workflows/.*\.yml$'` to scope to workflow files only
- Follow the existing `bash -c 'if command -v ... fi' --` wrapper pattern

**Patterns to follow:**
- `shellcheck` / `shfmt` hooks in `.pre-commit-config.yaml` (system binary with guard)

**Test scenarios:**
- Happy path: Modifying a workflow file triggers both hooks
- Edge case: Hooks skip gracefully when tools are not installed
- Edge case: Non-workflow YAML files do not trigger the hooks

**Verification:**
- Both hooks appear in `.pre-commit-config.yaml`
- Hooks fire only on workflow file changes

- [ ] **Unit 4: Fix any lint findings in existing workflows**

**Goal:** Ensure current workflows pass both linters cleanly

**Requirements:** R1, R2

**Dependencies:** Unit 1 (need working make targets)

**Files:**
- Modify: `.github/workflows/lint.yml` (if findings)
- Modify: `.github/workflows/claude.yml` (if findings)
- Modify: `.github/workflows/harness-analysis.yml` (if findings)
- Modify: `.github/workflows/harness-auto-remediate.yml` (if findings)
- Modify: `.github/workflows/security-alerts.yml` (if findings)
- Create: `.zizmor.yml` (if configuration needed to suppress false positives)

**Approach:**
- Run `actionlint` and `zizmor` against all workflows
- Fix genuine issues (syntax errors, security problems)
- For zizmor findings that are false positives or accepted risks (e.g., `pull_request_target` usage is intentional in claude.yml), configure suppressions in `.zizmor.yml` or inline annotations
- Do not change workflow behavior — only fix lint violations and add suppressions

**Test scenarios:**
- Happy path: `make actionlint` exits 0 after fixes
- Happy path: `make zizmor` exits 0 after fixes/suppressions
- Integration: `make lint` passes with all existing and new targets

**Verification:**
- Both `make actionlint` and `make zizmor` pass cleanly
- `make lint` passes end-to-end
- No workflow behavior has changed

## System-Wide Impact

- **Interaction graph:** New Makefile targets are added to the `lint` dependency chain. CI gains 2 new parallel jobs. Pre-commit gains 2 new hooks. All three layers remain aligned
- **Error propagation:** Lint failures in CI block PR merge (same as existing linters). Pre-commit failures block local commit
- **API surface parity:** No external API changes
- **Unchanged invariants:** All existing lint targets, CI jobs, and pre-commit hooks remain unchanged. The mirror contract (local = CI) is maintained

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| zizmor false positives on `pull_request_target` or `secrets: inherit` patterns | Configure `.zizmor.yml` suppressions for accepted patterns |
| actionlint may flag valid-but-unusual GHA expressions in complex workflows | Review findings case-by-case; use inline `# nolint` comments sparingly |
| CI install time increase (~10s per tool) | Both tools are small binaries; impact is negligible |

## Sources & References

- Related issue: tanimon/dotfiles#110
- Related learning: `docs/solutions/integration-issues/github-actions-expression-in-operator-does-not-exist-2026-03-29.md`
- Related learning: `docs/solutions/developer-experience/chezmoi-oxlint-oxfmt-lint-pipeline-gotchas-2026-03-29.md`
- actionlint: https://github.com/rhysd/actionlint
- zizmor: https://github.com/zizmorcore/zizmor
