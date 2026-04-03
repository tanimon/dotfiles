---
title: "fix: Allow Renovate bot in Claude Code Review workflow"
type: fix
status: completed
date: 2026-03-29
---

# fix: Allow Renovate bot in Claude Code Review workflow

## Overview

`claude-code-review.yml` ワークフローが Renovate bot の PR で失敗する。`claude-code-action` の `allowed_bots` パラメータが未設定のため、bot アクターが拒否される。

## Problem Frame

Renovate bot が PR #69 を作成 → `claude-code-review.yml` がトリガー → `claude-code-action` が actor type を検出 → `renovate` が Bot であることを検出 → `allowed_bots` が空のためエラー: "Workflow initiated by non-human actor: renovate (type: Bot). Add bot to allowed_bots list or use '*' to allow all bots."

## Requirements Trace

- R1. Renovate bot が作成した PR に対して Claude Code Review が正常に実行されること
- R2. セキュリティを維持し、許可する bot を明示的にリストすること（`*` ワイルドカードは使わない）

## Scope Boundaries

- `claude-code-review.yml` のみ変更。`claude.yml` は `@claude` メンション + `author_association` ガードで別メカニズムのため対象外
- `dependabot[bot]` も将来に備えて追加する（同様のエラーを予防）

## Context & Research

### Relevant Code and Patterns

- `.github/workflows/claude-code-review.yml:25-30` — `claude-code-action` の `with:` ブロック
- `.github/workflows/claude.yml` — `author_association` ガードの参考パターン
- `claude-code-action` の `action.yml` が `allowed_bots` をカンマ区切り文字列として受け付ける

### Institutional Learnings

- `docs/solutions/integration-issues/claude-code-action-v1-parameter-migration-2026-03-29.md` — GitHub Actions は `with:` の未知キーを silent ignore するため、パラメータ名は pinned SHA の `action.yml` で検証すべき

## Key Technical Decisions

- **`allowed_bots` に明示リストを使う（`*` ではない）**: セキュリティドキュメントが `*` は外部アプリケーションのプロンプト注入リスクがあると警告。`renovate[bot],dependabot[bot]` を明示指定する
- **`dependabot[bot]` も追加**: Renovate と同じく dependency update bot であり、同じエラーを予防する

## Implementation Units

- [ ] **Unit 1: `allowed_bots` を claude-code-review.yml に追加**

**Goal:** Renovate bot と Dependabot の PR で Claude Code Review が実行されるようにする

**Requirements:** R1, R2

**Dependencies:** None

**Files:**
- Modify: `.github/workflows/claude-code-review.yml`

**Approach:**
- `claude-code-action` の `with:` ブロックに `allowed_bots: 'renovate[bot],dependabot[bot]'` を追加

**Patterns to follow:**
- 既存の `with:` ブロックのインデント・スタイル

**Test scenarios:**
- Happy path: Renovate bot の PR でワークフローがエラーなく進行すること（PR #69 の re-run で検証）

**Verification:**
- `make lint` が通ること
- PR #69 のワークフローを re-run して Bot エラーが解消されること
