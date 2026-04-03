---
title: "feat: Improve harness with project rules, verification docs, and CI"
type: feat
status: completed
date: 2026-03-28
---

# feat: Improve harness with project rules, verification docs, and CI

## Overview

ハーネスヘルスレポートで特定された3つのギャップを埋める: (1) プロジェクト固有の `.claude/rules/` 追加、(2) CLAUDE.md に Verification セクション追加、(3) GitHub Actions CI 追加。

## Problem Frame

このリポジトリで作業するエージェントは `dot_claude/rules/` のグローバルルール（デプロイ先: `~/.claude/rules/`）を持つが、chezmoi リポジトリ自体で作業する際のプロジェクト固有ルールがない。また、変更を検証する手順が CLAUDE.md に文書化されておらず、CI も未設定のため、pre-commit をすり抜けた問題を検出できない。

## Requirements Trace

- R1. `.claude/rules/` にプロジェクト固有ルールを追加し、エージェントが chezmoi テンプレート・シェルスクリプトの落とし穴を回避できるようにする
- R2. CLAUDE.md に Verification セクションを追加し、変更の検証方法を明記する
- R3. GitHub Actions CI で secretlint, shellcheck, shfmt を自動実行する

## Scope Boundaries

- `dot_claude/rules/` のグローバルルールは変更しない
- `chezmoi apply --dry-run` の CI 実行は対象外（CI 環境に `.chezmoi.toml` とテンプレート変数が必要なため、セットアップコストが高い）
- `.chezmoiignore` の変更は不要（`.claude/rules/` は既に除外されていない）

## Context & Research

### Relevant Code and Patterns

- `.pre-commit-config.yaml` — secretlint + shellcheck + shfmt が既に設定済み。shellcheck/shfmt は `.tmpl` ファイルを除外
- `.chezmoiscripts/` — 全スクリプトが `set -euo pipefail` を使用、hash tracking パターンで `run_onchange_` を実現
- `CLAUDE.md` — 92行、Known Pitfalls に chezmoi 固有の落とし穴が既に記載。ルール化されていない判断基準がある
- `.chezmoiignore` — `*.sh` はルートレベルで除外。`.claude/` 配下は動的ディレクトリのみ除外

### Institutional Learnings

- `docs/solutions/integration-issues/chezmoi-tmpl-shellcheck-shfmt-incompatibility.md` — `.tmpl` ファイルは shellcheck/shfmt と非互換、pre-commit で除外済み
- `docs/solutions/developer-experience/autonomous-harness-engineering-hooks-2026-03-28.md` — ハーネスエンジニアリングのフック設計に関する知見

## Key Technical Decisions

- **CI では `chezmoi apply --dry-run` を実行しない**: CI 環境でテンプレート変数（`.profile`, `.ghOrg`）を設定するコストが高く、リントで十分な検証が得られるため
- **shellcheck/shfmt は `.tmpl` ファイルを除外**: Go テンプレート構文が非互換のため（既存 pre-commit と同じポリシー）
- **ルールファイルは CLAUDE.md の Known Pitfalls と重複させない**: CLAUDE.md はコンテキスト提供、`.claude/rules/` はエージェントの判断基準に焦点

## Open Questions

### Resolved During Planning

- **Q: `.claude/rules/` は `.chezmoiignore` に追加が必要?** → 不要。現在の `.chezmoiignore` は `.claude/` 配下の特定ディレクトリのみ除外しており、`rules/` は除外対象外
- **Q: CI で pnpm のセットアップが必要?** → はい。secretlint は pnpm 経由で実行するため

### Deferred to Implementation

- なし

## Implementation Units

