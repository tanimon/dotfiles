# chezmoi Patterns

Project-specific rules for working in this chezmoi dotfiles repository.

## File Type Selection

When adding or modifying managed files, choose the right chezmoi pattern:

| Pattern | When to use | Example |
|---------|-------------|---------|
| `.tmpl` (regular template) | chezmoi fully owns the file; no external tool modifies it | `dot_gitconfig.tmpl`, `dot_claude/settings.json.tmpl` |
| `create_` | Provision-once files that should not be overwritten on subsequent applies | (none currently in this repo) |
| `modify_` script | Runtime-mutable files where chezmoi owns a subset of keys (e.g., IDE configs, `~/.claude.json`) | `modify_dot_claude.json` |
| `.chezmoiignore` + `run_onchange_` | Files managed entirely by external tools (plugin state, extension lists) | `dot_claude/plugins/marketplaces.txt` + `.chezmoiscripts/run_onchange_after_add-marketplaces.sh.tmpl` |

## modify_ Script Safety

- Always include `set -e` at the top
- Never use OS guards (`{{ if eq .chezmoi.os "darwin" }}`) that wrap the entire script — on non-matching OS the script outputs nothing and chezmoi deletes the target
- Use `printf '%s\n'` (not `printf '%s'`) to preserve trailing newlines stripped by `$(cat)`
- For new-machine bootstrap (empty stdin), output initial data from a `.data` file
- See `modify_dot_claude.json` for a well-documented example of partial JSON management

## Template Syntax

- `.tmpl` files use Go template syntax: `{{ .chezmoi.homeDir }}`, `{{ .profile }}`
- To output literal template delimiters, use: `{{ "{{ .chezmoi.homeDir }}" }}`
- `chezmoi add --autotemplate` over-substitutes `:` and `/` in JSON — use `chezmoi add --template` + manual `sed` for homeDir substitution

## .chezmoiignore Gotchas

- `*.txt` at root level does NOT match nested paths like `.config/gh/extensions.txt`
- Use `**/*.txt` for recursive matching
- Always verify with `chezmoi managed | grep <pattern>` after adding entries
- New repo-only files (docs, scripts, CI) must be added to `.chezmoiignore`

## Declarative Sync Pattern

For files managed by external tools (plugins, extensions):
1. Maintain a text list of entries (one per line)
2. Use `run_onchange_` script tracking the list's hash
3. Script installs/adds each entry from the list
4. Use a `scripts/update-*.sh` helper to regenerate the list from current state
5. Removal requires manual action — removing a line does not uninstall

Examples: marketplace sync (`dot_claude/plugins/marketplaces.txt` + `.chezmoiscripts/run_onchange_after_add-marketplaces.sh.tmpl` + `scripts/update-marketplaces.sh`), gh extensions (`dot_config/gh/extensions.txt` + `.chezmoiscripts/run_onchange_after_install-gh-extensions.sh.tmpl` + `scripts/update-gh-extensions.sh`)
