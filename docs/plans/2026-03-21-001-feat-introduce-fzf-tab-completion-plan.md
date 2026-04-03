---
title: "feat: Introduce fzf-tab for zsh completion"
type: feat
status: completed
date: 2026-03-21
---

# feat: Introduce fzf-tab for zsh completion

## Overview

[fzf-tab](https://github.com/Aloxaf/fzf-tab) を sheldon 経由で導入し、zsh の補完 UI を fzf ベースに置き換える。現在の `menu select` スタイルの補完を、fuzzy 検索・プレビュー付きの fzf-tab に統一する。

## Problem Statement / Motivation

現在の zsh 補完は組み込みの `menu select` を使用しており、候補が多い場合の検索性が低い。fzf-tab を導入することで:

- 補完候補の fuzzy 検索が可能になる
- ファイル補完時にプレビューを表示できる
- 既存の fzf キーバインド (`Ctrl-R`, `Ctrl-T`, `Alt-C`) との操作感を統一できる

## Proposed Solution

### 変更ファイル一覧

1. **`dot_config/sheldon/plugins.toml`** — fzf-tab プラグインを追加
2. **`dot_zshrc`** — `menu select` を削除、fzf-tab 用 zstyle 設定を追加

### 実装詳細

#### 1. sheldon plugins.toml にエントリ追加

fzf-tab は `compinit` の後、かつ zsh-autosuggestions の**前**にロードする必要がある。sheldon はファイル内の定義順でプラグインをロードするため、`zsh-completions` と `zsh-autosuggestions` の間に配置する。

```toml
[plugins.zsh-completions]
github = "zsh-users/zsh-completions"

[plugins.fzf-tab]
github = "Aloxaf/fzf-tab"

[plugins.zsh-autosuggestions]
github = "zsh-users/zsh-autosuggestions"
use = ["{{ name }}.zsh"]
```

#### 2. dot_zshrc の修正

**削除:**
```diff
- zstyle ':completion:*' menu select
```

`menu select` は fzf-tab と競合する。fzf-tab は独自の補完 UI を提供するため不要。

**追加（任意）:**
```zsh
# fzf-tab: disable sort when completing `git checkout`
zstyle ':completion:*:git-checkout:*' sort false
# fzf-tab: preview for directory completion
zstyle ':fzf-tab:complete:cd:*' fzf-preview 'eza -1 --color=always $realpath'
# fzf-tab: switch group using `<` and `>`
zstyle ':fzf-tab:*' switch-group '<' '>'
```

## Technical Considerations

### プラグインロード順序

fzf-tab の README が明示する要件:
1. `compinit` の後にロードすること
2. zsh-autosuggestions, zsh-syntax-highlighting 等のラッパープラグインの**前**にロードすること

現在の `dot_zshrc` のロード順:
1. L24-25: `compinit` (zshrc 内)
2. L61: `carapace` (補完ソース追加)
3. L62: `fzf --zsh` (キーバインドのみ)
4. L64: `sheldon source` (プラグインロード) ← fzf-tab はここでロードされる

`compinit` が `sheldon source` より前にあるため、要件を満たしている。

### carapace との共存

carapace は補完定義を追加するだけなので、fzf-tab の UI レイヤーとは独立。共存に問題なし。

### `fzf --zsh` との共存

`fzf --zsh` は `Ctrl-R` (history), `Ctrl-T` (file), `Alt-C` (cd) のキーバインドを設定するだけ。fzf-tab は Tab 補完を担当するため、機能は重複しない。

### 既存 zstyle の互換性

- `matcher-list` — fzf-tab でも有効。fzf-tab は zsh の補完システムの上に構築されているため、マッチングルールはそのまま適用される
- `format` — fzf-tab のグループヘッダーとして表示される
- `group-order` (git) — fzf-tab でもグループ順序として反映される

## Acceptance Criteria

- [ ] `dot_config/sheldon/plugins.toml` に fzf-tab エントリが追加されている
- [ ] fzf-tab が zsh-autosuggestions より前に定義されている
- [ ] `dot_zshrc` から `zstyle ':completion:*' menu select` が削除されている
- [ ] `chezmoi apply --dry-run` でエラーがないこと
- [ ] sheldon lock & source が正常に動作すること

## Dependencies & Risks

- **依存**: fzf がインストール済みであること（Brewfile に含まれている）
- **リスク（低）**: sheldon の初回 lock 時にネットワークアクセスが必要
- **リスク（低）**: fzf-tab のカスタム zstyle が他の補完設定と干渉する可能性 → 最小限の設定から開始

## MVP

### `dot_config/sheldon/plugins.toml`

```toml
[plugins.fzf-tab]
github = "Aloxaf/fzf-tab"
```

（zsh-completions と zsh-autosuggestions の間に配置）

### `dot_zshrc`

`menu select` 行を削除。

## Sources

- fzf-tab: https://github.com/Aloxaf/fzf-tab
- sheldon: https://github.com/rossmacarthur/sheldon
- 既存設定: `dot_config/sheldon/plugins.toml`, `dot_zshrc`
