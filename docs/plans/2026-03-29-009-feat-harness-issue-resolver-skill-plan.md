---
title: "feat: Create harness-issue-resolver Skill"
type: feat
status: completed
date: 2026-03-29
---

# feat: Create harness-issue-resolver Skill

## Overview

harness-analysis ラベル付き GitHub issue を自動修正するワークフローを再利用可能な Claude Code コマンド（slash command）として定義する。今回のセッションで手動実行したフロー（issue 確認 → branch 作成 → 修正 → docs 記録 → PR 作成）を `/resolve-harness-issues` コマンドとして Skill 化する。

## Problem Frame

CI の harness-analysis ワークフローが weekly で issue を自動起票するが、修正は手動プロセスに依存している。今回のセッションでは 8 件の issue を手動で確認・修正・close したが、このフローは定型的で Skill 化に適している。

## Requirements Trace

- R1. `/resolve-harness-issues` コマンドで harness-analysis ラベル付き open issue を一覧表示し、修正フローを開始できる
- R2. main ではなく feature branch 上で作業し、PR を作成する
- R3. 既存スキル（`/lfg` 相当のプラン→実装フロー、`/ce:compound`、`/git-commit-push-pr`）を適切に参照・誘導する
- R4. issue が 0 件の場合は早期終了する
- R5. 修正完了後に issue を close するよう指示する

## Scope Boundaries

- Claude Code コマンド（`dot_claude/commands/` に `.md` ファイル）として実装。plugin skill ではない
- コマンドは LLM への指示プロンプトであり、シェルスクリプトではない
- 自動的にコードを書く・コミットする仕組みは作らない（LLM に判断を委ねる）

## Key Technical Decisions

- **Claude Code コマンド（.md）で実装**: `dot_claude/commands/resolve-harness-issues.md` として作成。理由：既存の `harness-health.md`, `capture-harness-feedback.md` と同じパターン。plugin skill は不要（外部依存なし、単一プロンプト定義で十分）
- **他のスキルを直接呼び出さず、フェーズごとに指示を記述**: `/lfg` や `/ce:compound` は compound-engineering plugin の skill。コマンド内で直接呼び出すのではなく、各フェーズの手順を自己完結で記述し、必要に応じてユーザーが plugin skill を併用できる形にする。理由：plugin への依存を最小化し、plugin がない環境でも動作する
- **feature branch 作成を明示的にフローに組み込む**: main 直接 commit を防止するため、最初のステップで branch 作成を指示

## Open Questions

### Resolved During Planning

- **コマンド名は？**: `resolve-harness-issues` — 動作を明確に表す命名。`/resolve-harness-issues` で呼び出し
- **wontfix の判断はどうするか？**: コマンド内で issue ごとに修正 or wontfix の判断をエージェントに委ねる指示を記述

### Deferred to Implementation

- **issue が多い場合のバッチサイズ**: 実際の運用で調整（初期は全件処理）

## Implementation Units

- [ ] **Unit 1: コマンドファイル作成**

**Goal:** `/resolve-harness-issues` コマンドを作成

**Requirements:** R1, R2, R3, R4, R5

**Dependencies:** None

**Files:**
- Create: `dot_claude/commands/resolve-harness-issues.md`

**Approach:**
- 既存コマンド（`harness-health.md`, `capture-harness-feedback.md`）のスタイルに従い、markdown プロンプトとして記述
- フェーズ構成: (1) issue 確認 (2) branch 作成 (3) issue ごとの修正ループ (4) make lint 検証 (5) commit (6) docs 記録 (7) PR 作成 (8) issue close
- 各フェーズの指示は自己完結（plugin skill への依存なし）

**Patterns to follow:**
- `dot_claude/commands/harness-health.md` の構造（ステップバイステップ + 出力フォーマット）
- `dot_claude/commands/capture-harness-feedback.md` の分類アプローチ

**Test scenarios:**
- Happy path: open issue が存在する → branch 作成 → 修正 → PR 作成の全フローが指示される
- Edge case: open issue が 0 件 → 早期終了メッセージ
- Edge case: 一部 issue が wontfix → close with comment の指示

**Verification:**
- `chezmoi managed | grep resolve-harness-issues` でファイルが管理対象
- コマンドが `/resolve-harness-issues` として認識される（Claude Code で呼び出し可能）

---

- [ ] **Unit 2: CLAUDE.md にコマンドを追記**

**Goal:** CLAUDE.md の Common Commands セクションに新コマンドを追記

**Requirements:** R1

**Dependencies:** Unit 1

**Files:**
- Modify: `CLAUDE.md`

**Approach:**
- Common Commands セクションまたは適切な場所に `/resolve-harness-issues` の説明を一行追加

**Test scenarios:**
- Happy path: CLAUDE.md に新コマンドの記載がある

**Verification:**
- `grep resolve-harness-issues CLAUDE.md` でヒットする

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| コマンドが長すぎてエージェントが全指示を遵守しない | 各フェーズを簡潔に記述し、重要な制約（branch 作成必須、make lint 必須）を冒頭に記載 |
| plugin skill なしでは一部機能が不足 | コマンドは自己完結で動作可能に設計。plugin skill は optional enhancement として記載 |

## Sources & References

- Related code: `dot_claude/commands/harness-health.md`, `dot_claude/commands/capture-harness-feedback.md`
- Related solution: `docs/solutions/developer-experience/autonomous-harness-engineering-hooks-2026-03-28.md`
- Related plan: `docs/plans/2026-03-29-008-fix-autonomous-harness-engineering-verification-plan.md`
