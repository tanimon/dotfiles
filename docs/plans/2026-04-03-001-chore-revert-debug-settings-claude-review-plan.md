---
title: "chore: Revert debug settings for Claude Code Review workflow"
type: chore
status: completed
date: 2026-04-03
---

# chore: Revert debug settings for Claude Code Review workflow

## Overview

Issue #94 の残 TODO 2件を解決する。Claude Code Review ワークフローのデバッグ用設定 (`show_full_output: true`, `classify_inline_comments: false`) を本番運用に適した値に更新する。

## Problem Frame

PR #83 でデバッグ目的に設定した `show_full_output: true` と `classify_inline_comments: false` が、ワークフロー検証完了後もそのまま残っている。`show_full_output: true` はログにセンシティブな情報が含まれるリスクがある。`classify_inline_comments: false` は当時の分類パイプラインが全コメントを無言で破棄する問題への回避策だった。

## Requirements Trace

- R1. `show_full_output` の適切な値を判断し設定する
- R2. `classify_inline_comments` の適切な値を判断し設定する
- R3. Issue #94 の残 TODO を解消する

## Scope Boundaries

- claude.yml の review ステップのみ変更対象
- 他のワークフロー (security-alerts, harness-analysis 等) は対象外

## Context & Research

### Input の役割と推奨値

**`show_full_output`** (デフォルト: `false`)
- `true` にすると Claude Code の全 JSON 出力（ツール実行結果含む）を GitHub Actions ログに表示
- セキュリティ警告: シークレット、API キー等の機密情報がログに漏洩するリスクあり
- デバッグ時のみ `true` にし、本番運用では `false` が推奨

**`classify_inline_comments`** (デフォルト: `true`)
- `true` にするとインラインコメントをバッファし、分類パイプラインで「本物のレビューコメント」か「探索中のプローブ」かを判定してから投稿
- `false` にするとコメントを即時投稿（分類スキップ）
- Solution doc (`claude-code-review-no-pr-comments-classify-inline-filter-2026-03-29.md`) によると、`true` 時に code-review プラグインの出力形式と分類システムの期待が一致せず全コメントが破棄された

### 判断

**`show_full_output: true` → `false` に変更する**
- ワークフロー検証は完了済み（Issue #94 の最初の TODO がチェック済み）
- パブリックリポジトリのため、ログにセンシティブ情報が漏れるリスクを排除すべき
- 再度デバッグが必要になった場合は一時的に `true` に戻せばよい

**`classify_inline_comments: false` → 行自体を削除する（デフォルト `true` に戻す）**
- claude-code-action は継続的に更新されており、SHA `58dbe8e` 以降のバージョンで分類パイプラインが改善されている可能性が高い
- ただし、改善が確認できていないリスクがある。デフォルト `true` に戻した後、次回の `/review` 実行でコメントが正しく投稿されることを確認する必要がある
- もし分類パイプラインがまだ壊れている場合は `false` に再設定すればよい
- **代替案**: 安全策として `classify_inline_comments: false` を維持する。分類パイプラインの修正が確認されるまで変更しない

### Institutional Learnings

- `docs/solutions/integration-issues/claude-code-review-no-pr-comments-classify-inline-filter-2026-03-29.md` — 分類パイプラインが全コメントを破棄した root cause 分析

## Key Technical Decisions

- `show_full_output` は `false` に戻す（セキュリティ上の理由）
- `classify_inline_comments` は `false` を維持する（分類パイプラインの修正がアップストリームで確認できていないため）。行は明示的に残し、将来デフォルト `true` に戻す際のコメントを追加

## Implementation Units

- [ ] **Unit 1: claude.yml の review ステップ設定を更新**

**Goal:** デバッグ設定を本番向けに更新する

**Requirements:** R1, R2

**Dependencies:** None

**Files:**
- Modify: `.github/workflows/claude.yml`

**Approach:**
- `show_full_output: true` → 行を削除（デフォルト `false` に戻す）
- `classify_inline_comments: false` → そのまま維持し、理由コメントを追加

**Patterns to follow:**
- 既存の claude.yml のコメントスタイル

**Test scenarios:**
- Happy path: `show_full_output` 行が削除されていること
- Happy path: `classify_inline_comments: false` が維持されていること
- Integration: actionlint が通ること (`make actionlint`)

**Verification:**
- `make lint` が通る
- claude.yml の diff が意図通りである

- [ ] **Unit 2: Issue #94 の TODO を更新するコメントを投稿**

**Goal:** Issue #94 に対応完了のコメントを投稿し、クローズする

**Requirements:** R3

**Dependencies:** Unit 1

**Files:** None (GitHub API 操作)

**Approach:**
- `gh issue comment` で判断結果と理由を記載
- `gh issue close` でクローズ

**Test expectation:** none -- GitHub API 操作のみ

**Verification:**
- Issue #94 がクローズされている

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| classify_inline_comments を false のまま残すことでレビューの質が下がる | code-review プラグインが自前で分類を行うため、追加分類は冗長。将来アップストリームの改善を確認したら true に戻す |

## Sources & References

- Related issues: #94, #83, #92, #93, #104
- Solution doc: `docs/solutions/integration-issues/claude-code-review-no-pr-comments-classify-inline-filter-2026-03-29.md`
- External docs: [claude-code-action action.yml](https://github.com/anthropics/claude-code-action/blob/main/action.yml)
