---
title: "chore: Sync node/pnpm versions between local and CI"
type: feat
status: completed
date: 2026-03-29
---

# chore: Sync node/pnpm versions between local and CI

## Overview

node と pnpm のバージョンを local（mise）と CI（GitHub Actions）で可能な限り統一し、バージョンドリフトを防止する。node は `.node-version` を単一ソースとする。pnpm は mise が `packageManager` を読めない制約上、`package.json` と `config.toml` の二箇所で exact version を固定する（`"latest"` による確実なドリフトを解消）。

## Problem Frame

現在、node と pnpm のバージョンが複数箇所に散在している:
- **Local**: `dot_config/mise/config.toml` (`node = "24"`, `pnpm = "latest"`)
- **CI**: `.github/workflows/lint.yml` (`node-version: "24"`, `version: 10`)

`pnpm = "latest"` は pnpm 11 リリース時に CI（pnpm 10固定）と不整合になり、`pnpm-lock.yaml` の lockfileVersion 互換性問題を引き起こす。node は両方 `"24"` だがメンテ箇所が二重。

## Requirements Trace

- R1. node バージョンの単一ソース: `.node-version` ファイルを local と CI 両方が参照する
- R2. pnpm バージョンの環境ごとの固定: CI は `package.json` `packageManager` を参照、ローカルは `config.toml` で同一バージョンを固定（mise が `packageManager` を読めないため二箇所管理だが、`"latest"` による確実なドリフトを exact version 固定で大幅に軽減）
- R3. Renovate がバージョン更新を自動提案できる（`packageManager` と `.node-version` は自動、`config.toml` は Renovate mise マネージャー対応次第）
- R4. 既存の `chezmoi apply` / `make lint` ワークフローが壊れない

## Scope Boundaries

- corepack の有効化は行わない（mise の pnpm 管理と競合するため）
- `.node-version` は repo-only ファイルとし、`~/` にはデプロイしない
- 他のワークフロー（claude.yml, claude-code-review.yml, harness-analysis.yml）は node/pnpm を使わないため変更不要

## Context & Research

### Relevant Code and Patterns

- `dot_config/mise/config.toml`: mise グローバル設定、`idiomatic_version_file_enable_tools = ["node"]` で `.node-version` 自動読み取りが有効済み
- `.github/workflows/lint.yml`: secretlint ジョブのみ node/pnpm を使用
- `package.json`: `packageManager` フィールド未設定
- `.chezmoiignore`: `package.json`, `Makefile` 等の repo-only ファイルは既に除外パターンあり
- `renovate.json`: `config:recommended` 拡張済み。Renovate の `nodenv` マネージャーが `.node-version` を、`npm` マネージャーが `packageManager` を検出する

### Institutional Learnings

- `docs/solutions/integration-issues/renovate-managerfilepatterns-regex-delimiter.md`: Renovate が mise 依存を検出済みと記載。`config.toml` 内の pnpm バージョン固定も Renovate の mise マネージャーが検出する可能性あり

## Key Technical Decisions

- **`.node-version` を repo root に配置**: CI の `actions/setup-node` が `node-version-file` で読み取り、mise も `idiomatic_version_file_enable_tools` で読み取る。`.chezmoiignore` に追加して `~/` へのデプロイを防ぐ。理由: 両環境が同一ファイルを参照する最もシンプルな方法
- **`package.json` に `packageManager` フィールドを追加**: `pnpm/action-setup` が `version` input 省略時にこのフィールドを読む。理由: npm エコシステムの標準的な pnpm バージョン固定方法
- **`config.toml` の `pnpm = "latest"` を exact version に変更**: `"latest"` はメジャーバージョンジャンプのリスクがある。`packageManager` と同一バージョンを明示する。理由: mise は `packageManager` を読まないため、ローカルでの pnpm バージョンは config.toml で制御する必要がある
- **`config.toml` の `node = "24"` は維持**: グローバルフォールバックとして残す。このリポジトリ内では `.node-version` が優先される。理由: このリポジトリ外での node 利用に影響しない
- **corepack は使わない**: mise が pnpm を直接管理しており、corepack を有効にすると全 Node プロジェクトの挙動が変わる。理由: blast radius が大きすぎる

## Open Questions

### Resolved During Planning

- **`.node-version` の chezmoi 管理**: repo-only ファイルとして `.chezmoiignore` に追加。`package.json` と同じパターン
- **corepack の要否**: 不要。`pnpm/action-setup` は `packageManager` を直接読む。mise はローカルで pnpm を管理する
- **Renovate の `.node-version` 対応**: Renovate の `nodenv` マネージャーが `.node-version` を自動検出する（`config:recommended` に含まれる）

### Deferred to Implementation

- **Renovate が `dot_config/mise/config.toml` の pnpm バージョンを更新できるか**: mise マネージャーのファイルパス検出が `dot_` プレフィックス付きで動作するか要確認。動作しない場合は `packageManager` 更新 PR 時に手動で合わせる運用とする

## Implementation Units

- [ ] **Unit 1: `.node-version` ファイル作成と `.chezmoiignore` 追加**

