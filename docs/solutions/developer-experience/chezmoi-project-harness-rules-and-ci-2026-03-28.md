---
title: "Project-Specific Harness Rules and CI for chezmoi Dotfiles Repository"
date: 2026-03-28
last_updated: 2026-03-29
updated_reason: "Added harness-activator smoke tests, hook guidance rules, Known Pitfalls categorization"
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
  - chezmoi-execute-template
  - template-validation
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
- **`chezmoi execute-template --init` without `--source`** — Templates using `include` (e.g., `{{ include "darwin/Brewfile" | sha256sum }}`) fail silently because `execute-template --init` doesn't know the source directory. The `--source "$(pwd)"` flag is required.
- **`chezmoi execute-template --init --promptString` does not populate `.data` namespace** — `--promptString 'ghOrg=test-org'` answers `promptStringOnce` prompts during config initialization, but does NOT set template data variables (`.ghOrg`, `.profile`). Templates referencing `.ghOrg` fail with `map has no entry for key "ghOrg"`. The fix is to use a test `chezmoi.toml` with `[data]` section and `--config` flag instead of `--init --promptString`.
- **`mktemp` without `.toml` extension for chezmoi config** — `chezmoi execute-template --config` determines the config format from the file extension. Plain `mktemp` creates files like `/tmp/tmp.dcHXJCEb9v` with no recognizable extension, causing `chezmoi: invalid config: .dcHXJCEb9v: unknown format`. Fix: use `mktemp /tmp/chezmoi-test-XXXXXX.toml` to preserve the `.toml` suffix. This applies to any tool that infers format from file extension (chezmoi, viper-based CLIs, etc.).

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

Four parallel jobs: secretlint (via pnpm), shellcheck (Ubuntu pre-installed), shfmt (downloaded binary), and chezmoi template validation.

**Critical pattern:** Both shellcheck and shfmt `find` commands exclude `.tmpl` files — Go template syntax is incompatible with shell linters. This mirrors the existing `.pre-commit-config.yaml` exclusion pattern.

**`executable_*` coverage (2026-03-29):** The original CI `find` only matched `*.sh` and `*.bash`, missing chezmoi `executable_*` prefix files without extensions (e.g., `executable_git-clean-squashed`). Pre-commit caught these via regex `executable_` in `files:`, but CI silently skipped them. Fixed by adding `-name 'executable_*'` to both shellcheck and shfmt `find` commands, with additional exclusions for `.mts`, `.ts`, `.mjs` (TypeScript files that also use the `executable_` prefix).

**`modify_` script smoke tests (2026-03-29):** Added a `modify-scripts` CI job that exercises `modify_dot_claude.json` with three test cases: (1) existing JSON with mcpServers replacement verified by checking for a known key from `mcp-servers.json`, (2) empty stdin producing valid JSON with mcpServers, (3) missing source file triggering passthrough of stdin unchanged. This catches regressions that could zero out `~/.claude.json` on `chezmoi apply`.

**chezmoi template validation** uses `chezmoi execute-template --config <test-config> --source "$(pwd)"` to validate Go template syntax in all `.tmpl` files. Key details:
- A test `chezmoi.toml` is created with `[data]` section providing dummy values for `profile` and `ghOrg`. This is required because `--init --promptString` only answers `promptStringOnce` prompts — it does NOT populate the `.data` namespace that templates reference via `.ghOrg` / `.profile`
- `--source "$(pwd)"` is **required** for templates that use `include` — without it, `execute-template` cannot resolve file paths for hash computation
- `.chezmoi.toml.tmpl` is excluded from validation because it uses `promptStringOnce` which requires interactive input
- Validates syntax only (output goes to `/dev/null`); does not test rendered correctness

Added `.github/` to `.chezmoiignore` to prevent CI files from deploying to `~/`.

### 4. Makefile as single source of truth for lint checks (2026-03-29)

A `Makefile` was introduced with targets mirroring each CI job: `secretlint`, `shellcheck`, `shfmt`, `test-modify`, `check-templates`, and `lint` (runs all). CI workflow (`.github/workflows/lint.yml`) was refactored to call `make` targets directly instead of inline `find | xargs` commands. This ensures local `make lint` and CI run the exact same commands from one definition.

Key details:
- `SHELL_FILES` and `TMPL_FILES` variables centralize `find` patterns, matching CI's file discovery logic
- Graceful skip via `command -v` when tools are missing (matches `.pre-commit-config.yaml` pattern)
- `check-templates` target creates a temp config with `mktemp /tmp/chezmoi-test-XXXXXX.toml` (`.toml` extension required — see "What Didn't Work")
- `pnpm run lint` delegates to `make lint` for users who prefer npm scripts
- `Makefile` added to `.chezmoiignore` to prevent deployment to `~/`

### 5. Harness rule improvements

