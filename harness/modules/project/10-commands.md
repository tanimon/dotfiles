## Common Commands

`chezmoi --help` covers the everyday subcommands (`apply`, `diff`, `add`, `edit`, `managed`, `data`). The ones below are not guessable from a tool's own help:

```sh
# Linting (mirrors CI — also runs on commit via prek; requires `just`, installed via darwin/Brewfile)
just lint                      # Run all checks; `just --list` shows the individual recipes
pnpm exec secretlint '**/*'   # Scan for leaked secrets only

# Branch / PR context — replaces the fetch + merge-base + diff --stat + gh pr view chain.
# Never touches the worktree, the index, HEAD, or branch state (git fetch updates remote-tracking refs)
bash scripts/pr-context.sh [<base>]   # base defaults to origin/main; PR_CONTEXT_SKIP_FETCH=1 when offline

# Agent instructions (CLAUDE.md / AGENTS.md / .cursor/rules are GENERATED — see below)
just harness-sync              # Regenerate them from harness/modules/ + harness/project.json
just check-instructions        # Fail if a generated file was hand-edited (drift)

# Security alerts (scheduled weekly in CI, also manual)
gh workflow run security-alerts.yml  # Trigger security alert sweep manually
```
