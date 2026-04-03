---
title: "fix: Claude Code Review ワークフローがレビューコメントを投稿しない"
type: fix
status: completed
date: 2026-03-29
deepened: 2026-03-29
---

# fix: Claude Code Review ワークフローがレビューコメントを投稿しない

## Overview

`.github/workflows/claude-code-review.yml` が PR に対して正常に実行完了するが、レビューコメントが一切投稿されない問題を修正する。

## Problem Frame

ワークフロー実行完了後も PR にレビューコメントが投稿されない。調査の結果、複合的な問題が判明:

1. **`classify_inline_comments` のデフォルト動作** — `true`（デフォルト）の場合、インラインコメントはバッファリングされ、分類後に投稿される。分類で全てフィルタされている可能性がある
2. **パーミッション不足** — 一部の実行で 11〜18件のパーミッション拒否が発生（ただし最新の実行では 0件に改善）
3. **`show_full_output: false`** — エージェントの実際の動作が不可視で、原因特定が困難
4. **`claude.yml` との権限差異** — `actions: read`、`additional_permissions`、`issues: write` が欠落

最新のワークフロー実行（Run 23701011894）では `permission_denials_count: 0` にもかかわらず「No buffered inline comments」となっており、パーミッション問題だけが原因ではないことが確認された。

## Requirements Trace

- R1. PR にレビューコメント（インラインまたはサマリー）が投稿されること
- R2. ワークフロー出力が確認可能であること（デバッグ容易性）
- R3. `claude.yml` との権限構成の一貫性が確保されること
- R4. ワークフローファイル自体を変更する PR の OIDC 失敗は既知の制約として許容

## Scope Boundaries

- OIDC 認証失敗（ワークフローファイル変更 PR）は修正対象外（claude-code-action の設計上の制約）
- `code-review` プラグイン自体のロジック変更は対象外
- `claude.yml`（インタラクティブワークフロー）は変更しない

## Context & Research

### Relevant Code and Patterns

- `.github/workflows/claude.yml` — 動作中のインタラクティブワークフロー（比較対象）
  - `additional_permissions: actions: read` を設定
  - ワークフロー permissions に `actions: read` を含む
  - `issues: write` を持つ
- `.github/workflows/claude-code-review.yml` — 問題のレビューワークフロー
  - `additional_permissions` 未設定
  - `actions: read` permission なし
  - `issues: read` のみ（`write` ではない）

### Institutional Learnings

- `docs/solutions/integration-issues/claude-code-action-v1-parameter-migration-2026-03-29.md`: GitHub Actions は認識しない `with:` キーをサイレントに無視する。→ 今回は `plugins`、`plugin_marketplaces`、`prompt` は全て有効な v1 パラメータであることを確認済み。

### ワークフロー実行データ（更新済み）

| Run ID | PR | permission_denials_count | コスト | ターン数 | 結果 |
|--------|-----|--------------------------|--------|---------|------|
| 23701011894 | #82 (2回目) | **0** | $0.90 | 17 | No buffered inline comments |
| 23700930828 | #82 (1回目) | 18 | $1.02 | 不明 | No buffered inline comments |
| 23700528958 | #80 | 11 | $1.18 | 19 | No buffered inline comments |

**重要**: パーミッション拒否が 0 の実行でも 17 ターン・$0.90 のコストが発生しコメントが投稿されていない。エージェントは実質的な作業を行っているが、出力が PR に到達していない。

### External References

- `anthropics/claude-code-action` action.yml:
  - `classify_inline_comments` (default: `true`): インラインコメントをバッファリングし分類後に投稿
  - `show_full_output` (default: `false`): Claude Code の完全な JSON 出力を表示
  - `additional_permissions`: GitHub 追加権限のリクエスト

## Key Technical Decisions

- **`show_full_output: true` を追加（最優先）**: エージェントが 17 ターンで何をしているかを可視化する。他の修正の効果を検証するための前提条件。
- **`classify_inline_comments: false` を追加（診断用）**: デフォルトの分類ステップがコメントをフィルタしている可能性を排除する。コメントが投稿されることを確認後、`true` に戻すか判断する。
- **`claude.yml` と権限を一致させる**: `actions: read`（permissions + additional_permissions）および `issues: write` を追加。権限差異がコメント投稿を阻害している可能性を一括で排除する。

