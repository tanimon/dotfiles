---
title: "feat: Improve harness health from 82 to 90+"
type: feat
status: completed
date: 2026-03-28
---

# feat: Improve harness health from 82 to 90+

## Overview

ハーネスヘルス診断で発見された3つの改善ポイントを対応し、エージェントの生産性を向上させる。プロジェクトルールに具体的なファイル参照を追加し、CI にテンプレート検証を追加し、ルールと CI の関係を明示する。

## Problem Frame

harness-health 診断で Score 82/100。主な減点要因:
1. プロジェクトルール（`.claude/rules/`）が実リポジトリファイルを参照していない → エージェントが具体例を見つけにくい
2. CI に chezmoi テンプレート検証がない → テンプレート構文エラーがマージ後に発覚
3. shell-scripts.md が CI 強制を明記していない → ルールが「お願い」に見える

## Requirements Trace

- R1. `.claude/rules/chezmoi-patterns.md` が各パターンの実例ファイルパスを含む
- R2. `.claude/rules/shell-scripts.md` が CI 強制の関係を明記する
- R3. `.github/workflows/lint.yml` に chezmoi テンプレート検証ジョブを追加
- R4. `package.json` に統合 verify スクリプトを追加

## Scope Boundaries

- グローバルルール (`~/.claude/rules/`) は変更しない
- CLAUDE.md の構造的変更はしない（既に十分な品質）
- テストフレームワーク導入はしない（dotfiles リポジトリにはオーバーキル）

## Context & Research

### Relevant Code and Patterns

- `.claude/rules/chezmoi-patterns.md` — 現在パターン説明のみ、実例なし
- `.claude/rules/shell-scripts.md` — CI との関係記載なし
- `.github/workflows/lint.yml` — secretlint, shellcheck, shfmt の3ジョブ
- `modify_dot_claude.json` — modify_ パターンの好例
- `.chezmoiscripts/run_onchange_darwin-install-packages.sh.tmpl` — run_onchange_ パターンの好例
- `dot_config/zsh/sandbox.zsh` — .tmpl でないシェルスクリプトの好例（shellcheck/shfmt 対象）

### Institutional Learnings

- `docs/solutions/integration-issues/chezmoi-tmpl-shellcheck-shfmt-incompatibility.md` — .tmpl と shell lint の非互換性は既知
- `docs/solutions/integration-issues/chezmoi-full-template-drift.md` — テンプレートドリフトの問題は既知

## Key Technical Decisions

- **chezmoi テンプレート検証は `chezmoi execute-template` を使う**: `chezmoi apply --dry-run` はターゲットマシン依存（`.chezmoi.toml` が必要）で CI では動かない。`execute-template` なら個別テンプレートの構文チェックが可能。ただし Go テンプレート内のカスタム関数（`include`, `joinPath` 等）は chezmoi バイナリなしでは検証不可なので、CI では chezmoi をインストールして `chezmoi execute-template` を使う
- **verify スクリプトはシェルスクリプトにしない**: `package.json` の `scripts` に追加。pnpm は既にプロジェクトの依存管理ツール

## Open Questions

### Resolved During Planning

- **CI で chezmoi をどうインストールするか**: `curl -sfL get.chezmoi.io | sh` で `/usr/local/bin` にインストール（公式推奨方法）
- **テンプレート検証の範囲**: `.tmpl` ファイルのみ。Go テンプレート構文エラーの検出が目的

### Deferred to Implementation

- **テンプレート検証で使用するダミーデータ**: `chezmoi execute-template` に渡すテスト用変数の具体値は実装時に決定

## Implementation Units

- [ ] **Unit 1: chezmoi-patterns.md に実例ファイル参照を追加**

  **Goal:** 各パターン説明に、リポジトリ内の具体的な実装例へのパスを追加

  **Requirements:** R1

  **Dependencies:** なし

  **Files:**
  - Modify: `.claude/rules/chezmoi-patterns.md`

  **Approach:**
  - File Type Selection テーブルの各行に `→ see <path>` 形式で実例を追加
  - `.tmpl`: `dot_config/starship.toml.tmpl` など
  - `create_`: リポジトリ内の create_ ファイルを検索して使用
  - `modify_`: `modify_dot_claude.json`
  - `.chezmoiignore` + `run_onchange_`: `.chezmoiscripts/run_onchange_after_add-marketplaces.sh.tmpl`
  - Declarative Sync Pattern セクションにも `scripts/update-marketplaces.sh` と `dot_claude/plugins/marketplaces.txt` を参照として追加

  **Patterns to follow:**
  - CLAUDE.md の Key Patterns セクションが同様の具体参照スタイルを使用

  **Test scenarios:**
  - Happy path: 各パターンに少なくとも1つの実在ファイルパスが参照されている
  - Edge case: 参照先ファイルが実際にリポジトリに存在することを確認

  **Verification:**
  - ルール内の全ファイルパスが `ls` で存在確認できる

