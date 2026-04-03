---
title: "feat: Add gtr shell completion and fzf worktree navigation"
type: feat
status: completed
date: 2026-03-23
---

# feat: Add gtr shell completion and fzf worktree navigation

## Overview

git-worktree-runner (gtr) を快適に使うための 2 つの改善:

1. **zsh shell 補完の有効化** — `git gtr completion zsh` の出力を zshrc に組み込む
2. **fzf ワークツリーナビゲーション** — `gtr list` の結果を fzf で選択して `cd` するシェル関数

## Problem Statement / Motivation

- gtr は `git gtr completion zsh` で補完スクリプト生成をサポートしているが、現在の dotfiles では有効化されていない
- gtr 管理下のワークツリーへ移動するには、`git gtr list` でパスを目視確認してから手動で `cd` する必要があり手間

## Proposed Solution

### 1. Shell 補完の有効化

`dot_zshrc` の Completion セクション（既存の `source <(chezmoi completion zsh)` 等と同じパターン）に追加:

```zsh
command -v git &>/dev/null && eval "$(git gtr completion zsh)"
```

**配置**: `compinit` の後、他の `source <(... completion zsh)` と同じブロック内。gtr の補完は `compdef` ベースなので `compinit` の後で OK。ただし、gtr は git サブコマンドとして動作するため `eval` を使う（`source <(...)` ではなく）。

**注意**: `carapace` (line 61) も使用されているが、carapace は bridge モードで zsh/fish/bash の補完を統合する。gtr が carapace に対応していない場合は直接 `eval` で補完を登録する方がシンプル。

### 2. fzf ワークツリーナビゲーション関数 `gwt`

`dot_config/zsh/` に新しいファイル `worktree.zsh` を作成し、`dot_zshrc` から source する。

```zsh
# Fuzzy-find and cd into a git worktree managed by gtr
gwt() {
  if ! command -v git &>/dev/null || ! git gtr version &>/dev/null 2>&1; then
    echo "gwt: git-gtr is required but not available" >&2
    return 1
  fi
  if ! command -v fzf &>/dev/null; then
    echo "gwt: fzf is required but not installed" >&2
    return 1
  fi

  local line
  line=$(git gtr list --porcelain | fzf --delimiter='\t' --with-nth=2 --header 'Select worktree') || return 0
  local dir
  dir=$(printf '%s' "$line" | cut -f1)

  if [[ -d "$dir" ]]; then
    cd "$dir" || return 1
  else
    echo "gwt: directory not found: $dir" >&2
    return 1
  fi
}
```

**関数名 `gwt`**: "git worktree" の略。短く打ちやすい。

**porcelain 出力の形式** (タブ区切り):
```
/path/to/repo	main	clean
/path/to/repo-worktrees/feature-auth	feature-auth	clean
```

- `--with-nth=2`: fzf にはブランチ名のみ表示（パスは選択後に使用）
- `--delimiter='\t'`: タブ区切りでフィールド分割
- `cut -f1`: 選択行からパス（第1フィールド）を取得

## Technical Considerations

### ファイル構成

| ファイル | 変更内容 |
|---------|---------|
| `dot_zshrc` | gtr 補完の `eval` 追加 + `worktree.zsh` の `source` 追加 |
| `dot_config/zsh/worktree.zsh` (新規) | `gwt` 関数定義 |

### 設計判断

- **専用ファイル vs dot_zshrc 直書き**: `dot_config/zsh/worktree.zsh` に分離。path.zsh, sandbox.zsh と同じパターン。関心の分離を維持
- **`gwt` の補完**: `gwt` 自体には引数がないので補完不要
- **zoxide との共存**: `cd` は zoxide で `z` にエイリアスされている（`zoxide init zsh --cmd cd`）。`gwt` 内の `cd` は zoxide 経由になるので、ディレクトリ履歴にも反映される

## Acceptance Criteria

- [ ] `git gtr <TAB>` で gtr のサブコマンド補完が動作する
- [ ] `gwt` で fzf が起動し、ワークツリー一覧がブランチ名で表示される
- [ ] fzf で選択するとそのワークツリーのディレクトリに `cd` する
- [ ] Esc/Ctrl-C でキャンセルした場合、カレントディレクトリが変わらない
- [ ] gtr 未インストール / fzf 未インストール時にわかりやすいエラーメッセージ
- [ ] `chezmoi apply --dry-run` で正しく適用される

## Implementation Steps

1. `dot_config/zsh/worktree.zsh` を新規作成（`gwt` 関数）
2. `dot_zshrc` に `source ~/.config/zsh/worktree.zsh` を追加（sandbox.zsh の後）
3. `dot_zshrc` の Completion セクションに `eval "$(git gtr completion zsh)"` を追加
4. `chezmoi apply --dry-run` で確認
5. 動作テスト

## Sources & References

- [git-worktree-runner README](https://github.com/coderabbitai/git-worktree-runner) — `completion zsh` コマンド、`list --porcelain` 出力形式
- 既存パターン: `dot_zshrc:31-36` — 他ツールの補完設定
- 既存パターン: `dot_config/zsh/path.zsh`, `sandbox.zsh` — zsh 設定ファイル分離
- 既存パターン: `dot_local/bin/executable_gtr-copy` — fzf + worktree の組み合わせ
