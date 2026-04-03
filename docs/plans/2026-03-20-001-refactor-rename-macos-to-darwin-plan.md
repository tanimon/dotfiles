---
title: "refactor: rename macOs/ directory to darwin/"
type: refactor
status: completed
date: 2026-03-20
---

# refactor: rename macOs/ directory to darwin/

## Overview

`macOs/` ディレクトリを `darwin/` にリネームし、すべての参照を更新する。chezmoi の `.chezmoi.os` 値（`"darwin"`）、既存スクリプト命名規則（`darwin-install-packages`）、兄弟ディレクトリ `windows/` との一貫性を確保する。

## Problem Statement / Motivation

現在の `macOs/` は以下の点で不整合:
- chezmoi の OS 識別子は `"darwin"`（`.chezmoi.os` の値）
- 既存の `run_onchange_` スクリプトは `darwin-` プレフィックスを使用
- 兄弟ディレクトリ `windows/` は OS 名をそのまま使用
- `macOs` は macOS の正式表記でもない（正式は `macOS`）

`darwin/` にリネームすることで命名規則が統一される。

## Proposed Solution

ディレクトリリネーム + 参照更新の4箇所を1コミットで実施。

## Changes

### 1. ディレクトリリネーム

```bash
git mv macOs darwin
```

`macOs/` 内の3ファイルはそのまま移動:
- `Brewfile`
- `defaults.sh`
- `DefaultKeyBinding.dict`

### 2. `.chezmoiignore` (line 5)

```diff
-macOs/
+darwin/
```

**理由:** このエントリがないと `chezmoi apply` が `darwin/` 内のファイルを `~/darwin/` にデプロイしてしまう。

### 3. `.chezmoiscripts/run_onchange_darwin-install-packages.sh.tmpl` (lines 5, 7)

```diff
-# brewfile hash: {{ include "macOs/Brewfile" | sha256sum }}
+# brewfile hash: {{ include "darwin/Brewfile" | sha256sum }}
```

```diff
-brew bundle install --file={{ joinPath .chezmoi.sourceDir "macOs/Brewfile" | quote }}
+brew bundle install --file={{ joinPath .chezmoi.sourceDir "darwin/Brewfile" | quote }}
```

### 4. `CLAUDE.md` (line 54)

```diff
-# brewfile hash: {{ include "macOs/Brewfile" | sha256sum }}
+# brewfile hash: {{ include "darwin/Brewfile" | sha256sum }}
```

ドキュメント例が実際のコードと一致するように更新。

## Acceptance Criteria

- [ ] `macOs/` ディレクトリが存在しないこと
- [ ] `darwin/` ディレクトリに Brewfile, defaults.sh, DefaultKeyBinding.dict が存在すること
- [ ] `grep -r "macOs/" .` でディレクトリパス参照がヒットしないこと（prose の "macOS" は除く）
- [ ] `chezmoi apply --dry-run` で `darwin/` 配下のファイルがデプロイ対象にならないこと

## Side Effects

- `run_onchange_` スクリプトのレンダリング結果が変わるため、次回 `chezmoi apply` 時に `brew bundle install` が1回再実行される。`brew bundle install` は冪等なので問題なし。

## Dependencies & Risks

- **リスク:** なし。変更は repo-only ディレクトリのリネームで、ランタイム影響は `brew bundle` の冪等な再実行のみ。
- **依存:** なし。外部サービスや他ブランチへの影響なし。

## Sources & References

- `.chezmoiignore` — chezmoi ignore 設定
- `.chezmoiscripts/run_onchange_darwin-install-packages.sh.tmpl` — Brewfile インストールスクリプト
- `CLAUDE.md` — プロジェクトドキュメント
