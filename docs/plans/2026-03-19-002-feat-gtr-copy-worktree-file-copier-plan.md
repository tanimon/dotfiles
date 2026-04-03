---
title: "feat: Add gtr-copy worktree file copier"
type: feat
status: active
date: 2026-03-19
origin: docs/brainstorms/2026-03-19-gtr-copy-requirements.md
---

# feat: Add gtr-copy worktree file copier

## Overview

git-worktree-runner (gtr) で作成した worktree 内で生成したファイルを、fzf によるインタラクティブな2ステップ操作（ファイル選択 → コピー先worktree選択）で他の worktree にコピーするシェルスクリプト。chezmoi 管理下で全マシンに配布する。

## Problem Statement / Motivation

gtr project 内で生成したファイル（特に `docs/` 配下）を親リポジトリや他の project にコピーする際、worktree のパスが長く `cp` コマンドを手打ちするのが煩雑。(see origin: docs/brainstorms/2026-03-19-gtr-copy-requirements.md)

## Proposed Solution

`~/.local/bin/gtr-copy` として配置するシェルスクリプト。fzf の `--multi` でファイルを選択し、`git worktree list` から現在の worktree を除外した一覧でコピー先を選択、`cp` + `mkdir -p` でディレクトリ構造を保持してコピーする。

## Technical Approach

### Source File Path

```
dot_local/bin/executable_gtr-copy
  → ~/.local/bin/gtr-copy (0755)
```

- `executable_` prefix で chezmoi が実行権限を付与
- `.tmpl` は不要（テンプレート変数を使わない）
- `~/.local/bin` は `$PATH` の先頭（`dot_config/zsh/path.zsh` で設定済み）
- `.chezmoiignore` に該当パターンなし — 追加設定不要

### Script Structure

```bash
#!/usr/bin/env bash
set -euo pipefail
```

#### Phase 1: Precondition Guards

1. `command -v fzf` — fzf がインストールされているか確認
2. `git rev-parse --show-toplevel` — git リポジトリ内か確認
3. worktree root を取得し、常に worktree root からの相対パスで動作

#### Phase 2: File Selection (R1)

**ファイル一覧の生成方法:**
```bash
cd "$worktree_root"
{ git ls-files; git ls-files --others --exclude-standard; } | sort -u
```

- `git ls-files` で tracked ファイルを列挙
- `git ls-files --others --exclude-standard` で untracked（未コミット）ファイルも含める
- **理由**: 主なユースケースが「Claude Code で生成した未コミットの docs/ ファイルのコピー」であるため、untracked ファイルの包含が必須

**fzf 呼び出し:**
```bash
selected_files=$(... | fzf --multi --preview 'bat --color=always {} 2>/dev/null || cat {}')
```

- `--multi` で複数ファイル選択（Tab キー）
- `--preview` で `bat`（なければ `cat`）によるファイル内容プレビュー
- fzf キャンセル（Esc/Ctrl-C）時は exit 0（インタラクティブツールの慣習）

#### Phase 3: Destination Selection (R2, R3)

```bash
git worktree list | grep -v "^$worktree_root " | fzf
```

- `git worktree list` の出力から現在の worktree を除外
- `(bare)` を含む行もフィルタ（bare worktree にはコピー不可）
- パス + ブランチ名を表示（`git worktree list` のデフォルト出力をそのまま利用）
- 選択結果からパス部分のみ抽出: `awk '{print $1}'`
- **コピー先が0件の場合**: fzf を起動せず `gtr-copy: no other worktrees found` を stderr に出力して exit 1

#### Phase 4: Copy Execution (R4)

```bash
for file in $selected_files; do
    dest_path="$dest_worktree/$file"
    mkdir -p "$(dirname "$dest_path")"
    cp "$file" "$dest_path"
done
```

- worktree root からの相対パスを保持してコピー
- `mkdir -p` で存在しないディレクトリを自動作成
- symlink はデリファレンス（`cp` デフォルト動作 — worktree 間では symlink 先が無効になる可能性が高い）
- 部分失敗時: 残りのファイルのコピーを続行し、エラーを収集して最後にまとめて報告
- コピー完了後、コピーしたファイル数とコピー先を表示

### Error Handling

