---
title: "feat: Add Makefile for local CI check execution"
type: feat
status: completed
date: 2026-03-29
---

# feat: Add Makefile for local CI check execution

## Overview

CI で実行する全チェック（secretlint, shellcheck, shfmt, modify_ スモークテスト, chezmoi テンプレート検証）をローカルで簡単に再現できるよう、Makefile を導入する。`make lint` で全チェックを一括実行でき、個別ターゲットでも実行可能にする。CLAUDE.md の Verification セクションも更新する。

## Problem Frame

現状、CI で実行される5つのチェック（secretlint, shellcheck, shfmt, modify-scripts, chezmoi-templates）をローカルで再現するには、各コマンドを個別に手動実行する必要がある。CLAUDE.md の Verification セクションには `shellcheck <script.sh>` のような個別ファイル向けコマンドしかなく、「全ファイルに対して CI と同じチェックを実行」するワンライナーがない。

## Requirements Trace

- R1. Makefile で CI 全チェックをローカル実行できる（`make lint`）
- R2. 個別チェックも個別ターゲットで実行可能（`make shellcheck`, `make shfmt` 等）
- R3. pnpm scripts にも lint エントリを追加し `pnpm run lint` でも動作
- R4. CLAUDE.md の Common Commands / Verification セクションを更新
- R5. `.chezmoiignore` に Makefile を追加（`~` にデプロイしない）
- R6. `.claude/rules/shell-scripts.md` に CI テンプレート検証ジョブの存在を記載

## Scope Boundaries

- CI ワークフロー（`.github/workflows/lint.yml`）自体は変更しない
- 新しい lint ツールの導入はしない
- Makefile のターゲットは CI のジョブと1:1対応させ、独自チェックは追加しない

## Context & Research

### Relevant Code and Patterns

- `.github/workflows/lint.yml` — CI の5ジョブ定義（secretlint, shellcheck, shfmt, modify-scripts, chezmoi-templates）
- `.pre-commit-config.yaml` — ローカル pre-commit フック（secretlint, shellcheck, shfmt）
- `package.json` — 現在 `secretlint` と `verify`（secretlint のみ実行）スクリプトあり
- `.chezmoiignore` — `package.json` 等の repo-only ファイルを除外済み

### Institutional Learnings

- `docs/solutions/developer-experience/chezmoi-project-harness-rules-and-ci-2026-03-28.md` — CI セットアップの経緯と `executable_*`, `.tmpl` 除外の重要性
- `docs/solutions/integration-issues/chezmoi-tmpl-shellcheck-shfmt-incompatibility.md` — `.tmpl` は shell lint 不可

## Key Technical Decisions

- **Makefile を主インターフェースにする**: shellcheck/shfmt はシステムツール（Node.js 外）なので pnpm scripts だけでは不自然。Makefile なら全ツールを統一的に呼べる。pnpm scripts には `lint` を追加して `make lint` に委譲する形にする
- **CI の `find` コマンドを Makefile にそのまま転用する**: CI とローカルで同じファイル発見ロジックを使い、差異を防ぐ。`find` ではなく変数で共通化し保守性を高める
- **ツール未インストール時は graceful skip**: pre-commit と同じパターンで、`command -v` チェック後に警告を出してスキップ。新規マシンの初回 apply 時に全ツールが揃っていない状況を考慮
- **chezmoi テンプレート検証はローカルでも `chezmoi execute-template` を使う**: CI と同一手法。ローカルには既に chezmoi がインストールされている前提（このリポジトリのユーザーなので）

## Open Questions

### Resolved During Planning

- **pnpm run lint vs make lint の関係**: `pnpm run lint` は `make lint` を呼ぶ薄いラッパー。エントリポイントを2つ提供することで、ユーザーの好みに対応
- **modify_ スモークテストをローカルで実行するか**: 含める。CI と同じ3テストケース（既存データ、空stdin、ソースファイル欠損）を `make test-modify` で実行

### Deferred to Implementation

- **chezmoi テンプレート検証時のダミーデータ値**: CI と同じ値を使うが、Makefile 内での具体的な記述方法は実装時に決定

## Implementation Units

