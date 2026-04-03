---
title: "feat: Scheduled CI harness analysis with automatic Issue creation"
type: feat
status: completed
date: 2026-03-29
---

# feat: Scheduled CI harness analysis with automatic Issue creation

## Overview

定期的に Claude Code を CI 上で実行し、harness の改善点やリファクタリングすべき箇所を検出して GitHub Issue を自動作成する。修正自体は CI で行わず、発見と Issue 化までをスコープとする。

## Problem Frame

現在 harness の改善は開発者がセッション終了時に手動で `/harness-health` や `/capture-harness-feedback` を実行することに依存している。定期的な自動チェックがないため、ルールの陳腐化、パターンのドリフト、ドキュメントと実装の乖離が検出されずに蓄積する。

## Requirements Trace

- R1. 定期的（週次程度）に harness の改善点を自動検出する
- R2. 検出結果を GitHub Issue として自動作成する
- R3. 手動トリガー（workflow_dispatch）でも実行可能にする
- R4. 重複 Issue を避けるメカニズムを持つ
- R5. 既存のセキュリティ硬化ルール（SHA pinning, author_association guards）に準拠する

## Scope Boundaries

- Issue 作成まで。自動修正 PR は対象外
- このリポジトリ（chezmoi dotfiles）のみ対象。クロスプロジェクト分析は対象外
- Claude Code の既存スキル（harness-health, capture-harness-feedback の知見）をプロンプトで活用。新規スキル作成は不要

## Context & Research

### Relevant Code and Patterns

- `.github/workflows/claude.yml` — claude-code-action の使用パターン。`anthropics/claude-code-action@aee99972d0cfa0c47a4563e6fca42d7a5a0cb9bd # v1` で SHA pinning 済み
- `.github/workflows/claude-code-review.yml` — 同じ action の別パターン
- `.github/workflows/lint.yml` — Makefile ミラーパターン（ただし本ワークフローは Makefile 不要）
- `dot_claude/commands/harness-health.md` — harness 健全性スコアリングの 5 次元評価基準
- `dot_claude/commands/capture-harness-feedback.md` — セッション振り返りと改善提案のフォーマット
- `~/.claude/rules/common/github-actions.md` — `contains(fromJSON(...))` パターン、SHA pinning、fork guard ルール

### Institutional Learnings

- `docs/solutions/integration-issues/github-actions-expression-in-operator-does-not-exist-2026-03-29.md` — `in` 演算子は使わず `contains(fromJSON(...))` を使用
- `docs/solutions/developer-experience/chezmoi-project-harness-rules-and-ci-2026-03-28.md` — CI と Makefile のミラー契約

## Key Technical Decisions

- **claude-code-action を使用**: 既にリポジトリで使われている `anthropics/claude-code-action` を再利用。新たなツールチェーン導入は不要。claude.yml と同じ SHA ピンを使用
- **Cron スケジュール: 週1回（月曜 09:00 JST = 日曜 00:00 UTC）**: 日次は Issue ノイズが多すぎ、月次は遅すぎる。週次が適切なバランス
- **重複防止: ラベル + Issue 検索**: `harness-analysis` ラベルと open Issue タイトル検索で重複 Issue を防止。Claude Code プロンプト内で `gh issue list` を使って既存 Issue を確認させる
- **分析プロンプトの設計**: harness-health の評価基準をプロンプトに埋め込み、具体的なファイルパスとアクションを含む Issue を生成させる。汎用的な「improve code quality」ではなく、actionable な提案のみを Issue 化

## Open Questions

### Resolved During Planning

- **Q: 分析対象は何か?** → CLAUDE.md、.claude/rules/、dot_claude/ 配下のルール・コマンド・フック、およびコードベースのパターンドリフト。docs/solutions/ の活用度も含む
- **Q: Issue のフォーマットは?** → タイトルにカテゴリプレフィックス（`[harness]`）、本文に具体的ファイルパス・現状・提案アクションを含む構造化フォーマット

### Deferred to Implementation

- **Q: プロンプトの最適な長さと詳細度** → 初回実装後に Issue の品質を見て調整

## Implementation Units

