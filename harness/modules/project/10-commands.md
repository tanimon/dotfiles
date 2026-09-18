## Common Commands

```sh
chezmoi apply                  # Apply all dotfiles to ~/
chezmoi apply --dry-run        # Preview what would change
chezmoi diff                   # Show diff between source and destination
chezmoi add <file>             # Add a file to chezmoi management
chezmoi edit <file>            # Edit a managed file's source
chezmoi managed                # List all managed files
chezmoi data                   # Show template data (profile, ghOrg, etc.)

# Linting (mirrors CI — also runs on commit via prek; requires `just`, installed via darwin/Brewfile)
just lint                      # Run all checks (secretlint + shellcheck + shfmt + oxlint + oxfmt + actionlint + zizmor + modify_ + script tests + templates + sensitive scan + nono profile + instruction drift)
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
