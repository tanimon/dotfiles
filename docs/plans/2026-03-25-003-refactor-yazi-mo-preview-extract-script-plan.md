---
title: "refactor(yazi): extract mo preview shell logic to standalone script"
type: refactor
status: active
date: 2026-03-25
origin: P3 finding from ce:review of PR #51
---

# refactor(yazi): extract mo preview shell logic to standalone script

## Overview

keymap.toml のインラインシェルコマンド（156文字、14個の `\"` エスケープ）を外部スクリプトに抽出し、保守性を改善する。

## Requirements Trace

- R1. keymap.toml の `run` フィールドをスクリプト呼び出しに簡素化
- R2. 既存の機能（named group, --watch, --foreground, ファイル/ディレクトリ判定）を維持
- R3. chezmoi で管理し、`chezmoi apply` で正しく配置される

## Scope Boundaries

- 機能変更なし（純粋なリファクタリング）
- スクリプトは POSIX sh 互換（bash 依存なし）

## Key Technical Decisions

- **スクリプトパス**: `dot_config/yazi/scripts/mo-preview.sh` → `~/.config/yazi/scripts/mo-preview.sh`
- **chezmoi プレフィックス**: `executable_` を使い実行権限を付与
- **keymap.toml はテンプレート不要**: スクリプトパスは `~/.config/yazi/scripts/mo-preview.sh` で固定（homeDir 依存なし）

## Implementation Units

- [ ] **Unit 1: mo-preview.sh スクリプト作成**

**Files:**
- Create: `dot_config/yazi/scripts/executable_mo-preview.sh`

- [ ] **Unit 2: keymap.toml のコマンドをスクリプト呼び出しに置換**

**Files:**
- Modify: `dot_config/yazi/keymap.toml`
