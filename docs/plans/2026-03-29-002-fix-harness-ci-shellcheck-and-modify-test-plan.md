---
title: "fix: Align CI shellcheck with pre-commit and add modify_ script smoke test"
type: fix
status: completed
date: 2026-03-29
---

# fix: Align CI shellcheck with pre-commit and add modify_ script smoke test

## Overview

harness-health 診断 (88/100) で特定された2つのギャップを修正する: (1) CI の shellcheck/shfmt がpre-commit と対象ファイルが不一致、(2) `modify_` スクリプトのスモークテストが CI にない。

## Problem Frame

CI の `find` コマンドが `*.sh` と `*.bash` のみを対象にしており、`executable_` プレフィックスの拡張子なしシェルスクリプト（`executable_git-clean-squashed`, `executable_gtr-copy`）を見逃している。pre-commit はこれらを正しく検出するため、CI と pre-commit でリント対象に差異がある。

また、`modify_dot_claude.json` はCIで一切テストされておらず、スクリプトの不具合で `~/.claude.json` が破壊されるリスクがある。

## Requirements Trace

- R1. CI の shellcheck/shfmt が pre-commit と同じファイルパターンを対象とする
- R2. `modify_dot_claude.json` の基本動作を CI でスモークテストする

## Scope Boundaries

- Known Pitfalls の構造化は対象外（影響が小さく、現状15件は許容範囲）
- pre-commit の設定変更は不要（既に正しい）
- 新しいツールやフレームワークの導入はしない

## Context & Research

### Relevant Code and Patterns

- `.github/workflows/lint.yml` — 現在の CI: `find . -type f \( -name '*.sh' -o -name '*.bash' \)` で拡張子ベースのみ
- `.pre-commit-config.yaml` — `files: '(\.sh$|\.bash$|\.chezmoiscripts/|executable_)'` で `executable_` も対象
- `modify_dot_claude.json` — `jq` で `mcpServers` キーのみ置換する modify_ スクリプト
- `dot_claude/mcp-servers.json` — modify_ スクリプトの入力データ
- `dot_local/bin/executable_git-clean-squashed` — 拡張子なし bash スクリプト（CI で未検査）
- `dot_local/bin/executable_gtr-copy` — 同上

### Institutional Learnings

- `docs/solutions/integration-issues/chezmoi-tmpl-shellcheck-shfmt-incompatibility.md` — `.tmpl` は shell lint 非互換（除外必須）

## Key Technical Decisions

- **CI の `find` を pre-commit と同等にする**: `-name 'executable_*'` を追加し、`.tmpl` と `.mts`/`.ts`/`.mjs` を除外。pre-commit の `files` regex と同等のカバレッジを実現
- **modify_ のスモークテストは独立ジョブにする**: 既存の lint ジョブとは性質が異なる（構文チェックではなく動作検証）
- **スモークテストは最小限**: サンプル JSON を stdin で渡し、出力が有効な JSON であること、`mcpServers` キーが置換されていることのみ検証

## Open Questions

### Resolved During Planning

- **Q: CI で `executable_` ファイルをどう検出するか** → `find` に `-name 'executable_*'` を追加。ただし `.mts` 等のスクリプトは除外
- **Q: modify_ テストに chezmoi は必要か** → 不要。`modify_dot_claude.json` は純粋なシェルスクリプトで、stdin/stdout で動作。`CHEZMOI_SOURCE_DIR` 環境変数を設定すれば単体テスト可能

### Deferred to Implementation

- なし

## Implementation Units

- [ ] **Unit 1: CI shellcheck/shfmt の対象ファイルパターンを pre-commit と統一**

  **Goal:** CI の shellcheck/shfmt が `executable_` プレフィックスのシェルスクリプトも検査するようにする

  **Requirements:** R1

  **Dependencies:** なし

  **Files:**
  - Modify: `.github/workflows/lint.yml`

  **Approach:**
  - shellcheck ジョブの `find` コマンドに `-o -name 'executable_*'` を追加
  - shfmt ジョブも同様に更新
  - `.tmpl`, `.mts`, `.ts`, `.mjs` ファイルは引き続き除外（`! -name '*.tmpl' ! -name '*.mts' ! -name '*.ts' ! -name '*.mjs'`）
  - `node_modules` は引き続き除外

  **Patterns to follow:**
  - `.pre-commit-config.yaml` のファイルパターン: `files: '(\.sh$|\.bash$|\.chezmoiscripts/|executable_)'`

  **Test scenarios:**
  - Happy path: `executable_git-clean-squashed` と `executable_gtr-copy` が shellcheck/shfmt の対象になる
  - Happy path: 既存の `.sh` ファイルが引き続き対象
  - Edge case: `executable_notify.mts`（TypeScript）が除外される
  - Edge case: `.tmpl` ファイルが除外される

  **Verification:**
  - CI ワークフローの `find` コマンドが `executable_*` を含む
  - ローカルで同じ `find` コマンドを実行し、期待するファイルが列挙される

- [ ] **Unit 2: modify_ スクリプトのスモークテストを CI に追加**

  **Goal:** `modify_dot_claude.json` の基本動作を CI で検証

  **Requirements:** R2

  **Dependencies:** なし

  **Files:**
  - Modify: `.github/workflows/lint.yml`

  **Approach:**
  - `modify-scripts` ジョブを追加
  - サンプル JSON (`{"existingKey": "value", "mcpServers": {}}`) を stdin で渡す
  - `CHEZMOI_SOURCE_DIR` を `$(pwd)` に設定
  - 出力が有効な JSON であることを `jq empty` で検証
  - 出力の `mcpServers` が `dot_claude/mcp-servers.json` の内容と一致することを `jq` で検証
  - 出力の `existingKey` が保持されていることを検証（非破壊性の確認）
  - 空 stdin（新規マシン）のケースもテスト: 出力が有効な JSON であること

  **Patterns to follow:**
  - 既存の chezmoi-templates ジョブの構造（ubuntu-latest, actions/checkout@v4）

  **Test scenarios:**
  - Happy path: 既存 JSON + mcpServers → 出力に mcpServers が置換され、他のキーが保持される
  - Happy path: 空 stdin → 有効な JSON が出力される（`{}` + mcpServers）
  - Error path: `jq` が未インストールの場合、stdin がそのまま出力される（スクリプトの guard 動作）

  **Verification:**
  - CI ジョブが正常に通過する
  - 各テストケースの期待出力が検証される

## System-Wide Impact

- **CI パイプライン**: 2つの変更: (1) shellcheck/shfmt の対象ファイル拡大、(2) modify-scripts ジョブ追加。ビルド時間への影響は最小（数秒）
- **既存ジョブ**: secretlint, chezmoi-templates ジョブは変更なし
- **Unchanged invariants**: pre-commit の設定、CLAUDE.md、`.claude/rules/` は変更なし

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| `executable_` ファイルに既存の shellcheck 警告がある | 事前にローカルで `shellcheck` を実行して修正 |
| `jq` が CI ランナーに未インストール | Ubuntu ランナーには標準搭載 |

## Sources & References

- harness-health レポート (this session, score 88/100)
- 既存 CI: `.github/workflows/lint.yml`
- 既存 pre-commit: `.pre-commit-config.yaml`
- modify_ スクリプト: `modify_dot_claude.json`
