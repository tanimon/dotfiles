---
title: "feat: Migrate sandbox from cco to agent-safehouse"
type: feat
status: completed
date: 2026-03-20
---

# feat: Migrate sandbox from cco to agent-safehouse

## Overview

cco (Claude Condom) を agent-safehouse に置き換える。両ツールとも macOS Seatbelt (`sandbox-exec`) を使用するが、safehouse は deny-all デフォルト、composable プロファイル、自動 symlink 解決、Homebrew 配布など、cco で手動パッチが必要だった問題を標準で解決している。

## Problem Statement / Motivation

cco の現在の統合には以下の課題がある:

1. **手動パッチが必要**: Node.js `realpathSync` EPERM を修正する `run_onchange_after_patch-cco-sandbox.sh.tmpl` が必要
2. **allow-default モデル**: cco の native sandbox は `(allow default)` ベースで、ホスト FS 全体が読み取り可能（`--safe` なしの場合）
3. **設定の制約**: `CCO_SANDBOX_ARGS_FILE` はバックエンドパススルー専用、cco レベルフラグは処理されない
4. **statusline ワークアラウンド**: `/tmp` にキャッシュする専用ラッパースクリプトが必要
5. **エージェント対応**: 6 エージェントのみ（safehouse は 14）

safehouse はこれらを標準機能で解決:
- base profile で `file-read-metadata` を `$HOME` に自動許可（パッチ不要）
- `(deny default)` ベース（セキュリティデフォルト強化）
- `--append-profile`, `--enable=` による柔軟な設定
- `--explain --stdout` でポリシーデバッグ可能

## Proposed Solution

cco の全統合ポイントを safehouse 等価物に置き換える。cco は `.chezmoiexternal.toml` に残し、Linux フォールバック用に保持する。

## Technical Considerations

### safehouse は macOS 専用

safehouse に Linux サポートはない（issue #14 で要望中、未実装）。この dotfiles リポジトリは macOS 専用だが、将来の Linux 対応を考慮し cco の完全削除は行わない。

### cco allow-paths → safehouse マッピング

| cco allow-paths エントリ | safehouse 等価物 |
|---|---|
| `~/ghq` (rw) | `--add-dirs=$HOME/ghq` |
| `~/.local/bin:ro` | `--add-dirs-ro=$HOME/.local/bin` |
| `~/.local/share/claude:ro` | claude-code.sb プロファイルで自動対応 |
| `~/.ssh:ro` | `--enable=ssh` |
| `~/.colima:ro` | `--add-dirs-ro=$HOME/.colima` |
| `~/.gitconfig:ro`, `~/.gitignore:ro`, `~/.config/git:ro` | 50-integrations-core/git.sb で自動対応 |
| `~/.local/share/mise:ro` | 30-toolchains/runtime-managers.sb で自動対応 |
| `~/.config/gh:ro` | 50-integrations-core/scm-clis.sb で自動対応 |
| `~/Library/Keychains:ro` | `--enable=keychain` |
| `~/Library/Group Containers/2BUA8C4S2C.com.1password:ro` | `--enable=1password` |
| `~/.cache` (rw) | `--add-dirs=$HOME/.cache` |
| `~/.claude` (rw) | claude-code.sb プロファイルで自動対応 |
| `~/.codex` (rw) | codex.sb プロファイルで自動対応 |
| `~/.config/chezmoi:ro`, `~/.local/share/chezmoi:ro` | `--add-dirs-ro=` で明示追加 |
| `~/.zshrc:ro` 等の dotfiles | `--enable=shell-init` または `--add-dirs-ro=` |
| `~/.config/*` 各種 | `--add-dirs-ro=` で明示追加 |

### statusline wrapper の必要性

safehouse の base profile は `(allow file-read-metadata (subpath "$HOME"))` を含み、`$HOME` 配下の stat/lstat を許可する。ただし `file-read-data` は依然 deny-all なので、`~/.claude/statusline-command.ts` の**内容読み取り**には claude-code.sb プロファイルの `~/.claude` 許可が必要。safehouse の claude-code.sb が `~/.claude` に r/w アクセスを付与するため、statusline wrapper は不要になる可能性が高い。検証が必要。

### Seatbelt deprecation

両ツールとも `sandbox-exec` に依存。Apple は deprecated としているが代替 API は提供されておらず、現行 macOS で動作する。リスクは同等。

## Acceptance Criteria

- [ ] safehouse が Brewfile 経由でインストールされる
- [ ] `claude` コマンドで safehouse 経由のサンドボックス実行される
- [ ] cco の allow-paths と同等のアクセス制御が safehouse で実現される
- [ ] Node.js EPERM パッチが不要（safehouse 標準で解決）
- [ ] statusline が正常動作する（wrapper 不要なら削除）
- [ ] `command claude` で引き続きサンドボックスバイパス可能
- [ ] cco 関連ファイルは残すが、デフォルトでは safehouse を使用
- [ ] `chezmoi apply` で新規マシンに safehouse 設定がデプロイされる

## Implementation Plan

### Phase 1: safehouse インストール

1. Brewfile に `tap "eugene1g/safehouse"` と `brew "eugene1g/safehouse/agent-safehouse"` を追加
2. `scripts/update-brewfile.sh` を実行して Brewfile を更新（または手動追加）

**Files:**
- `darwin/Brewfile`

### Phase 2: safehouse 用シェルラッパー作成

`dot_config/zsh/cco.zsh` を `dot_config/zsh/sandbox.zsh` に置き換え（またはリネーム）。

新しいラッパーの設計:
- safehouse の存在を確認し、なければ cco にフォールバック
- 設定ファイル `~/.config/safehouse/config` から追加パスを読み込み
- `--enable=` モジュールを適用
- `--append-profile` でカスタムポリシーを適用