- **Concrete file references in `.claude/rules/chezmoi-patterns.md`** — Each pattern in the File Type Selection table now links to a real example file (e.g., `modify_dot_claude.json` for modify\_ pattern). Declarative Sync Pattern section references both marketplace and gh extension file triples.
- **CI Enforcement section in `.claude/rules/shell-scripts.md`** — Explicitly states that shell script rules are enforced by CI (`.github/workflows/lint.yml`) and pre-commit (`.pre-commit-config.yaml`), not advisory.
- **`verify` script in `package.json`** — `pnpm run verify` runs secretlint as a single entry point for validation.

### 6. Harness-activator smoke tests and hook guidance (2026-03-29)

**`test-scripts` Makefile target** — Tests `dot_claude/scripts/executable_harness-activator.sh` with three scenarios: (1) normal execution in a git repo produces "HARNESS EVALUATION REMINDER" output, (2) HOME directory guard suppresses output (exit 0), (3) duplicate session_id produces empty output (flag file prevents re-firing). Includes a `jq` tool guard matching the `shellcheck`/`shfmt` pattern. CI job `harness-scripts` added to `lint.yml`.

**Hook Scripts section in `.claude/rules/shell-scripts.md`** — Promotes three hard-won patterns from `docs/solutions/` into project rules:
- Exit code contract: `exit 0` for intentional skip, `exit 1` + stderr for errors, never `exit 1` without stderr
- Session identity: `jq -r '.session_id // empty'` is the stable identifier; `$PPID`/`$$` are unreliable in `bash -c` wrappers
- One-shot flag pattern: flag file must be set AFTER context guards to prevent non-project contexts from consuming the one-shot

**CLAUDE.md Known Pitfalls categorization** — 14 items reorganized into 4 categories with `###` subheaders (chezmoi CLI & ファイル管理, テンプレート構文, スクリプト安全性, 外部制約 & ツール連携). No content changes — structure only.

## Why This Works

- **Project rules vs global rules separation** prevents agents from conflating `dot_claude/rules/` (what gets deployed everywhere) with `.claude/rules/` (guidance for working in this specific repo)
- **Verification section** gives agents a concrete validation checklist instead of relying on implicit knowledge
- **CI** catches issues that bypass pre-commit hooks (direct pushes, `--no-verify` commits) and provides a visible quality gate on PRs
- **`.tmpl` exclusion** avoids false positives from Go template syntax that shell linters cannot parse

## Prevention

- When adding project-specific agent rules to a chezmoi repo, always use `.claude/rules/` at the repo root — never add to `dot_claude/rules/` unless the rule should apply globally across all projects
- When adding new repo-only directories (`.github/`, `scripts/`), always add them to `.chezmoiignore`
- When setting up shell linting in CI for chezmoi repos, always exclude `.tmpl` files — reference `.pre-commit-config.yaml` for the established exclusion patterns
- When aligning CI `find` with pre-commit regex patterns, watch for chezmoi `executable_*` prefix files — `find -name` and pre-commit `files:` regex use different matching semantics. Verify both produce the same file set with a local `find` command
- Add smoke tests for `modify_` scripts in CI — a broken modify\_ script can silently zero out the target file on `chezmoi apply`. Test with sample input, empty stdin, and missing source file scenarios
- When using `chezmoi execute-template` in CI, use `--config` with a test `chezmoi.toml` containing `[data]` section — `--init --promptString` does NOT populate the data namespace. Also pass `--source` for `include` resolution. Exclude `.chezmoi.toml.tmpl` from validation
- When adding project rules, include concrete file path references to real repository examples — agents follow patterns better when they can read the actual implementation
- When creating temp files for tools that infer format from extension (chezmoi, viper-based CLIs), always use `mktemp <dir>/prefix-XXXXXX.ext` with the correct extension — plain `mktemp` produces extensionless files that cause "unknown format" errors
- When CI and local development run the same checks, consolidate the check logic into a `Makefile` (or equivalent) and have CI call the same targets — this eliminates drift between CI inline commands and local developer invocations
- **Mirror contract enforcement:** When adding a new `make` target to the `lint` dependency, always add a corresponding CI job in `.github/workflows/lint.yml` — the contract is "if it passes locally, CI will pass too" and the converse must also hold
- When testing hook scripts in Makefile, pipe JSON to stdin (`printf '{"session_id":"%s"}' "$SID" | bash "$SCRIPT"`), manage `/tmp` flag files for cleanup, and test context guards by running from different directories in subshells
- Remember that `docs/plans/` is gitignored — don't attempt to commit plan files

## Related Issues

- [Autonomous Harness Engineering via Claude Code Hooks](autonomous-harness-engineering-hooks-2026-03-28.md) — Complementary: hooks handle dynamic session feedback, rules handle static project guidance
- [chezmoi .tmpl shellcheck/shfmt incompatibility](../integration-issues/chezmoi-tmpl-shellcheck-shfmt-incompatibility.md) — The foundational learning that informed CI exclusion patterns
