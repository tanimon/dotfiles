---
title: "feat: yazi の Markdown Previewer に mo を利用する"
type: feat
status: completed
date: 2026-03-25
---

# feat: yazi の Markdown Previewer に mo を利用する

GitHub Issue: [#49](https://github.com/tanimon/dotfiles/issues/49)

yazi のブラウザベース Markdown プレビューを `gh markdown-preview` から [k1LoW/mo](https://github.com/k1LoW/mo) に置き換える。

## 現状

| 機能 | ツール | 方式 |
|------|--------|------|
| プレビューペイン（ターミナル内） | `glow` via `glow.yazi` plugin | ターミナルレンダリング |
| ブラウザプレビュー（`<C-p>`） | `gh markdown-preview` | ブラウザ |
| opener（markdown） | `glow` | ターミナル |

- `keymap.toml` のみ chezmoi 管理。`yazi.toml` と plugins は未管理
- `gh-markdown-preview` は `dot_config/gh/extensions.txt` で宣言的管理

## 変更方針

`mo` はブラウザベースの Markdown ビューアのため、ターミナル内プレビューペイン（`glow.yazi`）はそのまま維持し、ブラウザプレビュー機能のみ置き換える。

### 1. `mo` のインストール

- Brewfile に `tap "k1LoW/tap"` と `brew "k1LoW/tap/mo"` を追加

### 2. yazi keymap の更新

- `dot_config/yazi/keymap.toml` の `<C-p>` を `gh markdown-preview` → `mo` に変更
  - 現在: `shell --block -- gh markdown-preview %h`
  - 変更後: `shell --block -- mo %h`

### 3. `gh-markdown-preview` 拡張の削除

- `dot_config/gh/extensions.txt` から `yusukebe/gh-markdown-preview` を削除（mo で代替）

## Acceptance Criteria

- [ ] `brew install` で `mo` がインストールされること
- [ ] yazi で `<C-p>` 押下時に `mo` でブラウザプレビューが開くこと
- [ ] `gh-markdown-preview` 拡張が extensions.txt から削除されていること
- [ ] ターミナル内プレビューペイン（glow）は変更なし

## Sources

- [k1LoW/mo](https://github.com/k1LoW/mo) — Markdown viewer (browser-based, v0.21.0)
- インストール: `brew install k1LoW/tap/mo`
- 現在の keymap: `dot_config/yazi/keymap.toml:1-4`
- 現在の Brewfile: `darwin/Brewfile`
- gh extensions: `dot_config/gh/extensions.txt`
