---
title: "chezmoi scripts/ deployment gap: repo-only scripts unreachable from deployed hooks"
date: 2026-04-04
category: integration-issues
module: chezmoi
problem_type: integration_issue
component: tooling
severity: high
symptoms:
  - "Pipeline health section of session-start hook was always blank"
  - "Feature silently degraded on every session due to graceful degradation swallowing the missing script"
  - "pipeline-health.sh --json call returned empty output from deployed hook context"
root_cause: incomplete_setup
resolution_type: code_fix
tags:
  - chezmoi
  - deployment-patterns
  - hooks
  - scripts
  - silent-failure
  - chezmoiignore
---

# chezmoi scripts/ deployment gap: repo-only scripts unreachable from deployed hooks

## Problem

Hook scripts deployed by chezmoi to `~/.claude/scripts/` could not invoke `scripts/pipeline-health.sh` because the `scripts/` directory is excluded by `.chezmoiignore` and never deployed to `~/`. The graceful degradation (`|| true`) silently swallowed the failure, making the pipeline health feature permanently dead code without any visible error.

## Symptoms

- Session-start briefing never showed pipeline health status despite the hook being correctly wired
- `pipeline-health.sh --json` returned empty output when called from the deployed hook path (`$HOME/.claude/scripts/pipeline-health.sh`)
- No error messages in `~/.claude/logs/harness-errors.log` because the `|| true` guard suppressed the failure
- The script worked correctly when run directly from the repo (`bash scripts/pipeline-health.sh`)

## What Didn't Work

- **Calling `scripts/pipeline-health.sh` by repo-relative path from the hook**: The hook runs from `~/.claude/scripts/` at runtime, not from the chezmoi source directory. Repo-relative paths are meaningless in this context.
- **Using `CHEZMOI_SOURCE_DIR` to resolve the repo path at runtime**: This would add a dependency on chezmoi being installed and introduce a fragile runtime path resolution. The deployed hook should be self-contained.
- **Keeping the script in both `scripts/` (for CI) and `dot_claude/scripts/` (for runtime)**: This creates two copies of the same logic that can drift apart. Rejected in favor of single source of truth.

## Solution

Moved `scripts/pipeline-health.sh` to `dot_claude/scripts/executable_pipeline-health.sh` as the **single source of truth**.

**Before:**
```
scripts/pipeline-health.sh          # repo-only, excluded by .chezmoiignore
dot_claude/scripts/                  # deployed to ~/.claude/scripts/
```

**After:**
```
dot_claude/scripts/executable_pipeline-health.sh   # source of truth
  → deployed to ~/.claude/scripts/pipeline-health.sh (runtime)
  → referenced directly by Makefile (CI)
```

Key changes:
- `executable_` prefix ensures chezmoi sets the execute bit on deployment
- Makefile `test-pipeline-health` target updated to `$(pwd)/dot_claude/scripts/executable_pipeline-health.sh`
- The `SHELL_FILES` glob in Makefile (`executable_*`) already covers the new path for shellcheck/shfmt
- CI workflow (`.github/workflows/lint.yml`) references `make` targets, not script paths directly — no CI changes needed

## Why This Works

chezmoi has two categories of scripts in this repo:

| Category | Location | Deployed to `~/`? | Use case |
|----------|----------|-------------------|----------|
| **Repo-only helpers** | `scripts/` | No (excluded by `.chezmoiignore`) | CI scripts, update helpers, one-off tools |
| **Deployed scripts** | `dot_claude/scripts/executable_*` | Yes → `~/.claude/scripts/` | Hook scripts, runtime tools |

The pipeline-health script was initially placed in `scripts/` because it was designed for CLI and CI use only (#5). When #3 (Session-Start Learning Injection) required calling it from a hook at runtime, the deployment gap became a blocker.

The fix places the script where it needs to be at runtime while keeping it accessible for CI via direct source path reference. The `executable_` prefix is chezmoi's convention for setting the execute bit — the prefix is stripped in the deployed target path.

## Prevention

- **Decision rule**: If a script might ever be called from a deployed hook or runtime context, place it in `dot_claude/scripts/` from the start. Use `scripts/` only for repo-internal tooling that will never be needed at runtime.
- **Silent failure awareness**: When adding graceful degradation (`|| true`) for optional dependencies, add a brief note in the requirements about what happens if the dependency is permanently missing vs. temporarily unavailable. The distinction between "graceful degradation for edge cases" and "silently disabled feature" is critical.
- **Document review catches this**: The feasibility and adversarial reviewers in the brainstorm document review independently flagged this as P0. Running document review before implementation prevents building on a broken foundation.

## Related Issues

- PR #126: feat: add session-start deterministic learning injection (fix applied here)
- PR #125: feat: add ECC learning pipeline health monitor (original placement in `scripts/`)
- `docs/solutions/integration-issues/chezmoi-apply-overwrites-runtime-plugin-changes.md` — related chezmoi deployment pattern (modify_ for runtime-mutable files)
- `.claude/rules/chezmoi-patterns.md` — documents the file type selection decision tree
