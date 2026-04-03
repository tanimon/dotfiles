---
title: "feat: Add daily development paths to safehouse config"
type: feat
status: completed
date: 2026-03-20
depth: Quick
---

# feat: Add daily development paths to safehouse config

## Overview

safehouse config に日常開発で必要なパスと enable モジュールを追加する。現状 `chezmoi diff` が `.local/share/cco` への `lstat` で失敗するなど、パス不足で開発ツールがブロックされている。

## Problem Statement

1. **`chezmoi diff` が失敗**: `.local/share/cco` が `.chezmoiexternal.toml` で管理されているが、safehouse config に含まれていないため `lstat` で EPERM
2. **docker 未有効化**: docker がインストール済みだが `--enable=docker` がない
3. **開発ツール系パス不足**: `.bun`, `.pnpm-state`, `.agents`, エディタ設定（helix, zed, karabiner）等が未登録
4. **`shell-init` 未有効化**: safehouse が shell startup file の読み取りをネイティブサポートしているが、個別ファイルを手動列挙している

## Proposed Changes

### 1. enable モジュール追加

| Module | Rationale |
|--------|-----------|
| `docker` | docker/colima が日常使用 |
| `shell-init` | shell 起動ファイルの読み取りを自動化（個別 dotfile 列挙を置換） |
| `clipboard` | 開発中の copy/paste |
| `process-control` | プロセス一覧・シグナル送信（デバッグ用途） |

### 2. 読み取り専用パス追加

| Path | Rationale |
|------|-----------|
| `~/.local/share/cco` | chezmoi external で管理、chezmoi diff に必須 |
| `~/.bun` | bun ランタイム |
| `~/.pnpm-state` | pnpm 状態 |
| `~/.agents` | agent skills |
| `~/.config/helix` | エディタ設定 |
| `~/.config/karabiner` | キーボード設定 |
| `~/.config/zed` | エディタ設定 |
| `~/.config/opencode` | opencode 設定 |

### 3. `shell-init` による dotfile エントリ整理

`--enable=shell-init` が有効になると safehouse が shell startup files を自動で読み取るため、以下の手動エントリを削除可能:
- `~/.zshrc`, `~/.zprofile`, `~/.bashrc`, `~/.bash_profile`

ただし `~/.vimrc`, `~/.tmux.conf`, `~/.cVimrc` は shell startup files ではないため残す。

## Risk Assessment

- **リスク: 低** — 全て読み取り専用パスの追加か、safehouse 公式モジュールの有効化
- `process-control` は若干のセキュリティ緩和だが、デバッグに必要
- `shell-init` への移行は手動エントリ削除を伴うが、safehouse のネイティブサポートなので安全

## Verification

```sh
# safehouse で chezmoi diff が成功するか確認
chezmoi diff --exclude=externals  # or full diff

# safehouse --explain で effective grants を確認
safehouse --explain --stdout 2>&1 | head -40
```
