---
title: "feat: Add /ce:compound reminder to harness activator"
type: feat
status: completed
date: 2026-03-29
---

# feat: Add /ce:compound reminder to harness activator

## Overview

`dot_claude/scripts/executable_harness-activator.sh` のセッション終了時リマインダーに `/ce:compound` の実行指示を追加する。現在のリマインダーはハーネス改善（CLAUDE.md ルール、`/capture-harness-feedback`、`docs/solutions/`）のみ言及しているが、セッション中に解決した問題の知識をドキュメント化する `/ce:compound` への誘導が欠けている。

## Problem Frame

harness-activator.sh は各セッションの最初のプロンプトで「セッション完了後にハーネス改善を評価せよ」というリマインダーを表示する claudeception パターンのフック。現状、`docs/solutions/` への手動記録は言及しているが、構造化されたソリューション文書を自動生成する `/ce:compound` スキルへの誘導がない。結果として、解決した問題の知識が失われやすい。

## Requirements Trace

- R1. リマインダーのテキストに `/ce:compound` の実行条件と目的を追記する
- R2. 既存のリマインダー項目（1-3）の構造と一貫性を保つ
- R3. スクリプトのロジック（session flag、context guards 等）は変更しない

## Scope Boundaries

- スクリプトの bash ロジックは変更しない（heredoc 内のテキストのみ）
- `/ce:compound` スキル自体の修正は対象外
- 他のフックスクリプトは対象外

## Context & Research

### Relevant Code and Patterns

- `dot_claude/scripts/executable_harness-activator.sh` — 対象ファイル。heredoc (line 48-68) 内のリマインダーテキストを編集
- 既存のリマインダー項目は「条件 → アクション」のフォーマット（例: "Did X? → Run Y"）

### Institutional Learnings

- `docs/solutions/developer-experience/autonomous-harness-engineering-hooks-2026-03-28.md` — claudeception パターンの設計根拠。LLM に判断を委任する方針

## Key Technical Decisions

- **既存の項目3を修正する**: 現在の項目3「Was significant debugging or investigation required? → docs/solutions/」は `/ce:compound` の実行条件とほぼ同じ。この項目を `/ce:compound` に誘導するよう書き換え、手動での `docs/solutions/` 記録から構造化スキルへの移行を促す
  - 理由: 項目を追加するより既存項目を進化させる方が自然で、リマインダーが長くなりすぎない

## Implementation Units

- [ ] **Unit 1: リマインダーテキストの更新**

**Goal:** heredoc 内のリマインダー項目3を `/ce:compound` への誘導に書き換える

**Requirements:** R1, R2, R3

**Dependencies:** なし

**Files:**
- Modify: `dot_claude/scripts/executable_harness-activator.sh`

**Approach:**
- heredoc (line 48-68) 内の項目3のテキストを編集
- 条件文は「セッション中に非自明な問題を解決した」ことを問う形にする
- アクションは `/ce:compound` の実行を指示
- 既存の「条件 → アクション」フォーマットを維持

**Patterns to follow:**
- 同ファイル内の項目1, 2 のフォーマット（番号 + 条件質問 + `→` + アクション指示）

**Test scenarios:**
- Happy path: `chezmoi apply` 後、新セッションでリマインダーに `/ce:compound` への言及が含まれること
- Edge case: 既存の項目1, 2 が変更されていないこと

**Verification:**
- スクリプトの出力に `/ce:compound` が含まれる
- `shellcheck` がパスする（ただし非 `.tmpl` なので既に CI 対象）
- 既存のセッションフラグ/ガードロジックが変更されていないことを diff で確認

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| リマインダーが冗長になる | 項目追加ではなく既存項目の書き換えで対応 |

## Sources & References

- 対象ファイル: `dot_claude/scripts/executable_harness-activator.sh`
- ce:compound スキル: `~/.claude/plugins/marketplaces/compound-engineering-plugin/plugins/compound-engineering/skills/ce-compound/SKILL.md`