- [ ] **Unit 1: Add project-specific `.claude/rules/`**

  **Goal:** chezmoi リポジトリで作業するエージェント向けのプロジェクト固有ルールを追加

  **Requirements:** R1

  **Dependencies:** None

  **Files:**
  - Create: `.claude/rules/chezmoi-patterns.md`
  - Create: `.claude/rules/shell-scripts.md`

  **Approach:**
  - `chezmoi-patterns.md` — テンプレートファイルの選択基準（`.tmpl` vs `modify_` vs `create_`）、テンプレート構文の注意点、`.chezmoiignore` のグロブ挙動をエージェント判断基準として記載
  - `shell-scripts.md` — `.chezmoiscripts/` 内スクリプトの規約（`set -euo pipefail` 必須、hash tracking パターン、`.tmpl` は shellcheck 対象外など）
  - CLAUDE.md の Known Pitfalls と重複しない。Pitfalls は「何が起きるか」、rules は「どう判断するか」

  **Patterns to follow:**
  - `dot_claude/rules/common/` のルールファイル形式（見出し + コードブロック + 箇条書き）
  - `~/.claude/rules/common/harness-engineering.md` のルール記述ガイドライン

  **Test scenarios:**
  - Happy path: `chezmoi managed` でルールファイルが管理対象外であることを確認（`.chezmoiignore` で除外されず、かつプロジェクトルートの `.claude/` はデプロイ先ではない）

  **Verification:**
  - ルールファイルが `.claude/rules/` に存在する
  - 内容が具体的でアクション可能（harness-engineering.md のガイドラインに沿う）

- [ ] **Unit 2: Add Verification section to CLAUDE.md**

  **Goal:** CLAUDE.md に変更の検証手順を明記

  **Requirements:** R2

  **Dependencies:** None

  **Files:**
  - Modify: `CLAUDE.md`

  **Approach:**
  - Known Pitfalls セクションの前に `## Verification` セクションを追加
  - `chezmoi apply --dry-run`, `pnpm exec secretlint '**/*'`, shellcheck/shfmt の手動実行方法を記載
  - 簡潔に保つ（5-10行程度）

  **Patterns to follow:**
  - 既存の Common Commands セクションのフォーマット（コマンド + コメント）

  **Test scenarios:**
  - Happy path: CLAUDE.md 内に Verification セクションが存在し、検証コマンドが記載されている

  **Verification:**
  - CLAUDE.md に `## Verification` セクションが追加されている
  - コマンドが実際に実行可能

- [ ] **Unit 3: Add GitHub Actions CI workflow**

  **Goal:** PR ごとに secretlint, shellcheck, shfmt を自動実行する CI を追加

  **Requirements:** R3

  **Dependencies:** None

  **Files:**
  - Create: `.github/workflows/lint.yml`
  - Modify: `.chezmoiignore` (`.github/` を追加)

  **Approach:**
  - `.github/workflows/lint.yml` — `push` (main) と `pull_request` でトリガー
  - secretlint: pnpm install → secretlint 実行
  - shellcheck: `.sh`/`.bash` ファイルとスクリプトを対象、`.tmpl` 除外
  - shfmt: 同上のファイルを対象
  - `.chezmoiignore` に `.github/` を追加（CI ワークフローは `~/` にデプロイ不要）

  **Patterns to follow:**
  - `.pre-commit-config.yaml` の shellcheck/shfmt のファイルパターンと除外ルール
  - 既存の `.chezmoiignore` のコメント付き除外パターン

  **Test scenarios:**
  - Happy path: ワークフローファイルが正しい YAML 構文で、secretlint/shellcheck/shfmt の3ジョブが定義されている
  - Edge case: `.tmpl` ファイルが shellcheck/shfmt の対象から除外されている
  - Happy path: `.chezmoiignore` に `.github/` が追加され、`chezmoi managed` に `.github/` が含まれない

  **Verification:**
  - `.github/workflows/lint.yml` が存在し、有効な YAML
  - `.chezmoiignore` に `.github/` エントリがある

## System-Wide Impact

- **`.chezmoiignore`:** `.github/` の追加が必要。既存の除外パターンに影響なし
- **Error propagation:** CI 失敗は PR マージをブロック（設定次第）
- **Unchanged invariants:** `dot_claude/rules/` のグローバルルール、pre-commit hooks、既存の CLAUDE.md セクションは変更なし

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| shellcheck/shfmt が CI ランナーに未インストール | Ubuntu ランナーには標準搭載。明示的にインストールステップを追加 |
| CI の secretlint が pre-commit と微妙に異なる挙動 | 同じ pnpm + secretlint バージョンを使用 |

## Sources & References

- Harness health report (this session)
- `docs/solutions/integration-issues/chezmoi-tmpl-shellcheck-shfmt-incompatibility.md`
- `.pre-commit-config.yaml` — existing lint configuration
