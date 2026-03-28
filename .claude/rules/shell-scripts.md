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

- **CI** (`.github/workflows/lint.yml`): Runs shellcheck and shfmt on all `.sh`/`.bash` files (excluding `.tmpl`) on every push and PR
- **Pre-commit** (`.pre-commit-config.yaml`): Runs the same shellcheck and shfmt checks locally before each commit via prek
- **secretlint**: Also runs in both CI and pre-commit to prevent committing secrets

`.tmpl` files are excluded from both because Go template syntax is incompatible with shell linters.


## Avoiding Recursion

- Never call `chezmoi add` from `run_after_` scripts — this causes infinite recursion
- Instead, use `cp` + `sed` to write directly to the source directory
