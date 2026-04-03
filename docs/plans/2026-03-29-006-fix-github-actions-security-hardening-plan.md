---
title: "fix: Harden Claude Code GitHub Actions workflows (P1 security)"
type: fix
status: completed
date: 2026-03-29
---

# fix: Harden Claude Code GitHub Actions workflows (P1 security)

## Overview

PR #68 のコードレビューで検出された3つの P1 セキュリティ問題を修正する。GitHub Actions ワークフロー（`claude-code-review.yml`, `claude.yml`）に対して、author ガード、SHA ピニング、fork PR 除外を追加。

## Problem Frame

現状のワークフローはテンプレートから生成されたもので、パブリックリポジトリにおけるセキュリティハードニングが不足している:
- 任意の GitHub ユーザーが `@claude` で API クレジットを消費可能
- mutable tag (`@v1`) によりサプライチェーン攻撃のリスクあり
- Fork PR がレビューワークフローをトリガーしてリソースを消費可能

## Requirements Trace

- R1. `@claude` メンションを OWNER/MEMBER/COLLABORATOR に制限する
- R2. 全 GitHub Actions を SHA ピニングに変更し、Renovate で自動更新する
- R3. Fork PR がレビューワークフローをトリガーしないようにする

## Scope Boundaries

- `claude-code-action` 内部のプロンプトハードニングは対象外（サードパーティ依存）
- `concurrency` 制限の追加は対象外（別途検討）
- `id-token: write` の要否検証は対象外（action の要件確認が必要）

## Context & Research

### Relevant Code and Patterns

- `.chezmoiexternal.toml` — SHA ピニング + Renovate の確立パターン
- `renovate.json` — `config:recommended` を extend。GitHub Actions の SHA ピニングは Renovate の built-in `github-actions` マネージャーが自動検出する
- `.claude/rules/renovate-external.md` — adjacency contract のルール（`.chezmoiexternal.toml` 用だが、ピニング哲学は共通）

### Institutional Learnings

- `docs/solutions/integration-issues/chezmoi-external-script-repo-with-renovate-sha-pinning.md` — SHA ピニング + Renovate のパターンが確立済み

## Key Technical Decisions

- **author_association ガード方式**: `github.actor` のリストではなく `github.event.*.author_association` を使用。リポジトリの collaborator 設定と自動連動し、メンテナンスが不要なため
- **Renovate GitHub Actions 設定**: `config:recommended` に `helpers:pinGitHubActionDigests` を追加。built-in マネージャーが `uses: action@<sha> # vN` パターンを自動検出し、SHA 更新 PR を生成する。`.chezmoiexternal.toml` 用の custom manager とは独立して動作する
- **Fork ガード方式**: `github.event.pull_request.head.repo.full_name == github.repository` を使用。シンプルかつ確実にフォーク PR を除外できる

## Open Questions

### Resolved During Planning

- **Renovate に追加設定は必要か?**: `helpers:pinGitHubActionDigests` preset を `extends` に追加するだけでよい。SHA ピニング済みの `uses:` ディレクティブは built-in マネージャーが自動検出する
- **claude.yml の全イベントに author_association ガードは適用できるか?**: `issue_comment` と `pull_request_review_comment` は `author_association` を持つ。`issues` イベントは `github.event.issue` に `author_association` がないため、`github.actor` ベースのチェックか `github.event.sender.type` 等で代替する必要がある。ただし、OWNER 本人が issue を作成するユースケースが主なので、`issues` イベントは `author_association` をサポートしない点を受け入れ、コメント系イベントのみガードする

### Deferred to Implementation

- **SHA の具体的な値**: 実装時に `gh api` で最新の SHA を取得する

## Implementation Units

- [x] **Unit 1: author_association ガード追加**

**Goal:** `claude.yml` の `@claude` トリガーを OWNER/MEMBER/COLLABORATOR に制限

**Requirements:** R1

**Dependencies:** なし

**Files:**
- Modify: `.github/workflows/claude.yml`

