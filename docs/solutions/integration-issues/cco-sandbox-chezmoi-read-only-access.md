---
title: "cco sandbox 内で chezmoi read-only コマンドを有効にする"
category: integration-issues
date: 2026-03-20
tags: [cco, sandbox, chezmoi, seatbelt, allow-paths]
modules: [cco, chezmoi]
---

# cco sandbox 内で chezmoi read-only コマンドを有効にする

## Problem

cco `--safe` モードの sandbox 内で `chezmoi diff`, `chezmoi data`, `chezmoi managed` 等を実行すると、`open ~/.config/chezmoi: operation not permitted` で即座に失敗する。

## Root Cause

cco `--safe` は `$HOME` 配下の全ファイルへの read/write を拒否し、`allow-paths` に記載されたパスのみ選択的に許可する。chezmoi は以下の 3 カテゴリのパスにアクセスが必要:

1. **設定ディレクトリ** (`~/.config/chezmoi/`) — 全コマンドの起動時に必須
2. **ソースディレクトリ** (`~/.local/share/chezmoi/`) — diff, managed で参照
3. **ターゲットファイル** (管理対象の `~/` 配下ファイル) — diff で現状比較に必要

## Solution

`dot_config/cco/allow-paths.tmpl` に chezmoi 関連のパスを `:ro` (read-only) で追加する。

### 追加すべきパスの 3 カテゴリ

**1. chezmoi インフラ:**
```
{{ .chezmoi.homeDir }}/.config/chezmoi:ro
{{ .chezmoi.homeDir }}/.local/share/chezmoi:ro
```

**2. $HOME ルートのドットファイル (既存エントリでカバーされないもの):**
```
{{ .chezmoi.homeDir }}/.zshrc:ro
{{ .chezmoi.homeDir }}/.zprofile:ro
{{ .chezmoi.homeDir }}/.vimrc:ro
{{ .chezmoi.homeDir }}/.claude.json:ro
# etc.
```

**3. ~/.config サブディレクトリ (既存エントリでカバーされないもの):**
```
{{ .chezmoi.homeDir }}/.config/ghostty:ro
{{ .chezmoi.homeDir }}/.config/sheldon:ro
{{ .chezmoi.homeDir }}/.config/zsh:ro
# etc.
```

### 重要なポイント

- `--add-dir` はファイルもディレクトリもサポートする。ファイルは Seatbelt `literal` ルール、ディレクトリは `subpath` ルールが生成される
- `~/.claude` (ディレクトリ) の allow-path は `~/.claude.json` (ファイル) をカバーしない — 別エントリが必要
- 既存の allow-paths と重複しないよう、`chezmoi managed` の出力と照合して不足分のみ追加する

### スコープの判断: read-only のみ

`chezmoi apply` (フル実行) は以下の理由でスコープ外とした:

- ほぼ全 `$HOME` への書き込み権限が必要 → sandbox の意義が失われる
- `run_onchange_` スクリプトが `brew`, `pnpm`, `gh`, `claude` 等を実行 → ネットワークアクセスも必要
- `run_onchange_after_add-marketplaces.sh` が `claude` を呼ぶ → cco shell function 経由で二重 sandbox になり未定義動作

read-only コマンド (`diff`, `data`, `managed`, `apply --dry-run`) は sandbox の意義を損なわず実用的。

## Prevention

新しいファイルを chezmoi 管理に追加した場合、そのターゲットパスが `allow-paths.tmpl` に含まれているか確認する。含まれていないと sandbox 内での `chezmoi diff` が不正確な結果を返す（EPERM を差分として表示する可能性がある）。

確認コマンド（sandbox 外で実行）:
```bash
chezmoi managed --path-style absolute | xargs -I{} dirname {} | sort -u
```
