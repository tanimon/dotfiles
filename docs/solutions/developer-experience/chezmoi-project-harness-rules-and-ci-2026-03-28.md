---
title: "Project-Specific Harness Rules and CI for chezmoi Dotfiles Repository"
date: 2026-03-28
problem_type: developer_experience
component: tooling
symptoms:
  - "Agents lack project-specific guidance for chezmoi template patterns"
  - "No verification documentation in CLAUDE.md for validating changes"
  - "Pre-commit hooks are the only lint gate — no CI to catch bypassed commits"
  - "Agents confuse dot_claude/rules/ (global deploy) with .claude/rules/ (project-specific)"
root_cause: missing_tooling
resolution_type: tooling_addition
severity: medium
tags:
  - harness-engineering
  - claude-rules
  - chezmoi
  - github-actions
  - ci
  - project-specific-rules
  - shellcheck
  - shfmt
---

# Project-Specific Harness Rules and CI for chezmoi Dotfiles Repository

## Problem

Agents working in the chezmoi dotfiles repository had no project-specific rules to guide them on chezmoi template patterns, shell script conventions, or verification procedures. The only lint gate was pre-commit hooks, which can be bypassed.

## Symptoms

- Agents made avoidable mistakes with chezmoi file type selection (`.tmpl` vs `modify_` vs `create_`)
- No documented way to verify changes before committing
- No CI to catch issues that bypass pre-commit hooks
- Agents confused `dot_claude/rules/` (deployed globally to `~/.claude/rules/` via chezmoi) with `.claude/rules/` (project-specific rules for the repo itself)

## What Didn't Work

- **Attempting to commit `docs/plans/` files** — `.gitignore` excludes `docs/*` with only `!docs/solutions/` as exception. Modifying `.gitignore` to add `!docs/plans/` exposed 30+ old untracked plan files, polluting the PR scope. Reverted and left plans as local working documents.
- **Using `chezmoi apply --dry-run` in CI** — Requires `.chezmoi.toml` with template variables (`.profile`, `.ghOrg`) that are environment-specific. Setup cost too high for CI; lint checks provide sufficient validation.

## Solution

Three additions to the harness:

### 1. Project-specific `.claude/rules/`

Created `.claude/rules/chezmoi-patterns.md` and `.claude/rules/shell-scripts.md` at the repo root. These are NOT the same as `dot_claude/rules/` which deploys to `~/.claude/rules/`.

**Key distinction:**
- `dot_claude/rules/` → chezmoi source → deploys to `~/.claude/rules/` (global, cross-project)
- `.claude/rules/` → repo root → project-specific rules for this repo only (not deployed)

Content focuses on agent judgment criteria (when to use `modify_` vs `.tmpl`, `run_onchange_` hash tracking pattern, `.tmpl` shellcheck incompatibility) rather than duplicating CLAUDE.md Known Pitfalls.

### 2. CLAUDE.md Verification section

Added before Known Pitfalls with four commands:
```sh
chezmoi apply --dry-run        # Preview changes before applying
pnpm exec secretlint '**/*'   # Check for leaked secrets
shellcheck <script.sh>         # Lint non-.tmpl shell scripts
shfmt -d -i 4 <script.sh>     # Check shell script formatting
```

### 3. GitHub Actions CI (`.github/workflows/lint.yml`)

Three parallel jobs: secretlint (via pnpm), shellcheck (Ubuntu pre-installed), shfmt (downloaded binary).

**Critical pattern:** Both shellcheck and shfmt `find` commands exclude `.tmpl` files — Go template syntax is incompatible with shell linters. This mirrors the existing `.pre-commit-config.yaml` exclusion pattern.

Added `.github/` to `.chezmoiignore` to prevent CI files from deploying to `~/`.

## Why This Works

- **Project rules vs global rules separation** prevents agents from conflating `dot_claude/rules/` (what gets deployed everywhere) with `.claude/rules/` (guidance for working in this specific repo)
- **Verification section** gives agents a concrete validation checklist instead of relying on implicit knowledge
- **CI** catches issues that bypass pre-commit hooks (direct pushes, `--no-verify` commits) and provides a visible quality gate on PRs
- **`.tmpl` exclusion** avoids false positives from Go template syntax that shell linters cannot parse

## Prevention

- When adding project-specific agent rules to a chezmoi repo, always use `.claude/rules/` at the repo root — never add to `dot_claude/rules/` unless the rule should apply globally across all projects
- When adding new repo-only directories (`.github/`, `scripts/`), always add them to `.chezmoiignore`
- When setting up shell linting in CI for chezmoi repos, always exclude `.tmpl` files — reference `.pre-commit-config.yaml` for the established exclusion patterns
- Remember that `docs/plans/` is gitignored — don't attempt to commit plan files

## Related Issues

- [Autonomous Harness Engineering via Claude Code Hooks](autonomous-harness-engineering-hooks-2026-03-28.md) — Complementary: hooks handle dynamic session feedback, rules handle static project guidance
- [chezmoi .tmpl shellcheck/shfmt incompatibility](../integration-issues/chezmoi-tmpl-shellcheck-shfmt-incompatibility.md) — The foundational learning that informed CI exclusion patterns
