# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A chezmoi-managed dotfiles repository for macOS. Source directory is `~/.local/share/chezmoi/`, targeting `~/` as the destination. Managed configs include shell (zsh, starship, sheldon), editor (vim, helix), terminal (ghostty, tmux, zellij), git, Claude Code (`~/.claude/`), dev tools (mise, gh, yazi), and macOS packages (Brewfile).

## Common Commands

```sh
chezmoi apply                  # Apply all dotfiles to ~/
chezmoi apply --dry-run        # Preview what would change
chezmoi diff                   # Show diff between source and destination
chezmoi add <file>             # Add a file to chezmoi management
chezmoi edit <file>            # Edit a managed file's source
chezmoi managed                # List all managed files
chezmoi data                   # Show template data (profile, ghOrg, etc.)

# Pre-commit / linting (runs automatically on commit via prek)
pnpm exec secretlint '**/*'   # Scan for leaked secrets
```

## chezmoi Naming Conventions

Source files use chezmoi's naming scheme — understand these prefixes when working here:

| Prefix | Meaning |
|--------|---------|
| `dot_` | File starts with `.` in target (e.g., `dot_zshrc` → `~/.zshrc`) |
| `private_` | Target has `0600`/`0700` permissions |
| `modify_` | Script that receives current target on stdin, outputs modified version |
| `run_onchange_` | Script runs when its tracked hash changes |
| `run_after_` | Script runs after every `chezmoi apply` |
| `.tmpl` suffix | Go template — rendered with `.chezmoi.homeDir`, `.profile`, `.ghOrg` |

## Architecture

### Template Variables

Defined in `.chezmoi.toml.tmpl`, prompted on first `chezmoi init`:
- `.profile` — `"work"` or `"personal"` (controls gitconfig work overrides)
- `.ghOrg` — GitHub org name (used in permissions and directory paths)
- `.chezmoi.homeDir` — Home directory path

### Key Patterns

**`modify_dot_claude.json`** — Partially manages `~/.claude.json` (a large runtime file). Uses `jq` to replace only the `mcpServers` key from `dot_claude/mcp-servers.json`, preserving all other runtime state. This is the correct pattern for files where chezmoi should own a subset of keys.

**Declarative marketplace sync** — `dot_claude/plugins/marketplaces.txt` lists marketplace sources (one per line: `owner/repo` or URL). `run_onchange_after_add-marketplaces.sh.tmpl` tracks the file hash and runs `claude plugin marketplace add` for each entry when it changes. To add a new marketplace: register it locally with `claude plugin marketplace add`, run `scripts/update-marketplaces.sh` to regenerate the list, then commit and push. Plugin install/enable state (`installed_plugins.json`, `known_marketplaces.json`) is not managed by chezmoi — these files are in `.chezmoiignore`.

**`run_onchange_` scripts** — Track file hashes in comments (e.g., `# brewfile hash: {{ include "macOs/Brewfile" | sha256sum }}`). They re-run only when the tracked content changes.

### `.chezmoiignore`

Extensively excludes `~/.claude/` dynamic directories (projects, sessions, cache, etc.) so only curated config files are managed. Also excludes repo-only files like `docs/`, `package.json`, `node_modules/`.

### `.chezmoiexternal.toml`

Pulls external git repos (e.g., Claudeception skill) into the managed tree with auto-refresh.

### Pre-commit Hooks

Uses `prek` (not husky) with `secretlint` to prevent committing secrets. Dependencies managed via pnpm. The `run_onchange_install-pre-commit-hooks.sh.tmpl` script auto-installs when `package.json` or `.pre-commit-config.yaml` change.

## Known Pitfalls

- **`chezmoi add --autotemplate` breaks JSON** — `:` and `/` get over-substituted. Use `chezmoi add --template` + manual `sed` for homeDir substitution instead.
- **`run_after_` scripts calling `chezmoi add` cause recursion** — Use `cp` + `sed` to write directly to the source directory.
- **`.chezmoiignore` silently skips** — If `chezmoi add` does nothing, check `.chezmoiignore`.
- **Template escaping** — To output literal `{{ .chezmoi.homeDir }}` in a `.tmpl` file, use `{{ "{{ .chezmoi.homeDir }}" }}`.
- **Git commit signing** — Requires 1Password SSH agent (`op-ssh-sign`). Commits will fail without it running.
- **Repo-only files need `.chezmoiignore`** — Files like `CLAUDE.md`, `README.md` at repo root are excluded via `.chezmoiignore` so they don't deploy to `~/`. New repo-only files must be added there.
- **`modify_` scripts: empty stdout = target deletion** — Never use OS guards (`{{ if eq .chezmoi.os "darwin" }}`); on non-matching OS the script outputs nothing and chezmoi zeros the file. Always include `set -e`. Use `printf '%s\n'` (not `printf '%s'`) to preserve trailing newlines stripped by `$(cat)`.
- **Choosing chezmoi file patterns** — Regular `.tmpl` for fully-owned files. `create_` for provision-once. `modify_` for runtime-mutable files (IDE configs). `.chezmoiignore` to exclude entirely. For files modified by external tools (plugins), prefer `.chezmoiignore` + declarative `run_onchange_` scripts over bidirectional sync.
