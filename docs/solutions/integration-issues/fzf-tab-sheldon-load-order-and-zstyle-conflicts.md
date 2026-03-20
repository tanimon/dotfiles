---
title: "fzf-tab: sheldon ロード順序と zstyle menu select の競合"
category: integration-issues
date: 2026-03-21
tags: [zsh, fzf-tab, sheldon, completion, plugin-load-order]
---

# fzf-tab: sheldon ロード順序と zstyle menu select の競合

## Problem

fzf-tab（Aloxaf/fzf-tab）を sheldon 経由で zsh に導入する際、既存の補完設定との競合とプラグインのロード順序に注意が必要。

## Root Cause

2つの競合ポイントがある:

1. **`zstyle ':completion:*' menu select`** — fzf-tab は zsh 組み込みのメニュー選択 UI を fzf ベースに**置き換える**プラグイン。`menu select` が有効だと内部で無効化を試みるが、意図しない挙動の原因になり得る。

2. **プラグインロード順序** — fzf-tab は `compinit` の後、かつ zsh-autosuggestions / zsh-syntax-highlighting の**前**にロードする必要がある。これらのプラグインはウィジェットをラップするため、fzf-tab が後からロードされると補完インターセプトが正しく機能しない。

## Solution

### 1. sheldon plugins.toml のロード順序

sheldon はファイル内の宣言順でプラグインをソースするため、TOML 内の位置が重要:

```toml
# fzf-tab は compinit の後（.zshrc で処理済み）、
# zsh-autosuggestions / zsh-syntax-highlighting の前にロードする

[plugins.zsh-completions]
github = "zsh-users/zsh-completions"

[plugins.fzf-tab]
github = "Aloxaf/fzf-tab"

[plugins.zsh-autosuggestions]
github = "zsh-users/zsh-autosuggestions"

[plugins.zsh-syntax-highlighting]
github = "zsh-users/zsh-syntax-highlighting"
```

### 2. menu select の削除

```diff
- zstyle ':completion:*' menu select
```

### 3. sheldon lock の自動化

chezmoi で管理する場合、`plugins.toml` 変更時に `sheldon lock --update` を自動実行する `run_onchange_` スクリプトが必要:

```bash
# .chezmoiscripts/run_onchange_after_sheldon-lock.sh.tmpl
# sheldon plugins hash: {{ include "dot_config/sheldon/plugins.toml" | sha256sum }}
sheldon lock --update
```

`sheldon source` は lock ファイルが存在すればそこから読むが、新しいプラグインが追加された場合に自動フェッチが保証されない。

## 共存可能な設定

以下の既存設定は fzf-tab と干渉しない:

- `zstyle ':completion:*' matcher-list` — compinit の候補生成ルールで、fzf-tab の UI とは独立
- `zstyle ':completion:*' format` — fzf-tab のグループヘッダーとして表示される
- `zstyle ':completion:*:git:*' group-order` — fzf-tab でもグループ順序として反映
- `fzf --zsh` — Ctrl-R/Ctrl-T/Alt-C のキーバインドのみ。Tab 補完とは機能が異なる
- carapace — 補完定義を追加するだけで UI レイヤーとは独立

## Prevention

- sheldon で新しいプラグインを追加する際は、必ず既存プラグインとの**ロード順序の依存関係**を確認する
- 補完 UI を変更するプラグインを導入する際は、`zstyle menu select` など組み込み UI の設定と競合しないか確認する
- chezmoi 管理下では `run_onchange_` スクリプトでパッケージマネージャの lock/update を自動化する