```zsh
# Sandbox Claude Code via safehouse (deny-all default)
# Falls back to cco if safehouse is not installed
# Use `command claude` or `\claude` to bypass
claude() {
  if command -v safehouse &>/dev/null; then
    _claude_safehouse "$@"
  elif command -v cco &>/dev/null; then
    _claude_cco "$@"
  else
    command claude "$@"
  fi
}

_claude_safehouse() {
  local -a args=()
  local config="${XDG_CONFIG_HOME:-$HOME/.config}/safehouse/config"
  if [[ -f "$config" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" || "$line" == \#* ]] && continue
      args+=($line)
    done < "$config"
  fi
  command safehouse "${args[@]}" -- claude --dangerously-skip-permissions "$@"
}

_claude_cco() {
  local -a cco_args=(--safe)
  local config="${XDG_CONFIG_HOME:-$HOME/.config}/cco/allow-paths"
  if [[ -f "$config" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" || "$line" == \#* ]] && continue
      cco_args+=(--add-dir "$line")
    done < "$config"
  fi
  command cco "${cco_args[@]}" "$@"
}
```

**Files:**
- `dot_config/zsh/cco.zsh` → リネームまたは内容置換
- `dot_zshrc` → source パス更新（必要な場合）

### Phase 3: safehouse 設定ファイル作成

`dot_config/safehouse/config.tmpl` を作成。safehouse の CLI フラグを 1 行 1 引数で記述。

```
# safehouse configuration for Claude Code sandbox
# Each line is passed as a CLI argument to safehouse

# Enable integrations
--enable=ssh
--enable=keychain
--enable=1password

# Working directories (read-write)
--add-dirs=$HOME/ghq
--add-dirs=$HOME/.cache

# Read-only access
--add-dirs-ro=$HOME/.local/bin
--add-dirs-ro=$HOME/.colima
--add-dirs-ro=$HOME/.config/chezmoi
--add-dirs-ro=$HOME/.local/share/chezmoi
--add-dirs-ro=$HOME/.config/ghostty
--add-dirs-ro=$HOME/.config/mise
--add-dirs-ro=$HOME/.config/sheldon
--add-dirs-ro=$HOME/.config/starship.toml
--add-dirs-ro=$HOME/.config/yazi
--add-dirs-ro=$HOME/.config/zellij
--add-dirs-ro=$HOME/.config/zsh
--add-dirs-ro=$HOME/.config/cco
--add-dirs-ro=$HOME/.config/safehouse

# Dotfiles (read-only)
--add-dirs-ro=$HOME/.zshrc
--add-dirs-ro=$HOME/.zprofile
--add-dirs-ro=$HOME/.bashrc
--add-dirs-ro=$HOME/.bash_profile
--add-dirs-ro=$HOME/.vimrc
--add-dirs-ro=$HOME/.tmux.conf
--add-dirs-ro=$HOME/.cVimrc
--add-dirs-ro=$HOME/.claude.json
```

Note: chezmoi テンプレートで `{{ .chezmoi.homeDir }}` を使用してパスをレンダリング。

**Files:**
- `dot_config/safehouse/config.tmpl` (新規作成)

### Phase 4: statusline wrapper の検証と更新

safehouse の claude-code.sb プロファイルが `~/.claude` に r/w アクセスを付与するか確認。付与される場合:
1. statusline wrapper が不要か検証（safehouse 内で直接 `node --experimental-strip-types ~/.claude/statusline-command.ts` が動作するか）
2. 動作する場合は wrapper を削除し、`settings.json.tmpl` の statusline command を直接パスに変更
3. 動作しない場合は wrapper を残す（safehouse でも `/tmp` キャッシュが必要な可能性）

**Files:**
- `dot_claude/scripts/executable_statusline-wrapper.sh` (削除候補)
- `dot_claude/settings.json.tmpl` (statusline command パス更新)

### Phase 5: 不要になるファイルの整理

safehouse 移行後に不要になるもの:
- `.chezmoiscripts/run_onchange_after_patch-cco-sandbox.sh.tmpl` — safehouse ではパッチ不要
- `dot_config/cco/allow-paths.tmpl` — safehouse config に移行済み

削除ではなく、cco フォールバック用に残す。ただしシェルラッパーが safehouse 優先になるため、safehouse インストール済み環境では使用されない。

**Files:**
- `.chezmoiscripts/run_onchange_after_patch-cco-sandbox.sh.tmpl` (残置)
- `dot_config/cco/allow-paths.tmpl` (残置)
- `.chezmoiexternal.toml` (cco エントリ残置)
- `.chezmoiscripts/run_onchange_after_link-cco.sh.tmpl` (残置)

## Dependencies & Risks

### Dependencies
- Homebrew が利用可能であること（macOS 環境）
- safehouse v0.5.2+ が `--add-dirs`, `--add-dirs-ro`, `--enable=` をサポート

### Risks
- **safehouse のプロファイルが想定と異なる場合**: `--explain --stdout` でデバッグし `--append-profile` で補正
- **statusline 互換性**: safehouse 内での Node.js 動作を要検証
- **safehouse の breaking changes**: バージョンピン不可（Homebrew）、アップデートで挙動変更の可能性
- **`--enable=shell-init` の副作用**: shell startup files へのアクセスは意図的に制限したい場合がある（個別 `--add-dirs-ro` の方が安全）

## Sources & References

- [agent-safehouse GitHub](https://github.com/eugene1g/agent-safehouse)
- [agent-safehouse docs](https://agent-safehouse.dev/)
- 既存 cco 統合: `dot_config/zsh/cco.zsh`, `dot_config/cco/allow-paths.tmpl`
- 関連メモリ: `cco_seatbelt_file_read_metadata.md`, `seatbelt_wildcard_precedence.md`
