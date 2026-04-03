---
title: "chore: remove fzf-tab plugin"
type: chore
status: completed
date: 2026-03-23
---

# chore: remove fzf-tab plugin

## Overview

fzf-tab（Aloxaf/fzf-tab）を sheldon プラグインから削除し、zsh 組み込みの補完 UI に戻す。

## Problem Statement

fzf-tab を利用する必要がなくなったため、プラグイン構成をシンプルにする。

## Proposed Solution

fzf-tab を sheldon から削除し、代わりに zsh 組み込みの `menu select` を復活させる。`fzf --zsh` によるキーバインド（Ctrl-R, Ctrl-T, Alt-C）は fzf-tab とは独立しているため影響なし。

## Changes

### Phase 1: プラグイン削除

#### 1.1 `dot_config/sheldon/plugins.toml`

- `[plugins.fzf-tab]` セクション（2行）を削除
- fzf-tab に言及するロード順序コメント（15-17行目）を更新

```diff
-# Load order matters: sheldon sources plugins in declaration order.
-# fzf-tab must load after compinit (handled in .zshrc) and before
-# zsh-autosuggestions / zsh-syntax-highlighting which wrap widgets.
```

#### 1.2 `dot_zshrc`

- `zstyle ':completion:*' menu select` を追加（fzf-tab 導入時に削除された組み込み補完メニュー UI を復活）

```diff
 zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}' '+m:{A-Z}={a-z}'
 zstyle ':completion:*' format $'\e[2;37mCompleting %d\e[m'
+zstyle ':completion:*' menu select
 zstyle ':completion:*:git:*' group-order 'main commands' 'alias commands' 'external commands'
```

### Phase 2: ドキュメント整理

#### 2.1 `docs/solutions/integration-issues/fzf-tab-sheldon-load-order-and-zstyle-conflicts.md`

- 削除（fzf-tab を使わなくなるため不要）

## 影響範囲

- **sheldon lock**: `plugins.toml` 変更により `run_onchange_after_sheldon-lock.sh.tmpl` が自動で `sheldon lock --update` を実行 → fzf-tab がアンロードされる
- **fzf**: `fzf --zsh` キーバインド（Ctrl-R/Ctrl-T/Alt-C）は影響なし
- **carapace**: 補完定義の提供のみで UI レイヤーとは独立 → 影響なし
- **zsh-autosuggestions / zsh-syntax-highlighting**: ロード順序の制約が緩和される（fzf-tab との順序を気にする必要がなくなる）

## Acceptance Criteria

- [ ] `plugins.toml` から fzf-tab エントリが削除されている
- [ ] `dot_zshrc` に `menu select` zstyle が追加されている
- [ ] fzf-tab の solutions ドキュメントが削除されている
- [ ] `chezmoi apply --dry-run` でエラーがないこと

## Sources

- `dot_config/sheldon/plugins.toml:25-26` — 現在の fzf-tab 宣言
- `dot_zshrc:23-28` — 現在の completion 設定
- `docs/solutions/integration-issues/fzf-tab-sheldon-load-order-and-zstyle-conflicts.md` — fzf-tab 導入時の知見