| 状況 | 動作 |
|------|------|
| git リポジトリ外で実行 | stderr にエラー、exit 1 |
| fzf 未インストール | stderr にエラー、exit 1 |
| worktree が1つのみ | stderr にエラー、exit 1 |
| fzf キャンセル（Esc/Ctrl-C） | exit 0（正常終了） |
| コピー部分失敗 | 残りを続行、失敗をまとめて報告、exit 1 |

## Acceptance Criteria

- [ ] `gtr-copy` を worktree 内で実行し、fzf でファイルを複数選択できる
- [ ] コピー先 worktree を fzf で選択できる（現在の worktree は除外）
- [ ] 選択したファイルがディレクトリ構造を保持してコピーされる
- [ ] 未コミット（untracked）ファイルも fzf の一覧に表示される
- [ ] fzf でファイル内容のプレビューが表示される
- [ ] git リポジトリ外で実行した場合、明確なエラーメッセージが表示される
- [ ] worktree が1つしかない場合、明確なエラーメッセージが表示される
- [ ] fzf をキャンセルした場合、クリーンに終了する
- [ ] `chezmoi apply` で `~/.local/bin/gtr-copy` に実行権限付きで配置される
- [ ] サブディレクトリから実行しても、worktree root からの相対パスで正しくコピーされる

## Dependencies & Risks

- `fzf` が Brewfile で管理済み
- `bat` はオプショナル（なければ `cat` にフォールバック）
- `~/.local/bin` が `$PATH` に含まれている前提（`path.zsh` で設定済み）
- **リスク**: `gtr copy`（gtr 組み込みサブコマンド）と名前が類似 — 用途が異なる（`gtr copy` は `.gitconfig` で定義済みファイルの自動コピー、`gtr-copy` はインタラクティブな ad-hoc コピー）

## MVP

### dot_local/bin/executable_gtr-copy

```bash
#!/usr/bin/env bash
set -euo pipefail

# --- Guards ---
if ! command -v fzf &>/dev/null; then
    echo "gtr-copy: fzf is required but not installed" >&2
    exit 1
fi

worktree_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "gtr-copy: not inside a git repository" >&2
    exit 1
}

cd "$worktree_root"

# --- Destination worktree list ---
destinations=$(git worktree list | grep -v "^${worktree_root} " | grep -v "(bare)")

if [[ -z "$destinations" ]]; then
    echo "gtr-copy: no other worktrees found" >&2
    exit 1
fi

# --- File selection (fzf --multi with preview) ---
selected_files=$(
    { git ls-files; git ls-files --others --exclude-standard; } \
    | sort -u \
    | fzf --multi --preview 'bat --color=always {} 2>/dev/null || cat {}'
) || exit 0  # user cancelled

if [[ -z "$selected_files" ]]; then
    exit 0
fi

# --- Destination selection ---
dest_line=$(echo "$destinations" | fzf) || exit 0  # user cancelled
dest_worktree=$(echo "$dest_line" | awk '{print $1}')

# --- Copy with structure preservation ---
errors=()
copied=0

while IFS= read -r file; do
    dest_path="${dest_worktree}/${file}"
    if mkdir -p "$(dirname "$dest_path")" && cp "$file" "$dest_path"; then
        ((copied++))
    else
        errors+=("$file")
    fi
done <<< "$selected_files"

echo "gtr-copy: copied ${copied} file(s) to ${dest_worktree}"

if [[ ${#errors[@]} -gt 0 ]]; then
    echo "gtr-copy: failed to copy:" >&2
    printf '  %s\n' "${errors[@]}" >&2
    exit 1
fi
```

## Sources

- **Origin document:** [docs/brainstorms/2026-03-19-gtr-copy-requirements.md](../brainstorms/2026-03-19-gtr-copy-requirements.md) — Key decisions: chezmoi管理スクリプト、fzfファイル選択、全worktreeをコピー先対象
- **chezmoi executable pattern:** `dot_claude/scripts/executable_statusline-wrapper.sh` (既存の executable_ prefix パターン)
- **fzf usage pattern:** `dot_gitconfig.tmpl` の `git sw` alias（fzf をリスト選択に使用する既存パターン）
- **gtr copy config:** `dot_gitconfig.tmpl` 内 `[gtr "copy"]` セクション（組み込みサブコマンドとの関係）
