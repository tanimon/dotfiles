---
title: "feat: Add update-brewfile.sh script"
type: feat
status: completed
date: 2026-03-20
---

# feat: Add update-brewfile.sh script

`scripts/update-brewfile.sh` を作成し、現在のマシンにインストールされている Homebrew パッケージから `darwin/Brewfile` を再生成する。

## Problem Statement

リポジトリの3部構成の宣言的同期パターン（テキストリスト → capture スクリプト → apply スクリプト）において、Brewfile だけ capture スクリプトが欠落している。

| コンポーネント | gh extensions | marketplaces | **Brewfile** |
|---|---|---|---|
| 宣言リスト | `dot_config/gh/extensions.txt` | `dot_claude/plugins/marketplaces.txt` | `darwin/Brewfile` ✅ |
| capture スクリプト | `scripts/update-gh-extensions.sh` | `scripts/update-marketplaces.sh` | **なし** ❌ |
| apply スクリプト | `run_onchange_after_install-gh-extensions.sh.tmpl` | `run_onchange_after_add-marketplaces.sh.tmpl` | `run_onchange_darwin-install-packages.sh.tmpl` ✅ |

## Proposed Solution

`scripts/update-brewfile.sh` を既存スクリプトと同一パターンで作成する。

### 実装

```bash
# scripts/update-brewfile.sh
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="${REPO_ROOT}/darwin/Brewfile"

# brew CLI 存在チェック
if ! command -v brew &>/dev/null; then
  echo "error: brew not found" >&2
  exit 1
fi

# 現在インストール済みパッケージから Brewfile を再生成
brew bundle dump --force --file="$TARGET"

echo "Updated ${TARGET} ($(wc -l < "$TARGET" | tr -d ' ') entries)"
```

### 設計判断

1. **`brew bundle dump --force`**: `--force` で既存ファイルを上書き。`--file` で出力先を直接指定
2. **ソートは不要**: `brew bundle dump` はカテゴリ別（tap → brew → cask → mas）にソート済みで出力する
3. **パイプ不要**: 他のスクリプトと違い、`brew bundle dump` はファイルに直接書き出すため、stdout パイプ + リダイレクトは不要
4. **`scripts/` は `.chezmoiignore` で除外済み**: デプロイ対象外、追加設定不要

## Acceptance Criteria

- [ ] `scripts/update-brewfile.sh` が既存スクリプトと同一パターンで作成されている
- [ ] `brew bundle dump --force --file=<target>` で `darwin/Brewfile` を再生成する
- [ ] `brew` コマンドの存在チェックがある
- [ ] 実行権限 (`chmod +x`) が付与されている
- [ ] 実行後に更新件数を表示する

## Sources

- `scripts/update-gh-extensions.sh` — 参考スクリプト（gh extensions capture）
- `scripts/update-marketplaces.sh` — 参考スクリプト（marketplaces capture）
- `docs/solutions/integration-issues/chezmoi-declarative-marketplace-sync-over-bidirectional.md` — 宣言的同期パターンの解説