**Goal:** node バージョンの単一ソースとなる `.node-version` を作成し、chezmoi が `~/` にデプロイしないよう除外する

**Requirements:** R1, R4

**Dependencies:** None

**Files:**
- Create: `.node-version`
- Modify: `.chezmoiignore`

**Approach:**
- `.node-version` に `24` を記載（mise の現在設定と同じメジャーバージョン指定）
- `.chezmoiignore` の repo-only ファイルセクションに `.node-version` を追加

**Patterns to follow:**
- `.chezmoiignore` 内の `package.json` エントリと同じパターン

**Test scenarios:**
- Happy path: `chezmoi managed | grep node-version` が空（デプロイ対象外）
- Happy path: `.node-version` の内容が `24` であること

**Verification:**
- `chezmoi managed` に `.node-version` が含まれないこと

- [ ] **Unit 2: `package.json` に `packageManager` フィールド追加**

**Goal:** pnpm バージョンの単一ソースとなる `packageManager` フィールドを追加する

**Requirements:** R2, R3

**Dependencies:** None

**Files:**
- Modify: `package.json`

**Approach:**
- `"packageManager": "pnpm@10.28.0"` を追加。現在ローカルで使用中のバージョンに合わせる
- `pnpm-lock.yaml` の lockfileVersion `9.0` との互換性は pnpm 10.x で問題なし

**Patterns to follow:**
- npm エコシステムの標準 `packageManager` フィールド仕様

**Test scenarios:**
- Happy path: `pnpm install --frozen-lockfile` が成功すること
- Edge case: `packageManager` のバージョンとローカル pnpm バージョンが一致していること

**Verification:**
- `package.json` に `packageManager` フィールドが存在し、正しい pnpm バージョンが記載されていること

- [ ] **Unit 3: mise `config.toml` の pnpm バージョン固定**

**Goal:** ローカルの pnpm バージョンを `packageManager` と一致させ、`"latest"` によるドリフトを防止する

**Requirements:** R2

**Dependencies:** Unit 2（`packageManager` のバージョンと一致させるため）

**Files:**
- Modify: `dot_config/mise/config.toml`

**Approach:**
- `pnpm = "latest"` を `pnpm = "10.28.0"` に変更
- Renovate の mise マネージャーがこのファイルを検出するか実装時に確認

**Test scenarios:**
- Happy path: `chezmoi apply --dry-run` でエラーが出ないこと
- Happy path: `mise ls` で pnpm バージョンが `10.28.0` と表示されること

**Verification:**
- `config.toml` の pnpm が exact version で固定されていること

- [ ] **Unit 4: CI ワークフローを単一ソース参照に更新**

**Goal:** `lint.yml` が `.node-version` と `packageManager` からバージョンを読み取るよう変更する

**Requirements:** R1, R2, R4

**Dependencies:** Unit 1, Unit 2

**Files:**
- Modify: `.github/workflows/lint.yml`

**Approach:**
- `pnpm/action-setup` から `version: 10` を削除（`packageManager` から自動読み取り）
- `actions/setup-node` の `node-version: "24"` を `node-version-file: '.node-version'` に変更（明示的な指定が暗黙的な自動検出より安全）

**Patterns to follow:**
- `pnpm/action-setup` ドキュメント: `version` 省略時に `packageManager` を読む
- `actions/setup-node` ドキュメント: `node-version-file` input

**Test scenarios:**
- Happy path: CI lint ワークフローが全ジョブ成功すること
- Integration: `pnpm install --frozen-lockfile` が CI で成功すること（バージョン一致の証明）
- Error path: `.node-version` や `packageManager` が存在しない場合のフォールバック動作は確認不要（常に存在する前提）

**Verification:**
- `lint.yml` に hardcoded バージョン（`node-version: "24"`, `version: 10`）が残っていないこと
- PR の CI が全ジョブ green であること

## System-Wide Impact

- **Interaction graph:** `pnpm/action-setup` が `package.json` の `packageManager` を読む新しい依存関係。`actions/setup-node` が `.node-version` を読む新しい依存関係
- **Error propagation:** `packageManager` のバージョンが不正な場合、CI の `pnpm/action-setup` がエラーで失敗する（サイレント失敗ではない）
- **Unchanged invariants:** `make lint`、`chezmoi apply`、他の CI ワークフローの動作は変わらない

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Renovate が `dot_config/mise/config.toml` の pnpm を更新できない | `packageManager` と手動同期する運用。将来的に Renovate の `managerFilePatterns` で対応可能 |
| `pnpm/action-setup` が `packageManager` を正しく読めない | PR の CI で即座に検証される |
| `.node-version` の追加で他の chezmoi managed ファイルに影響 | `.chezmoiignore` に追加済みで影響なし |

## Sources & References

- `pnpm/action-setup` README: `version` 省略時の `packageManager` 自動検出
- `actions/setup-node` README: `node-version-file` input
- Renovate `nodenv` manager: `.node-version` 自動検出
- mise documentation: `idiomatic_version_file_enable_tools`
