---
module: lint-pipeline
date: 2026-03-29
problem_type: developer_experience
component: tooling
symptoms:
  - "oxfmt fails with SyntaxError on modify_dot_claude.json (bash script with .json extension)"
  - "command -v oxlint fails in Makefile despite pnpm install succeeding"
root_cause: config_error
resolution_type: tooling_addition
severity: medium
tags:
  - oxlint
  - oxfmt
  - chezmoi
  - modify-script
  - pnpm
  - lint-pipeline
  - makefile
---

# Adding oxlint/oxfmt to a chezmoi Lint Pipeline

## Problem

When integrating oxlint (JS/TS linter) and oxfmt (JS/TS/JSON formatter) into an existing chezmoi dotfiles repository, two non-obvious issues cause the lint pipeline to fail.

## Symptoms

1. `pnpm exec oxfmt --check` fails with `SyntaxError: Unexpected token` on `modify_dot_claude.json`
2. `command -v oxlint` returns non-zero in Makefile despite `pnpm add -D oxlint` succeeding

## What Didn't Work

- Using `*.json` glob without exclusions for oxfmt — matches chezmoi `modify_*` scripts that have `.json` extension but contain bash
- Modeling oxlint/oxfmt Makefile targets after shellcheck/shfmt with `command -v` guards — these are system-installed (Homebrew) binaries, but oxlint/oxfmt are pnpm-installed (`node_modules/.bin`) and not on PATH

## Solution

### 1. Exclude `modify_*` files from JSON glob

chezmoi's `modify_` prefix indicates a script that receives the current target on stdin and outputs the modified version. `modify_dot_claude.json` is a bash script despite its `.json` extension.

```makefile
# Before (broken)
JSON_FILES := $(shell find . -type f -name '*.json' \
    ! -path './node_modules/*' 2>/dev/null)

# After (fixed)
JSON_FILES := $(shell find . -type f -name '*.json' \
    ! -path './node_modules/*' \
    ! -name 'modify_*' 2>/dev/null)
```

For pre-commit hooks, use an exclude pattern:
```yaml
exclude: '(\.tmpl$|modify_)'
```

### 2. Use `pnpm exec` directly instead of `command -v` guard

pnpm-installed tools live in `node_modules/.bin/` and are not on the system PATH. The existing `secretlint` target (also pnpm-installed) correctly uses `pnpm exec` without a `command -v` guard.

```makefile
# Wrong: follows shellcheck/shfmt pattern (system binaries)
oxlint:
    @if command -v oxlint >/dev/null 2>&1; then ...

# Correct: follows secretlint pattern (pnpm binaries)
oxlint:
    @if [ -n "$(JS_TS_FILES)" ]; then \
        echo "Running oxlint..."; \
        pnpm exec oxlint $(JS_TS_FILES); \
    else \
        echo "No JS/TS files found"; \
    fi
```

## Why This Works

- **modify_ exclusion**: chezmoi uses the target filename as the script name. `modify_dot_claude.json` targets `~/.claude.json` but the source file itself is bash. Any file-type-based tooling must exclude `modify_*` prefixed files.
- **pnpm exec**: `pnpm exec` resolves binaries from `node_modules/.bin/` without requiring PATH modification. This matches the existing pattern established by `secretlint` in this repository.

## Prevention

- **Rule**: When adding file-type-based linters/formatters to a chezmoi repo, always exclude `modify_*` files — they may have misleading extensions.
- **Rule**: When choosing Makefile guard patterns, match the installation method: `command -v` for system binaries (Homebrew), `pnpm exec` for npm packages.
- **Pattern reference**: Two distinct tool-guard patterns exist in the Makefile — recognize which to follow:
  - System tools (shellcheck, shfmt): `command -v` guard + direct invocation
  - pnpm tools (secretlint, oxlint, oxfmt): no guard + `pnpm exec` invocation
