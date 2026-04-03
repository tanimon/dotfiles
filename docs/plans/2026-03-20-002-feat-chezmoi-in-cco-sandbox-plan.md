---
title: "feat: Enable chezmoi read-only commands inside cco sandbox"
type: feat
status: completed
date: 2026-03-20
---

# feat: Enable chezmoi read-only commands inside cco sandbox

## Overview

cco sandbox 内で `chezmoi diff`, `chezmoi data`, `chezmoi managed`, `chezmoi apply --dry-run` を実行できるようにする。現状は `~/.config/chezmoi` へのアクセスが拒否され、全ての chezmoi コマンドが失敗する。

## Problem Statement

cco `--safe` モードは `$HOME` 配下の `file-read*` と `file-write*` を拒否し、`allow-paths` に記載されたパスのみ選択的に許可する。chezmoi は以下が必要:

1. **設定ディレクトリ**: `~/.config/chezmoi/` — 全コマンドに必須
2. **ソースディレクトリ**: `~/.local/share/chezmoi/` — diff/managed/apply に必須
3. **ターゲットファイル**: `~/` 配下の管理対象ファイル — diff で現状との比較に必要

## Scope

**In scope (read-only commands):**
- `chezmoi diff` — ソースとターゲットの差分表示
- `chezmoi data` — テンプレートデータ表示
- `chezmoi managed` — 管理対象ファイル一覧
- `chezmoi apply --dry-run` — 適用プレビュー

**Out of scope:**
- `chezmoi apply` (フル実行) — ほぼ全 `$HOME` への書き込みが必要で、sandbox の意義が失われる
- `chezmoi add` — ソースディレクトリへの書き込みが必要。必要時は sandbox 外で実行
- `run_onchange_` スクリプトの実行 — `brew`, `pnpm`, `gh` 等の外部ツール + ネットワーク必要

## Technical Approach

### `allow-paths.tmpl` に追加が必要なパス

chezmoi バイナリは `/opt/homebrew/bin/chezmoi` (`$HOME` 外) なので sandbox 制限対象外。

#### 1. chezmoi インフラ (新規追加)

```
# chezmoi config (needed for all chezmoi commands)
{{ .chezmoi.homeDir }}/.config/chezmoi:ro
# chezmoi source directory (needed for diff, managed, apply --dry-run)
{{ .chezmoi.homeDir }}/.local/share/chezmoi:ro
```

#### 2. 管理対象ターゲット — $HOME ルートのドットファイル (新規追加)

`--add-dir` は個別ファイルもサポート (Seatbelt `literal` ルールが生成される):

```
# chezmoi target: shell configs
{{ .chezmoi.homeDir }}/.zshrc:ro
{{ .chezmoi.homeDir }}/.zprofile:ro
{{ .chezmoi.homeDir }}/.bashrc:ro
{{ .chezmoi.homeDir }}/.bash_profile:ro
# chezmoi target: editor/terminal
{{ .chezmoi.homeDir }}/.vimrc:ro
{{ .chezmoi.homeDir }}/.tmux.conf:ro
{{ .chezmoi.homeDir }}/.cVimrc:ro
# chezmoi target: claude.json (managed via modify_ script)
{{ .chezmoi.homeDir }}/.claude.json:ro
```

注: `~/.gitconfig` と `~/.gitignore` は既に allow-paths に存在。

#### 3. 管理対象ターゲット — ~/.config サブディレクトリ (新規追加)

既存エントリ: `~/.config/gh:ro`, `~/.config/git:ro`

不足分:

```
# chezmoi target: config directories
{{ .chezmoi.homeDir }}/.config/cco:ro
{{ .chezmoi.homeDir }}/.config/ghostty:ro
{{ .chezmoi.homeDir }}/.config/mise:ro
{{ .chezmoi.homeDir }}/.config/sheldon:ro
{{ .chezmoi.homeDir }}/.config/starship.toml:ro
{{ .chezmoi.homeDir }}/.config/yazi:ro
{{ .chezmoi.homeDir }}/.config/zellij:ro
{{ .chezmoi.homeDir }}/.config/zsh:ro
```

#### 4. 管理対象ターゲット — 既にカバー済み

以下は既存 allow-paths でカバー済み:

| ターゲット | 既存エントリ |
|-----------|------------|
| `~/.claude/` 配下 | `~/.claude` (rw) |
| `~/.config/gh/` | `~/.config/gh:ro` |
| `~/.config/git/` | `~/.config/git:ro` |
| `~/.gitconfig` | `~/.gitconfig:ro` |
| `~/.gitignore` | `~/.gitignore:ro` |
| `~/.local/bin/` | `~/.local/bin:ro` |
| `~/.local/share/mise/` | `~/.local/share/mise:ro` |
| `~/.ssh/` | `~/.ssh:ro` |

### 実装手順

#### Phase 1: allow-paths.tmpl 更新

`dot_config/cco/allow-paths.tmpl` に chezmoi セクションを追加。既存のパスとの重複・包含関係に注意:

- `~/.local/share/chezmoi:ro` は新規 (既存の `~/.local/share/mise:ro` や `~/.local/share/claude:ro` とは別パス)
- `~/.config/chezmoi:ro` は新規
- `~/.config/zsh:ro` は新規 (cco.zsh 自体がここにデプロイされる)

#### Phase 2: 動作検証

```bash
# sandbox 内で chezmoi コマンドを実行して検証
chezmoi data          # 最もシンプル — config 読み込みのみ
chezmoi managed       # source dir 読み込み
chezmoi diff          # source + target 読み込み
chezmoi apply --dry-run  # modify_ スクリプト評価含む
```

#### Phase 3: 問題があればデバッグ

```bash
# EPERM の発生箇所を特定
chezmoi diff 2>&1 | grep -i "permission\|eperm\|not permitted"
# または sandbox 外で managed paths を取得してカバー漏れを確認
command chezmoi managed --path-style absolute | xargs -I{} dirname {} | sort -u
```

## Acceptance Criteria

- [ ] `chezmoi data` が cco sandbox 内で正常に実行できる
- [ ] `chezmoi managed` が cco sandbox 内で正常に実行できる
- [ ] `chezmoi diff` が cco sandbox 内で正常に実行できる
- [ ] `chezmoi apply --dry-run` が cco sandbox 内で正常に実行できる
- [ ] 既存の sandbox セキュリティ (ghq 以外への書き込み制限) が維持される
- [ ] 新規追加パスは全て `:ro` (read-only) である

## Dependencies & Risks

- **Risk**: `chezmoi diff` が想定外のパスを読む可能性 → 検証時に EPERM エラーを確認し、必要に応じてパスを追加
- **Risk**: `--add-dir` で個別ファイル指定が多くなると Seatbelt ポリシーが肥大化 → 現状は10ファイル程度なので問題なし
- **Risk**: `chezmoi apply --dry-run` が `modify_dot_claude.json` を評価する際に `jq` が必要 → `jq` は `/opt/homebrew/bin/jq` ($HOME 外) なので OK。ソースファイル読み込みは `~/.local/share/chezmoi:ro` でカバー

## Sources & References

- cco `--add-dir` はファイル・ディレクトリ両対応 (ファイルは Seatbelt `literal`、ディレクトリは `subpath`)
- 既存 allow-paths パターン: `dot_config/cco/allow-paths.tmpl`
- cco sandbox patch: `.chezmoiscripts/run_onchange_after_patch-cco-sandbox.sh.tmpl`
- Memory: [cco_seatbelt_file_read_metadata.md](../../.claude/projects/-Users-akito-tanikado--local-share-chezmoi/memory/cco_seatbelt_file_read_metadata.md)
