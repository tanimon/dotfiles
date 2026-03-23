---
title: "gtr shell integration: use `git gtr init zsh` instead of custom wrappers"
category: integration-issues
date: 2026-03-23
tags:
  - git-worktree-runner
  - gtr
  - zsh
  - shell-integration
  - fzf
modules:
  - dot_zshrc
  - dot_config/zsh
---

# gtr shell integration: use `git gtr init zsh` instead of custom wrappers

## Problem

git-worktree-runner (gtr) の shell 補完と worktree ナビゲーション（fzf でワークツリーを選択して cd）を追加しようとした際、カスタム関数 `gwt` を自作してしまった。

## Root Cause

`git gtr completion zsh` と `git gtr list --porcelain` の存在は調査で発見したが、`git gtr init zsh` によるシェル統合（`gtr cd`, `gtr new --cd` 等）の存在を見逃していた。DeepWiki への質問が `completion` と `list` に限定されていたため。

## Solution

`git gtr init zsh` を使う。これ一つで以下が全て有効になる:

- **`gtr cd <branch>`** — 指定ワークツリーに cd
- **`gtr cd`**（引数なし）— fzf ピッカーで選択して cd。さらにキーバインド付き:
  - `ctrl-e`: エディタで開く
  - `ctrl-a`: AI ツール起動
  - `ctrl-d`: ワークツリー削除
  - `ctrl-y`: ファイルコピー
  - `ctrl-r`: リスト更新
- **`gtr new <branch> --cd`** — 新規作成して即 cd
- **補完** — `gtr <TAB>` でサブコマンド補完

### zshrc 設定（公式推奨のキャッシュパターン）

```zsh
# gtr shell integration: provides `gtr cd`, `gtr new --cd`, and completions
_gtr_init="${XDG_CACHE_HOME:-$HOME/.cache}/gtr/init-gtr.zsh"
[[ -f "$_gtr_init" ]] || eval "$(git gtr init zsh)" 2>/dev/null || true
source "$_gtr_init" 2>/dev/null || true; unset _gtr_init
```

キャッシュにより起動時間は ~1ms（毎回 eval だと ~60ms）。

### 確認方法

```bash
git gtr help init    # シェル統合の詳細ヘルプ
git gtr init zsh     # 生成されるスクリプトの確認
```

## Prevention

- gtr のような CLI ツールのラッパーを自作する前に、`help init` や `help` で公式のシェル統合機能を確認する
- DeepWiki 等で調査する際、`completion` だけでなく `init`, `shell integration`, `cd` 等のキーワードでも質問する
- `git gtr help` のサブコマンド一覧を最初に確認する

## References

- [git-worktree-runner](https://github.com/coderabbitai/git-worktree-runner)
- PR: https://github.com/tanimon/dotfiles/pull/47