- [ ] **Unit 2: shell-scripts.md に CI 強制の関係を明記**

  **Goal:** シェルスクリプトルールが CI で強制されていることを明示し、ルールの権威性を高める

  **Requirements:** R2

  **Dependencies:** なし

  **Files:**
  - Modify: `.claude/rules/shell-scripts.md`

  **Approach:**
  - 「CI Enforcement」セクションを追加
  - `.github/workflows/lint.yml` が shellcheck と shfmt を CI で実行していることを明記
  - `.pre-commit-config.yaml` がローカルでも同じチェックを実行することを明記
  - `.tmpl` ファイルが両方から除外されている理由を簡潔に記載

  **Patterns to follow:**
  - 既存のセクション構造（見出し + 箇条書き）を踏襲

  **Test scenarios:**
  - Happy path: CI ワークフローファイルへの参照が正確
  - Happy path: pre-commit 設定への参照が正確

  **Verification:**
  - 参照されている CI ファイルパスが実在する

- [ ] **Unit 3: CI に chezmoi テンプレート検証ジョブを追加**

  **Goal:** `.tmpl` ファイルの Go テンプレート構文エラーを CI で検出

  **Requirements:** R3

  **Dependencies:** なし

  **Files:**
  - Modify: `.github/workflows/lint.yml`

  **Approach:**
  - `chezmoi-templates` ジョブを追加
  - chezmoi を公式インストールスクリプトでインストール
  - `find` で `.tmpl` ファイルを列挙し、`chezmoi execute-template` で構文検証
  - テンプレート変数（`.chezmoi.homeDir`, `.profile`, `.ghOrg`）にはダミー値を渡す
  - chezmoi の `--init` + `--promptString` でデータを注入、または `chezmoi.toml` をテスト用に配置

  **Patterns to follow:**
  - 既存の shellcheck/shfmt ジョブの構造（ubuntu-latest, actions/checkout@v4）

  **Test scenarios:**
  - Happy path: 正常なテンプレートファイルが検証を通過
  - Error path: 構文エラーのあるテンプレートで CI が失敗
  - Edge case: テンプレート変数を使用するファイルがダミーデータで正常にレンダリング

  **Verification:**
  - CI ワークフローが構文的に正しい YAML
  - 既存の `.tmpl` ファイルがすべて検証を通過

- [ ] **Unit 4: package.json に統合 verify スクリプトを追加**

  **Goal:** 全検証を単一コマンドで実行可能にする

  **Requirements:** R4

  **Dependencies:** なし

  **Files:**
  - Modify: `package.json`

  **Approach:**
  - `"verify"` スクリプトを追加: secretlint 実行
  - shellcheck と shfmt はシステムツールなので pnpm スクリプトには含めず、CLAUDE.md の Verification セクションで `pnpm run verify` として案内

  **Patterns to follow:**
  - 既存の `"secretlint"` スクリプトの書式

  **Test scenarios:**
  - Happy path: `pnpm run verify` が secretlint を実行
  - Error path: シークレットが含まれるファイルで失敗

  **Verification:**
  - `pnpm run verify` が正常に実行される

## System-Wide Impact

- **CI パイプライン**: 新しい chezmoi-templates ジョブが追加され、ビルド時間が若干増加
- **エージェント行動**: ルールに具体例が追加されることで、エージェントが正しいパターンを選択しやすくなる
- **既存の CI ジョブ**: 変更なし

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| chezmoi execute-template がテンプレート関数（include等）を解決できない | chezmoi バイナリをインストールし、ソースディレクトリを指定して実行 |
| テンプレート変数のダミー値が不十分 | `.chezmoi.toml.tmpl` から必要な変数を抽出してテスト用設定を生成 |

## Sources & References

- 既存 CI: `.github/workflows/lint.yml`
- 既存ルール: `.claude/rules/chezmoi-patterns.md`, `.claude/rules/shell-scripts.md`
- chezmoi テンプレートドリフト: `docs/solutions/integration-issues/chezmoi-full-template-drift.md`
