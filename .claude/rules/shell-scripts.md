# Shell Scripts

Rules for `.chezmoiscripts/` and other shell scripts in this repository.

## Script Header

All scripts must start with:

```bash
#!/usr/bin/env bash
set -euo pipefail
```

## run_onchange_ Scripts

- Track content hashes in comments: `# brewfile hash: {{ include "darwin/Brewfile" | sha256sum }}`
- Place all `run_onchange_` scripts in `.chezmoiscripts/` (not the source tree root)
- Guard for missing tools gracefully — new machines may not have all tools on first apply:

```bash
command -v pnpm >/dev/null 2>&1 || { echo "WARNING: pnpm not found, skipping"; exit 0; }
```

## Template Scripts (.tmpl)

- `.tmpl` scripts are NOT compatible with shellcheck or shfmt (Go template syntax)
- Pre-commit hooks and CI exclude `.tmpl` files from shell linting
- Keep template logic minimal — prefer simple conditionals over complex template nesting

## Non-Template Scripts

- Must pass shellcheck and shfmt (`shfmt -i 4`)
- Place in `scripts/` for repo-only helpers
- Place in `.chezmoiscripts/` for chezmoi lifecycle scripts

## CI Enforcement

These rules are enforced automatically — not just advisory:

- **CI** (`.github/workflows/lint.yml`): Each CI job calls `Makefile` targets directly — local and CI run the exact same commands
- **Pre-commit** (`.pre-commit-config.yaml`): Runs shellcheck, shfmt, and secretlint automatically before each commit via prek
- **Local** (`Makefile`): `make lint` runs all checks. Individual targets: `make shellcheck`, `make shfmt`, `make secretlint`, `make test-modify`, `make test-scripts`, `make check-templates`

`.tmpl` files are excluded from shell linting because Go template syntax is incompatible with shell linters.


## Hook Scripts

Rules for Claude Code hook scripts (`dot_claude/scripts/`).

### Exit Code Contract

- `exit 0` — intentional skip (tool guard missing, non-project context, already ran)
- `exit 1` + stderr message — actionable error
- Never `exit 1` without stderr — produces confusing "No stderr output" message in Claude Code

### Session Identity

Extract session ID from stdin JSON (stable across all hook invocations in a session):

```bash
SESSION_ID=$(jq -r '.session_id // empty') || exit 0
[[ -z "$SESSION_ID" ]] && exit 0
```

Do not use `$PPID` or `$$` — these are unreliable in `bash -c` hook wrappers.

### One-Shot Flag Pattern

For hooks that should fire only once per session:

```bash
FLAG_FILE="/tmp/claude-<hook-name>-${SESSION_ID}"
[[ -f "$FLAG_FILE" ]] && exit 0

# ... context guards (directory exclusions, git checks) ...

# Set flag AFTER guards, not before — otherwise a non-project context
# consumes the flag and the hook silently skips in project contexts later.
touch "$FLAG_FILE"
```

### Reference

- `docs/solutions/developer-experience/autonomous-harness-engineering-hooks-2026-03-28.md`
- `docs/solutions/integration-issues/claude-code-hook-exit-code-and-stderr-semantics.md`

## Avoiding Recursion

- Never call `chezmoi add` from `run_after_` scripts — this causes infinite recursion
- Instead, use `cp` + `sed` to write directly to the source directory
