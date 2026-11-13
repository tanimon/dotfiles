---
date: 2026-03-28
trigger: "Agent uses wrong chezmoi file pattern or mishandles modify_ scripts"
paths:
  - "**/modify_*"
  - "**/*.tmpl"
  - ".chezmoiignore"
  - ".chezmoiscripts/**"
---

# chezmoi Patterns

Project-specific rules for working in this chezmoi dotfiles repository.

## File Type Selection

When adding or modifying managed files, choose the right chezmoi pattern:

| Pattern | When to use | Example |
|---------|-------------|---------|
| `.tmpl` (regular template) | chezmoi fully owns the file; no external tool modifies it | `dot_gitconfig.tmpl`, `dot_claude/settings.json.tmpl` |
| `create_` | Provision-once files that should not be overwritten on subsequent applies | (none currently in this repo) |
| `modify_` script | Runtime-mutable files where chezmoi owns a subset of keys (e.g., IDE configs) | `dot_config/karabiner/modify_karabiner.json` |
| `.chezmoiignore` + `run_onchange_` | Files managed entirely by external tools (plugin state, extension lists) | `dot_config/gh/extensions.txt` + `.chezmoiscripts/run_onchange_after_install-gh-extensions.sh.tmpl` |

## modify_ Script Safety

- Always include `set -e` at the top
- Never use OS guards (`{{ if eq .chezmoi.os "darwin" }}`) that wrap the entire script — on non-matching OS the script outputs nothing and chezmoi deletes the target
- Use `printf '%s\n'` (not `printf '%s'`) to preserve trailing newlines stripped by `$(cat)`
- For new-machine bootstrap (empty stdin), seed a minimal valid document inside the script before merging (see the `Bootstrap` block in `dot_config/karabiner/modify_karabiner.json`); never emit empty output
- See `dot_config/karabiner/modify_karabiner.json` for a well-documented example of partial JSON management
- Never target a path that may be a symlink managed outside this repo (e.g. `~/.claude.json`, which nono re-links to its real file (`~/.claude/.claude.json` on nono 0.79.0, not re-measured on 0.81.0) on every `nono run --profile claude-seal`; the topology has changed before, so check it with `ls -la` before relying on it) — chezmoi reads through the symlink for stdin but writes a plain file back, silently deleting the symlink. 管理が要るなら symlink ではなく実体を target し、symlink を `.chezmoiignore` に入れる。`~/.claude.json` は chezmoi で管理しないので、symlink と実体の**両方**を `.chezmoiignore` に入れる(前者だけでは一括 add が実体を拾う)。

## Template Syntax

- `.tmpl` files use Go template syntax: `{{ .chezmoi.homeDir }}`, `{{ .profile }}`
- To output literal template delimiters, use: `{{ "{{ .chezmoi.homeDir }}" }}`
- `chezmoi add --autotemplate` over-substitutes `:` and `/` in JSON — use `chezmoi add --template` + manual `sed` for homeDir substitution

## `chezmoi diff` の読み方

- **`chezmoi diff` の出力に `diff --git` ヘッダは無い。** このマシンの chezmoi は `[diff] command` が `chezmoi-json-diff`
  (`diff -u --label`)なので、`chezmoi diff | grep '^diff --git'` は差分があっても 0 件になる。apply で変わるファイルの一覧は
  `chezmoi status` で見て、差分の中身は `chezmoi diff` をそのまま読む。chezmoi-json-diff は JSON のキーの並びとファイルモードの差を
  出さないので、status に載っても diff が空のファイルがある(apply でバイト列やモードは変わる)。

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

Examples: gh extensions (`dot_config/gh/extensions.txt` + `.chezmoiscripts/run_onchange_after_install-gh-extensions.sh.tmpl` + `scripts/update-gh-extensions.sh`)

外部ツールが書き込む設定ファイルを、chezmoi 所有の `.tmpl` も毎 apply で再レンダリングする（= 2 者が同じファイルを取り合う）場合だけ、ハッシュゲート(`run_onchange_`)ではなく無条件で毎回実行する `run_after_` を使う。競合する `.tmpl` が無ければ `run_onchange_` で足りる。例: `apm-install` が書くのは `~/.claude.json` の `mcpServers` と `~/.codex/config.toml` の `[mcp_servers.*]` で、どちらも chezmoi は管理しないので `run_onchange_after_apm-install.sh.tmpl`。判断基準の詳細は `docs/solutions/architecture-patterns/run-after-vs-run-onchange-for-shared-config-ownership.md`。