**Approach:**
- `if` 条件に `author_association` チェックを追加
- `issue_comment` と `pull_request_review_comment` には `github.event.comment.author_association` を使用
- `pull_request_review` には `github.event.review.author_association` を使用
- `issues` イベントには直接的な author_association がないため、既存の body/title チェックのみ維持（OWNER 利用が主）
- 許可する association: `OWNER`, `MEMBER`, `COLLABORATOR`

**Patterns to follow:**
- anthropics/claude-code-action 公式ドキュメントのテンプレート例

**Test scenarios:**
- Happy path: OWNER がコメントで `@claude` → ワークフロー実行される（if 条件が true）
- Edge case: FIRST_TIME_CONTRIBUTOR が `@claude` コメント → ワークフローがスキップされる（if 条件が false）
- Edge case: `issues` の `opened` イベントは author_association ガードなし → OWNER が作成した `@claude` issue は実行される

**Verification:**
- `if` 条件に author_association チェックが含まれている
- YAML 構文が有効（GitHub Actions の `if` expression として正しい）

- [x] **Unit 2: SHA ピニング + Renovate 設定**

**Goal:** 全 GitHub Actions を SHA ピニングに変更し、Renovate で自動更新

**Requirements:** R2

**Dependencies:** なし

**Files:**
- Modify: `.github/workflows/claude-code-review.yml`
- Modify: `.github/workflows/claude.yml`
- Modify: `renovate.json`

**Approach:**
- `actions/checkout@v4` と `anthropics/claude-code-action@v1` の現在の SHA を取得
- `uses:` を `action@<sha> # vN` 形式に変更
- `renovate.json` の `extends` に `helpers:pinGitHubActionDigests` を追加
- SHA の取得: `gh api repos/{owner}/{repo}/git/ref/tags/v{version}` または `git ls-remote`

**Patterns to follow:**
- `.chezmoiexternal.toml` の SHA ピニング形式
- Renovate の GitHub Actions マネージャーが期待する `uses: action@sha # tag` コメント形式

**Test scenarios:**
- Happy path: SHA ピニング後もワークフローが正常にトリガーされる
- Happy path: Renovate が SHA ピニングを検出し、更新 PR を生成できる

**Verification:**
- 両ワークフローの `uses:` が 40文字の SHA でピニングされている
- バージョンタグがコメントで保持されている
- `renovate.json` に `helpers:pinGitHubActionDigests` が含まれている

- [x] **Unit 3: Fork PR ガード追加**

**Goal:** Fork PR がレビューワークフローをトリガーしないようにする

**Requirements:** R3

**Dependencies:** なし

**Files:**
- Modify: `.github/workflows/claude-code-review.yml`

**Approach:**
- job レベルの `if` に fork 除外条件を追加: `github.event.pull_request.head.repo.full_name == github.repository`
- これにより、fork からの PR ではジョブ全体がスキップされる

**Patterns to follow:**
- GitHub Actions 公式ドキュメントの fork PR セキュリティパターン

**Test scenarios:**
- Happy path: 同一リポジトリからの PR → ワークフロー実行
- Edge case: Fork からの PR → ジョブがスキップされる

**Verification:**
- `claude-code-review.yml` の job に `if` ガードが追加されている

## System-Wide Impact

- **Interaction graph:** Renovate の `helpers:pinGitHubActionDigests` は既存の `.chezmoiexternal.toml` custom manager と独立して動作。干渉なし
- **Error propagation:** author_association ガードにより、権限のないユーザーのコメントは GitHub Actions のジョブスキップで処理される（エラーではなく正常なスキップ）
- **Unchanged invariants:** 既存の `make lint` CI ワークフロー（`.github/workflows/lint.yml`）は変更なし

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| SHA 取得時に間違ったタグを参照 | `gh api` で正確な ref を取得し、ピニング後に YAML 構文を確認 |
| Renovate が SHA 更新を検出しない | `helpers:pinGitHubActionDigests` preset が `# vN` コメント形式を期待。形式を確実に合わせる |
| author_association ガードが厳しすぎて正当な利用者を排除 | COLLABORATOR を含めることで、リポに招待された外部協力者も利用可能 |

## Sources & References

- Related PR: #68
- Renovate docs: GitHub Actions manager (built-in)
- `docs/solutions/integration-issues/chezmoi-external-script-repo-with-renovate-sha-pinning.md`
