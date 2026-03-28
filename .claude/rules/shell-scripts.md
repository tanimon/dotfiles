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
- **Local** (`Makefile`): `make lint` runs all checks. Individual targets: `make shellcheck`, `make shfmt`, `make secretlint`, `make test-modify`, `make check-templates`

`.tmpl` files are excluded from shell linting because Go template syntax is incompatible with shell linters.


## Avoiding Recursion

- Never call `chezmoi add` from `run_after_` scripts — this causes infinite recursion
- Instead, use `cp` + `sed` to write directly to the source directory