- [ ] **Unit 1: Scheduled workflow ファイル作成**

  **Goal:** 週次 cron + 手動トリガーで Claude Code による harness 分析を実行し、Issue を作成するワークフローを追加

  **Requirements:** R1, R2, R3, R4, R5

  **Dependencies:** None

  **Files:**
  - Create: `.github/workflows/harness-analysis.yml`

  **Approach:**
  - `on.schedule` (cron: `0 0 * * 0` = 毎週日曜 00:00 UTC) と `on.workflow_dispatch` の両方をトリガーに設定
  - `anthropics/claude-code-action` を使用。既存 `claude.yml` と同じ SHA pin (`aee99972d0cfa0c47a4563e6fca42d7a5a0cb9bd`)
  - `actions/checkout` も同じ SHA pin (`34e114876b0b11c390a56381ad16ebd13914f8d5`)
  - permissions: `contents: read`, `issues: write`, `id-token: write`
  - プロンプトで Claude Code に以下を指示:
    1. リポジトリの harness 状態を分析（CLAUDE.md、.claude/rules/、dot_claude/ のルール・コマンド・フック）
    2. 改善点を特定（陳腐化ルール、パターンドリフト、ドキュメント乖離、リファクタリング候補）
    3. `gh issue list --label harness-analysis --state open` で既存 Issue を確認
    4. 新規発見のみ `gh issue create --label harness-analysis` で Issue 作成
    5. 各 Issue に具体的ファイルパスと推奨アクションを含める
  - `direct_prompt` パラメータを使用（`prompt` ではなく Issue/PR コンテキスト不要のため）
  - `allowed_tools` で `Bash`, `Read`, `Glob`, `Grep` と `gh issue` 関連コマンドのみ許可

  **Patterns to follow:**
  - `.github/workflows/claude.yml` — action SHA pin、permissions 構成
  - `.github/workflows/claude-code-review.yml` — claude-code-action の基本構成

  **Test scenarios:**
  - Happy path: workflow_dispatch で手動実行し、分析結果の Issue が作成される
  - Happy path: cron トリガーでワークフローが正常起動する（Actions タブで確認）
  - Edge case: 改善点がない場合、Issue が作成されない（空振り OK）
  - Edge case: 既に同名の open Issue がある場合、重複 Issue が作成されない
  - Error path: CLAUDE_CODE_OAUTH_TOKEN が未設定の場合、明確なエラーで失敗する

  **Verification:**
  - `workflow_dispatch` で手動実行し、GitHub Actions ログで分析プロセスが正常完了すること
  - 作成された Issue に `harness-analysis` ラベルが付与され、具体的なファイルパスと推奨アクションが含まれること

- [ ] **Unit 2: harness-analysis ラベル作成**

  **Goal:** Issue 分類・重複防止用の GitHub ラベルを作成

  **Requirements:** R4

  **Dependencies:** None（Unit 1 と並行可能）

  **Files:**
  - None（gh CLI で作成）

  **Approach:**
  - `gh label create harness-analysis --description "Automated harness improvement suggestions" --color 0E8A16` で作成
  - ワークフローの README/CLAUDE.md に記載は不要（ラベル自体が self-documenting）

  **Patterns to follow:**
  - 既存の GitHub ラベル管理（手動作成）

  **Test scenarios:**
  - Happy path: ラベルが作成され、Issues ページのラベルフィルタで使用可能

  **Verification:**
  - `gh label list` で `harness-analysis` ラベルが存在すること

- [ ] **Unit 3: CLAUDE.md に定期分析ワークフローを記載**

  **Goal:** 新ワークフローの存在と用途を CLAUDE.md に記載し、将来のエージェントが認識できるようにする

  **Requirements:** R1

  **Dependencies:** Unit 1

  **Files:**
  - Modify: `CLAUDE.md`

  **Approach:**
  - 既存の「Common Commands」セクションに `workflow_dispatch` の手動実行方法を追記
  - Architecture セクションに定期分析の仕組みを簡潔に記載

  **Patterns to follow:**
  - CLAUDE.md の既存フォーマット・記述スタイル

  **Test scenarios:**
  - Happy path: CLAUDE.md に追記された内容が正確で、既存セクションとの整合性がある

  **Verification:**
  - `chezmoi apply --dry-run` で CLAUDE.md の変更が意図通りであること

## System-Wide Impact

- **Interaction graph:** 新ワークフローは独立。既存の lint.yml、claude.yml、claude-code-review.yml に影響なし
- **Error propagation:** Claude Code の分析失敗はワークフロー失敗として Actions タブに表示。外部への影響なし
- **State lifecycle risks:** 重複 Issue 生成のリスクあり。ラベル + タイトル検索で軽減
- **API surface parity:** 影響なし
- **Integration coverage:** workflow_dispatch による手動テストで検証可能
- **Unchanged invariants:** 既存の lint.yml、claude.yml、claude-code-review.yml は一切変更しない

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Claude Code の分析品質が低く、ノイズの多い Issue が作成される | プロンプトで「actionable な提案のみ」を明示。初回実行後にプロンプトを調整 |
| CLAUDE_CODE_OAUTH_TOKEN の有効期限切れ | 既存ワークフロー（claude.yml）と同じ secret を共有。既存の運用で管理 |
| cron ジョブの実行遅延（GitHub Actions の cron は保証なし） | 週次スケジュールのため多少の遅延は許容。手動トリガーも可能 |
| Issue の重複作成 | ラベルフィルタと Claude Code プロンプト内での既存 Issue 確認で防止 |

## Sources & References

- Related workflows: `.github/workflows/claude.yml`, `.github/workflows/claude-code-review.yml`
- Harness health criteria: `dot_claude/commands/harness-health.md`
- Security rules: `~/.claude/rules/common/github-actions.md`
- Past learning: `docs/solutions/integration-issues/github-actions-expression-in-operator-does-not-exist-2026-03-29.md`
