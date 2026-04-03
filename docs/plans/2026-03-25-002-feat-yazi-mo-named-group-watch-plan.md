---
title: "feat(yazi): enhance mo preview with named groups, directory support, and --watch"
type: feat
status: completed
date: 2026-03-25
origin: https://github.com/tanimon/dotfiles/pull/50
---

# feat(yazi): enhance mo preview with named groups, directory support, and --watch

## Overview

PR #50 で導入された yazi の `<C-p>` → `mo` によるMarkdownプレビューを拡張する。現在は単一ファイルを default グループで開くのみだが、named group での分離表示、ディレクトリ配下の一括プレビュー、`--watch` による新規ファイル自動検出を追加する。

## Problem Frame

現状の `mo %h` は単一ファイルをブラウザプレビューするだけ。複数のMarkdownを扱うワークフローでは以下が不足:
1. 毎回 default グループに追加されるため、異なるコンテキストのファイルが混在する
2. ディレクトリを選択しても何も起きない（`mo` にディレクトリを渡してもエラー）
3. ディレクトリ内に新しいMarkdownが追加されても自動でプレビュー対象にならない

## Requirements Trace

- R1. `<C-p>` でファイルを開く際、新しい named group を作成してそこで開く
- R2. ディレクトリ上で `<C-p>` を押した場合、配下のすべての `*.md` ファイルを開く
- R3. `--watch` フラグを指定し、新規ファイル追加時に自動でプレビュー対象に含める

## Scope Boundaries

- yazi の `keymap.toml` のみ変更（新規ファイル作成なし）
- mo サーバーのポートやバインドアドレスの変更は対象外
- yazi プラグイン（Lua）の作成は行わない — シェルコマンドで完結させる

## Context & Research

### Relevant Code and Patterns

- `dot_config/yazi/keymap.toml` — 現在の `<C-p>` キーバインド定義（唯一の管理対象ファイル）
- yazi shell command syntax: `shell --block -- <command>` でブロッキング実行、`%h` でカーソル下のパス展開

### mo CLI の主要フラグ

| フラグ | 説明 |
|--------|------|
| `--target` / `-t` | Tab group 名（デフォルト: `"default"`） |
| `--watch` / `-w` | glob パターンでファイル監視（ファイル引数と併用不可、繰り返し指定可） |
| `--close` | セッションからファイルを除去 |

重要な制約: `--watch` はファイル引数と**併用不可**。glob パターンのみで動作する。

### Institutional Learnings

該当なし（yazi 関連の過去ソリューションは未記録）。

## Key Technical Decisions

- **Named group 名にディレクトリ名を使用**: ファイルの場合は親ディレクトリ名、ディレクトリの場合はそのディレクトリ名を `--target` に渡す。これにより同じディレクトリのファイルが自然にグループ化される
- **ファイル vs ディレクトリの分岐はインライン shell で実現**: yazi プラグイン（Lua）ではなく、`sh -c` のワンライナーで条件分岐する。keymap.toml 内で完結し、外部スクリプトファイルを増やさない
- **ディレクトリの場合は `--watch` を使用**: ディレクトリ選択時は `mo -w '<dir>/**/*.md' -t <group>` で起動。新規ファイルの自動検出要件（R3）を満たす
- **ファイルの場合も `--watch` を使用**: 単一ファイルの場合も `mo -w '<dir>/**/*.md' -t <group>` とし、同ディレクトリの他 Markdown も監視対象にする。これにより R3 を一貫して満たし、ファイル/ディレクトリで異なる挙動にならない
- **`--block` を維持**: `shell --block` により mo のフォアグラウンド実行を維持。Ctrl-C で yazi に戻れる

## Open Questions

### Resolved During Planning

- **Q: ファイル選択時とディレクトリ選択時で `--watch` の挙動を分けるべきか？**
  → 分けない。どちらの場合も `--watch` で同ディレクトリの `**/*.md` を監視する。一貫性があり実装もシンプル。

### Deferred to Implementation

- **Q: group 名に使うディレクトリ名にスペースや特殊文字が含まれる場合の挙動**
  → 実際の利用パターンで問題が出れば対処する。

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification.*

```
<C-p> pressed on item (file or directory)
  │
  ├─ item is a file?
  │    dir = parent directory of file
  │
  └─ item is a directory?
       dir = the directory itself
  │
  ▼
  group_name = basename(dir)
  mo --watch '<dir>/**/*.md' --target <group_name> --foreground
```

`--foreground` を使い、`shell --block` と組み合わせて yazi のターミナルを mo が占有。Ctrl-C で終了して yazi に戻る。

## Implementation Units

- [x] **Unit 1: keymap.toml の `<C-p>` コマンドを拡張**

**Goal:** ファイル/ディレクトリ判定 → named group + `--watch` で mo を起動

**Requirements:** R1, R2, R3

**Dependencies:** なし

**Files:**
- Modify: `dot_config/yazi/keymap.toml`

**Approach:**
- `run` フィールドのシェルコマンドを `sh -c` ワンライナーに置き換え
- `-d` テストでディレクトリ判定、ファイルの場合は `dirname` で親を取得
- `basename` でグループ名を生成
- `mo -w "$dir/**/*.md" -t "$group" --foreground` で起動
- `desc` をファイル/ディレクトリ両対応の説明に更新

**Patterns to follow:**
- yazi keymap の `shell --block -- sh -c '...'` パターン（公式ドキュメントのカスタムコマンド例）

**Test scenarios:**
- 単一 `.md` ファイル上で `<C-p>` → 親ディレクトリ名の group で mo が起動、同ディレクトリの *.md が表示される
- ディレクトリ上で `<C-p>` → そのディレクトリ名の group で mo が起動、配下の *.md が表示される
- 新しい `.md` ファイルをディレクトリに追加 → `--watch` により自動的にプレビューに追加される
- `.md` 以外のファイル上で `<C-p>` → mo は起動するが該当 glob にマッチするファイルのみ表示

**Verification:**
- `chezmoi diff` で keymap.toml の変更を確認
- `chezmoi apply` 後、yazi でファイルとディレクトリそれぞれに `<C-p>` を実行し、ブラウザで named group が正しく表示されること

## System-Wide Impact

- **Interaction graph:** yazi keymap → shell → mo CLI。他のキーバインドや設定に影響なし
- **Error propagation:** mo が見つからない場合はシェルエラーが yazi に表示される（既存挙動と同じ）
- **State lifecycle risks:** mo はセッションを自動保存する。異なるグループが蓄積する可能性があるが、`mo --clear` で解消可能
- **API surface parity:** なし
- **Integration coverage:** 手動テストのみ（yazi + mo のインタラクション）

## Risks & Dependencies

- `mo` の `--watch` と `--foreground` の組み合わせが期待通り動作するか実装時に検証が必要
- yazi の `shell --block` 内でのシェル変数展開（`%h` と `$variable` の共存）に注意

## Sources & References

- **Origin PR:** https://github.com/tanimon/dotfiles/pull/50
- **mo CLI:** `mo --help` (v0.21.0) — `--target`, `--watch`, `--foreground` フラグ
- **Related code:** `dot_config/yazi/keymap.toml`