- [ ] **Unit 1: Makefile を作成**

  **Goal:** CI 全チェックをローカルで再現する Makefile を作成

  **Requirements:** R1, R2

  **Dependencies:** なし

  **Files:**
  - Create: `Makefile`

  **Approach:**
  - ターゲット: `lint`（全チェック一括）, `secretlint`, `shellcheck`, `shfmt`, `test-modify`, `check-templates`
  - `SHELL_FILES` 変数で対象ファイル発見ロジックを共通化（CI の `find` と同じ条件）
  - 各ターゲットで `command -v` チェック → 未インストール時は WARNING + skip
  - `test-modify` は CI の modify-scripts ジョブと同じ3テストケースを実行
  - `check-templates` は CI の chezmoi-templates ジョブと同じロジック（テスト用 chezmoi.toml 生成 → `chezmoi execute-template`）
  - `.PHONY` 宣言

  **Patterns to follow:**
  - CI `.github/workflows/lint.yml` の各ジョブのコマンド構造
  - `.pre-commit-config.yaml` の graceful skip パターン（`command -v ... || echo "not found, skipping"`）

  **Test scenarios:**
  - Happy path: `make lint` が全チェックを順次実行し成功
  - Happy path: `make shellcheck` が shellcheck のみ実行
  - Edge case: shellcheck 未インストール時に `make shellcheck` が WARNING を出して成功終了
  - Happy path: `make test-modify` が modify_ スクリプトの3テストケースを実行
  - Happy path: `make check-templates` が全 `.tmpl` ファイルを検証

  **Verification:**
  - `make lint` が CI と同じ範囲のファイルをチェック
  - 個別ターゲットが単独で動作

- [ ] **Unit 2: package.json に lint スクリプトを追加**

  **Goal:** `pnpm run lint` でも全チェックを実行可能にする

  **Requirements:** R3

  **Dependencies:** Unit 1

  **Files:**
  - Modify: `package.json`

  **Approach:**
  - `"lint": "make lint"` を scripts に追加
  - 既存の `"verify"` は `"lint"` に統合するか、`"lint"` へのエイリアスに変更

  **Patterns to follow:**
  - 既存の `"secretlint"` スクリプトの形式

  **Test scenarios:**
  - Happy path: `pnpm run lint` が `make lint` を実行
  - Happy path: `pnpm run secretlint` が引き続き単独で動作

  **Verification:**
  - `pnpm run lint` が成功し、全チェック結果が表示される

- [ ] **Unit 3: .chezmoiignore に Makefile を追加**

  **Goal:** Makefile が `~` にデプロイされないようにする

  **Requirements:** R5

  **Dependencies:** Unit 1

  **Files:**
  - Modify: `.chezmoiignore`

  **Approach:**
  - `Makefile` を既存の repo-only ファイルセクションに追加

  **Patterns to follow:**
  - `.chezmoiignore` の既存 repo-only セクション（`package.json`, `renovate.json` 等）

  **Test scenarios:**
  - Happy path: `chezmoi managed | grep Makefile` が空（管理対象外）

  **Verification:**
  - `chezmoi managed` に Makefile が含まれない

- [ ] **Unit 4: CLAUDE.md と shell-scripts.md を更新**

  **Goal:** ドキュメントにローカル実行手順を反映し、CI テンプレート検証の存在も明記

  **Requirements:** R4, R6

  **Dependencies:** Unit 1

  **Files:**
  - Modify: `CLAUDE.md`
  - Modify: `.claude/rules/shell-scripts.md`

  **Approach:**
  - CLAUDE.md Common Commands に `make lint` を追加
  - CLAUDE.md Verification セクションに `make lint`（全チェック一括）と個別ターゲットの説明を追加
  - `.claude/rules/shell-scripts.md` の CI Enforcement セクションに chezmoi テンプレート検証ジョブの存在を1行追記

  **Patterns to follow:**
  - CLAUDE.md の既存コマンド記載スタイル（`コマンド  # コメント`）
  - shell-scripts.md の既存 CI Enforcement セクション構造

  **Test scenarios:**
  - Happy path: CLAUDE.md に `make lint` が記載されている
  - Happy path: shell-scripts.md に chezmoi テンプレート検証の記載がある

  **Verification:**
  - ドキュメントの更新が事実と一致（Makefile のターゲット名、CI ジョブ名）

## System-Wide Impact

- **エージェント行動**: `make lint` という明確なエントリポイントにより、コード変更後の検証が容易に
- **CI との整合性**: Makefile のチェックが CI と同一ロジックなので、ローカルで通れば CI も通る
- **pre-commit との関係**: pre-commit は commit 時に自動実行、Makefile は任意タイミングで手動実行。補完関係

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Makefile と CI の `find` ロジックが乖離する | CI 変更時に Makefile も更新するルールを CLAUDE.md に記載検討 |
| `make` が未インストール（Windows等） | このリポジトリは macOS 向け、make は Xcode CLT に含まれる |

## Sources & References

- CI 定義: `.github/workflows/lint.yml`
- Pre-commit: `.pre-commit-config.yaml`
- 既存スクリプト: `package.json`
- 過去の解決策: `docs/solutions/developer-experience/chezmoi-project-harness-rules-and-ci-2026-03-28.md`