## Open Questions

### Resolved During Planning

- **Q: パラメータは有効な v1 パラメータか？** → 有効。action.yml で確認済み。
- **Q: ワークフローファイル変更 PR の失敗は修正可能か？** → 不可。OIDC 認証の設計上の制約。
- **Q: パーミッション拒否が唯一の原因か？** → いいえ。最新実行（Run 23701011894）で `permission_denials_count: 0` でもコメント未投稿。複合的な問題。

### Deferred to Implementation

- **Q: エージェントの 17 ターンで具体的に何が行われているか？** → `show_full_output: true` の出力で確認。
- **Q: `classify_inline_comments` が原因なら、`true` に戻した場合どう調整するか？** → コメント投稿確認後に検討。

## Implementation Units

- [ ] **Unit 1: ワークフロー設定の包括的修正**

**Goal:** コメント未投稿の複合原因を一括で解消し、デバッグ可能な状態にする

**Requirements:** R1, R2, R3, R4

**Dependencies:** なし

**Files:**
- Modify: `.github/workflows/claude-code-review.yml`

**Approach:**
1. `with:` に `show_full_output: true` を追加（R2: デバッグ容易性）
2. `with:` に `classify_inline_comments: false` を追加（R1: 分類フィルタのバイパス）
3. ワークフロー permissions に `actions: read` を追加（R3: claude.yml との一貫性）
4. `with:` に `additional_permissions: actions: read` を追加（R3: claude.yml との一貫性）
5. ワークフロー permissions の `issues: read` を `issues: write` に変更（R3: claude.yml との一貫性、コメント投稿に必要な可能性）

**Patterns to follow:**
- `.github/workflows/claude.yml` の permissions 構成と `additional_permissions` パターン

**Test scenarios:**
- Happy path: 修正を含む PR 自体、またはマージ後の次の PR で、レビューコメントが PR に投稿される
- Happy path: `show_full_output: true` により GitHub Actions ログでエージェントの完全な出力が確認できる
- Edge case: ワークフローファイル自体を変更する PR では OIDC 401 で失敗する（R4: 既知の制約）
- Edge case: Renovate/Dependabot の PR でも `allowed_bots` 設定により正常にレビューが実行される

**Verification:**
- PR にレビューコメント（インラインまたはサマリー）が投稿されること
- Actions ログに Claude Code の詳細出力が表示されること
- `permission_denials_count` が 0 またはそれに近い値であること
- 修正を含む PR 自体は OIDC 制約で review ステップが失敗する可能性がある（ワークフローファイル変更のため）。マージ後の次の PR で検証する

## System-Wide Impact

- **Interaction graph:** `claude-code-review.yml` のみ変更。`claude.yml` や他のワークフローに影響なし
- **Error propagation:** `issues: write` 追加で review ワークフローが issue にコメントを書く能力を得る。意図しない書き込みリスクは低い（code-review プラグインのスコープ内）
- **API surface parity:** `claude.yml` と `claude-code-review.yml` のパーミッション構成が一致し、一貫性が向上

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| 全修正を適用してもコメントが投稿されない | `show_full_output: true` でエージェントの動作を詳細に確認し、次のステップを判断 |
| `show_full_output: true` でセンシティブ情報が漏洩 | Public リポジトリ。OAuth トークンは GitHub がマスク |
| `classify_inline_comments: false` で低品質コメントが投稿される | まず動作確認を優先。品質調整は後続の改善で対応 |
| ワークフローファイル変更 PR で OIDC 失敗 | 既知の制約。PR 説明に明記。マージ後の次の PR で検証 |

## Sources & References

- `.github/workflows/claude.yml` — 動作中のワークフロー（比較対象）
- `anthropics/claude-code-action` action.yml — v1 パラメータ定義（`classify_inline_comments`, `show_full_output`, `additional_permissions`）
- `docs/solutions/integration-issues/claude-code-action-v1-parameter-migration-2026-03-29.md`
- ワークフロー実行ログ: Run 23701011894 (0 denials), 23700930828 (18 denials), 23700528958 (11 denials)
