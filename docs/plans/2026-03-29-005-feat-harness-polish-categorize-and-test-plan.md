---
title: "feat: Polish harness with pitfall categorization, hook test, and rule promotion"
type: feat
status: completed
date: 2026-03-29
---

# feat: Polish harness with pitfall categorization, hook test, and rule promotion

## Overview

ハーネスヘルス 88/100 から 95+ を目指す。3つの改善: (1) Known Pitfalls をカテゴリ化して可読性向上、(2) harness-activator.sh のスモークテスト追加、(3) hook スクリプトのガイダンスを `.claude/rules/shell-scripts.md` に昇格。

## Problem Frame

ハーネスヘルス診断で残存する改善余地:
- Known Pitfalls が14項目のフラットリストで、エージェントが優先順位付けしにくい
- `dot_claude/scripts/executable_harness-activator.sh` は純粋な bash だが CI テストがない
- hook スクリプトの exit code 契約や session_id パターンが `docs/solutions/` にのみ記録されており、`.claude/rules/` に昇格されていない

## Requirements Trace

- R1. CLAUDE.md Known Pitfalls をカテゴリ別にサブヘッダーで整理する
- R2. harness-activator.sh のスモークテストを `make test-scripts` ターゲットとして追加する
- R3. hook スクリプトのガイダンス（exit code 契約、session_id パターン）を `.claude/rules/shell-scripts.md` に追加する

## Scope Boundaries

- CLAUDE.md の Known Pitfalls の内容自体は変更しない（構造の再編のみ）
- `run_onchange_` スクリプトのテストは対象外（.tmpl のため直接テスト困難）
- 新しい lint ツールの導入はしない
- グローバルルール (`~/.claude/rules/`) は変更しない

## Context & Research

### Relevant Code and Patterns

- `Makefile` の `test-modify` ターゲット: stdin パイプ → bash 実行 → jq/条件検証パターン
- `dot_claude/scripts/executable_harness-activator.sh`: stdin で JSON を受け取り、session_id 抽出、コンテキストガード、stdout メッセージ出力
- `.claude/rules/shell-scripts.md`: スクリプトヘッダー、run_onchange_、テンプレート、非テンプレート、CI 強制、再帰回避の6セクション

### Institutional Learnings

- `docs/solutions/developer-experience/autonomous-harness-engineering-hooks-2026-03-28.md`: session_id は `jq -r '.session_id // empty'` で取得。`$PPID`/`$$` は `bash -c` ラッパーで不安定
- `docs/solutions/integration-issues/claude-code-hook-exit-code-and-stderr-semantics.md`: `exit(0)` = skip、`exit(1)` + stderr = error。stderr なし exit(1) は混乱を招く

## Key Technical Decisions

- **Known Pitfalls のカテゴリ数を4-5に**: chezmoi CLI、テンプレート構文、スクリプト安全性、ファイル管理、外部制約。過剰な細分化は避ける
- **`test-scripts` を `test-modify` と別ターゲットに**: modify_ テストと hook テストは異なる前提条件を持つため分離。`make lint` に統合
- **harness-activator.sh テストは git リポジトリ内で実行**: スクリプトが `git rev-parse` を呼ぶため、テスト時は実際のリポジトリ内から実行する

## Open Questions

### Resolved During Planning

- **harness-activator.sh の stdin JSON はどう構成?**: `{"session_id": "uuid-here", ...}` 形式。テストでは最小限の JSON をパイプする
- **テストで `/tmp` フラグファイルが残る問題は?**: テスト前後で cleanup する。テスト用に一意の session_id を生成

### Deferred to Implementation

- **harness-activator.sh の出力メッセージの正確な検証範囲**: 出力が空でないことの確認で十分か、特定文字列の grep が必要かは実装時に判断

## Implementation Units

- [ ] **Unit 1: Known Pitfalls カテゴリ化**

**Goal:** CLAUDE.md の Known Pitfalls をカテゴリ別サブヘッダーで整理し、エージェントの可読性を向上させる

**Requirements:** R1

**Dependencies:** なし

**Files:**
- Modify: `CLAUDE.md`

**Approach:**
- 14項目を以下の4カテゴリに分類:
  - **chezmoi CLI & ファイル管理**: autotemplate, recursion, chezmoiignore (x2), repo-only files, choosing file patterns, never edit targets, docs/plans gitignored
  - **テンプレート構文**: escaping, execute-template in CI
  - **スクリプト安全性**: modify_ empty stdout, hook one-shot flags
  - **外部制約 & ツール連携**: git signing, inline hook commands escaping
