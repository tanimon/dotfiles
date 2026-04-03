---
title: "feat: Close harness health documentation gaps"
type: feat
status: completed
date: 2026-03-29
---

# feat: Close harness health documentation gaps

## Overview

harness-health 診断 (Score 88/100) で発見された3つのドキュメント・設定ギャップを埋め、agent の生産性を向上させる。

## Problem Frame

Score 88 の減点要因:
1. ローカルでの modify_ スモークテスト手順が CLAUDE.md に未記載 → agent がローカル検証方法を知らない
2. `.chezmoiexternal.toml` の Renovate 契約ルールが CLAUDE.md に埋まっており、`.claude/rules/` に分離されていない → ルールの発見性が低い
3. `docs/solutions/` の存在と用途が CLAUDE.md に未記載 → agent が過去の解決記録を参照しない

## Requirements Trace

- R1. CLAUDE.md の Verification セクションにローカル modify_ テスト手順を追加
- R2. Renovate 契約ルールを `.claude/rules/renovate-external.md` に分離し、CLAUDE.md からは簡潔な参照に置換
- R3. CLAUDE.md に `docs/solutions/` への導線を追加

## Scope Boundaries

- CLAUDE.md の構造的リライトはしない
- グローバルルール (`~/.claude/rules/`) は変更しない
- 新しい CI ジョブは追加しない

## Context & Research

### Relevant Code and Patterns

- `CLAUDE.md` — 108行、既に充実。Verification セクション (L84-89) と Architecture > `.chezmoiexternal.toml` (L62-66) が対象
- `.chezmoiexternal.toml` — Renovate 契約: `url`, `# renovate: branch=`, `ref` の隣接順序制約
- `.claude/rules/shell-scripts.md` — 既存ルールのフォーマット参考（セクション構成、CI 相互参照スタイル）
- `docs/solutions/` — 3カテゴリ（`developer-experience`, `integration-issues`, `runtime-errors`）に25件以上

### Institutional Learnings

- `docs/solutions/integration-issues/chezmoi-external-script-repo-with-renovate-sha-pinning.md` — Renovate + `.chezmoiexternal.toml` の連携パターンが記録済み

## Key Technical Decisions

- **Renovate ルールは `.claude/rules/renovate-external.md` に分離**: CLAUDE.md の Architecture セクションは概要説明に留め、詳細な制約ルールは `.claude/rules/` に置くのが harness engineering のベストプラクティス
- **CLAUDE.md からは Renovate 契約の詳細を削除せず簡潔化**: 完全削除すると CLAUDE.md だけ読む agent に情報が届かない。概要1行 + ルールファイルへの参照に置換

## Open Questions

### Resolved During Planning

- **modify_ テストのコマンド例は何か**: CI の `modify-scripts` ジョブ（`.github/workflows/lint.yml` L58-82）と同等のコマンド
- **docs/solutions/ の導線はどこに追加するか**: CLAUDE.md の Architecture セクション（Directory Layout テーブル付近）が最適

### Deferred to Implementation

- なし

## Implementation Units

- [ ] **Unit 1: CLAUDE.md に modify_ ローカルテスト手順を追加**

  **Goal:** Verification セクションにローカルで modify_ スクリプトをテストするコマンド例を追加

  **Requirements:** R1

  **Dependencies:** なし

  **Files:**
  - Modify: `CLAUDE.md`

  **Approach:**
  - Verification セクションの既存コマンド群の後に modify_ テスト例を追加
  - CI の `modify-scripts` ジョブと同等のコマンドをローカル用に簡略化
  - `CHEZMOI_SOURCE_DIR="$(pwd)"` の設定が必要なことを明記

  **Patterns to follow:**
  - 既存の Verification セクションのコマンド + コメント形式

  **Test scenarios:**
  - Happy path: 追加されたコマンドがコピペで実行可能
  - Happy path: コマンドの出力が valid JSON

  **Verification:**
  - 追加したコマンドを実際に実行して動作確認

- [ ] **Unit 2: Renovate 契約ルールを `.claude/rules/` に分離**

  **Goal:** `.chezmoiexternal.toml` の Renovate 連携ルールを独立ルールファイルに切り出し、CLAUDE.md を簡潔化

  **Requirements:** R2

  **Dependencies:** なし

  **Files:**
  - Create: `.claude/rules/renovate-external.md`
  - Modify: `CLAUDE.md`

  **Approach:**
  - `.claude/rules/renovate-external.md` に Renovate 契約の詳細を記載: `url`/`# renovate: branch=`/`ref` の隣接制約、新規エントリ追加時のチェックリスト
  - CLAUDE.md の `.chezmoiexternal.toml` セクションから Renovate 契約の詳細段落を削除し、概要1行 + `→ see .claude/rules/renovate-external.md` に置換
  - `.chezmoiexternal.toml` の実ファイルを参照例として含める

  **Patterns to follow:**
  - `.claude/rules/shell-scripts.md` のフォーマット（見出し構成、CI 相互参照スタイル）
  - `.claude/rules/chezmoi-patterns.md` の実例参照パターン

  **Test scenarios:**
  - Happy path: ルールファイルが `.chezmoiexternal.toml` の実際の構造と一致
  - Happy path: CLAUDE.md から削除した情報がルールファイルに移行されている

  **Verification:**
  - ルールファイル内の制約が `.chezmoiexternal.toml` の実態と一致
  - CLAUDE.md に Renovate 契約の重複記載がない

- [ ] **Unit 3: CLAUDE.md に docs/solutions/ への導線を追加**

  **Goal:** agent が過去の解決記録を発見・参照できるよう、CLAUDE.md に docs/solutions/ の説明を追加

  **Requirements:** R3

  **Dependencies:** なし

  **Files:**
  - Modify: `CLAUDE.md`

  **Approach:**
  - Architecture > Directory Layout テーブルに `docs/solutions/` エントリを追加
  - Known Pitfalls セクションの直前に1行の案内を追加: 「類似の問題に遭遇したら `docs/solutions/` を検索」

  **Patterns to follow:**
  - 既存の Directory Layout テーブルの行形式

  **Test scenarios:**
  - Happy path: Directory Layout テーブルに `docs/solutions/` 行がある
  - Happy path: 案内文が CLAUDE.md 内に存在する

  **Verification:**
  - `docs/solutions/` ディレクトリが実在し、記載内容と一致

## System-Wide Impact

- **Agent 行動**: CLAUDE.md と `.claude/rules/` の改善により、agent が modify_ テスト、Renovate 契約遵守、過去の解決記録参照をより確実に行える
- **既存 CI**: 変更なし
- **CLAUDE.md 行数**: 微増（+5行程度）、200行以下を維持

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| CLAUDE.md が長くなりすぎる | Renovate 詳細をルールに移すことで相殺。最終行数を確認 |

## Sources & References

- harness-health 診断結果（本セッション）
- 既存 CI: `.github/workflows/lint.yml` L53-82 (modify-scripts ジョブ)
- 既存 Renovate 設定: `renovate.json`, `.chezmoiexternal.toml`
- 過去プラン: `docs/plans/2026-03-28-005-feat-harness-health-improvements-plan.md` (completed)
