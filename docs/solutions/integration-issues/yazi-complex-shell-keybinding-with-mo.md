---
title: "yazi keymap で複雑なシェルコマンドを埋め込むパターン (mo + --watch + --target)"
category: integration-issues
date: 2026-03-25
tags:
  - yazi
  - mo
  - keymap
  - toml-escaping
  - shell
modules:
  - dot_config/yazi/keymap.toml
---

# yazi keymap で複雑なシェルコマンドを埋め込むパターン

## Problem

yazi の `keymap.toml` で `<C-p>` キーバインドに複雑なシェルロジック（条件分岐、変数、複数コマンド）を埋め込みたいが、TOML 文字列内でのクォーティングが厄介。

## Root Cause

yazi の `run` フィールドは TOML 文字列で、`%h` などの変数を yazi が展開した後にシェルに渡す。単純な `mo %h` なら問題ないが、条件分岐やパイプラインを含むコマンドでは TOML エスケープとシェルクォーティングが衝突する。

## Solution

`sh -c '...' _ %h` パターンを使い、yazi の `%h` をシェルの位置パラメータ `$1` として受け取る:

```toml
run = "shell --block -- sh -c 'd=\"$1\"; [ -f \"$d\" ] && d=$(dirname \"$d\"); g=\"$(basename \"$(dirname \"$d\")\")-$(basename \"$d\")\"; mo -w \"$d/**/*.md\" -t \"$g\" --foreground' _ %h"
```

### エスケープルール

| 文字 | TOML basic string 内での記法 | シェルに渡る値 |
|------|------|------|
| `"` | `\"` | `"` |
| `'` | `'` (エスケープ不要) | `'` |
| `$` | `$` (TOML はそのまま) | `$` (sh -c 内は single quote で保護) |

### mo CLI フラグの組み合わせ

- `--watch` (`-w`): glob パターンでファイル監視。**ファイル引数と併用不可**
- `--target` (`-t`): named group。同じグループ名のファイルがブラウザの同一タブグループに表示
- `--foreground`: サーバーをフォアグラウンドで実行。`shell --block` と組み合わせて Ctrl-C で yazi に戻れる

### ファイル/ディレクトリ判定の簡潔なパターン

```sh
# if/else より簡潔
d="$1"; [ -f "$d" ] && d=$(dirname "$d"); g=$(basename "$d")
# デフォルトはディレクトリとして扱い、ファイルの場合のみ dirname で上書き
```

### named group の衝突回避

`basename` だけでは同名ディレクトリ（例: `project-a/docs` と `project-b/docs`）でグループ名が衝突する。親ディレクトリ名を含めて一意にする:

```sh
# basename のみ → 衝突する
g=$(basename "$d")  # 両方 "docs"

# parent-basename → 衝突しない
g="$(basename "$(dirname "$d")")-$(basename "$d")"  # "project-a-docs" vs "project-b-docs"
```

TOML 内でのネストした `$()` のエスケープ:

```toml
g=\"$(basename \"$(dirname \"$d\")\")-$(basename \"$d\")\"
```

`$()` はシェルの新しいクォーティングコンテキストを作るため、ネストしたダブルクォートが外側と干渉しない。

## Prevention

- yazi keymap で複数コマンドが必要な場合は `sh -c '...' _ %h` パターンを使う
- TOML basic string (`"..."`) 内ではダブルクォートのみエスケープ (`\"`)、シングルクォートはそのまま
- 外部スクリプトファイルに分離するのは、ロジックが 100 文字を大幅に超える場合のみ検討