- 各カテゴリにサブヘッダー (`###`) を使用
- 項目の内容・順序は変えない（構造変更のみ）

**Patterns to follow:**
- CLAUDE.md の既存セクション構造（`##` → `###`）

**Test scenarios:**
- Happy path: カテゴリヘッダーが4つ存在し、各項目が適切なカテゴリに含まれる
- Edge case: 全14項目が漏れなく含まれていることを確認（項目数カウント）

**Verification:**
- CLAUDE.md の Known Pitfalls セクションにサブヘッダーが存在する
- 項目数は変わらない（内容の追加・削除なし）

- [ ] **Unit 2: harness-activator.sh スモークテスト追加**

**Goal:** harness-activator.sh の基本動作を CI で検証するスモークテストを追加する

**Requirements:** R2

**Dependencies:** なし

**Files:**
- Modify: `Makefile`

**Approach:**
- `test-scripts` ターゲットを新規追加
- テストシナリオ:
  1. 正常系: git リポジトリ内で、有効な session_id JSON を stdin に渡し、stdout にリマインダーメッセージが出力されることを確認
  2. コンテキストガード: `$HOME` を PWD として実行し、exit 0 で何も出力しないことを確認
  3. 重複防止: 同じ session_id で2回実行し、2回目は何も出力しないことを確認
- テスト前後で `/tmp/claude-harness-checked-*` フラグファイルをクリーンアップ
- `lint` ターゲットの依存に `test-scripts` を追加

**Patterns to follow:**
- `Makefile` の `test-modify` ターゲット: echo + pipe + 条件検証 + PASS/FAIL メッセージ

**Test scenarios:**
- Happy path: git リポジトリ内で有効な session_id → stdout に "HARNESS EVALUATION REMINDER" 含む出力
- Edge case: `HOME` ディレクトリで実行 → exit 0、stdout 空
- Edge case: 同一 session_id で2回目 → exit 0、stdout 空
- Error path: jq が見つからない場合 → exit 0（graceful skip）
- Integration: `make test-scripts` が `make lint` から呼ばれる

**Verification:**
- `make test-scripts` が成功する
- `make lint` が `test-scripts` を含む

- [ ] **Unit 3: hook ガイダンスを shell-scripts.md に昇格**

**Goal:** hook スクリプトの exit code 契約と session_id パターンを `.claude/rules/shell-scripts.md` に追加する

**Requirements:** R3

**Dependencies:** なし

**Files:**
- Modify: `.claude/rules/shell-scripts.md`

**Approach:**
- 既存の「Avoiding Recursion」セクションの前に新セクション「Hook Scripts」を追加
- 内容:
  - Exit code 契約: `exit 0` = intentional skip、`exit 1` + stderr = error、stderr なしの exit 1 は禁止
  - Session ID: `jq -r '.session_id // empty'` で取得、`$PPID`/`$$` は不安定
  - One-shot フラグ: `/tmp/claude-<name>-${SESSION_ID}` パターン、コンテキストガードの後に `touch` する
- `docs/solutions/` への参照リンクを含める

**Patterns to follow:**
- `.claude/rules/shell-scripts.md` の既存セクション構造

**Test scenarios:**
- Happy path: shell-scripts.md に "Hook Scripts" セクションが存在する
- Edge case: 既存セクションの構造が壊れていない

**Verification:**
- `.claude/rules/shell-scripts.md` に hook 関連のガイダンスが含まれる
- exit code 契約と session_id パターンが明記されている

## System-Wide Impact

- **Interaction graph:** CLAUDE.md の構造変更はエージェントの全セッションに影響。shell-scripts.md の変更は `.claude/rules/` として自動読み込みされる
- **Error propagation:** Makefile の `test-scripts` 失敗は `make lint` と CI を失敗させる
- **Unchanged invariants:** Known Pitfalls の内容自体は不変。既存の `test-modify` ターゲットも不変

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| harness-activator.sh テストが CI 環境で失敗（git/jq 依存） | CI の ubuntu-latest には git/jq がプリインストール。tool guard で graceful skip |
| Known Pitfalls の再分類でエージェントの既存参照が壊れる | 項目の文言は変更しない。サブヘッダー追加のみ |
| テスト用フラグファイルの残留 | テスト関数内で trap による cleanup |

## Sources & References

- Related solutions: `docs/solutions/developer-experience/autonomous-harness-engineering-hooks-2026-03-28.md`, `docs/solutions/integration-issues/claude-code-hook-exit-code-and-stderr-semantics.md`
- Related code: `Makefile`, `dot_claude/scripts/executable_harness-activator.sh`, `.claude/rules/shell-scripts.md`, `CLAUDE.md`
