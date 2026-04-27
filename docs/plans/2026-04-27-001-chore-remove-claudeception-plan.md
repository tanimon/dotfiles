---
title: "chore: Remove claudeception skill from chezmoi"
type: chore
status: active
date: 2026-04-27
---

# chore: Remove claudeception skill from chezmoi

## Overview

ユーザーが claudeception スキルを利用しなくなったため、chezmoi 管理対象から除去する。`.chezmoiexternal.toml` のアーカイブ取得設定、`settings.json.tmpl` の `UserPromptSubmit` フック、関連ドキュメント参照、`compound-harness-knowledge` スキル内の抽出評価ステップを取り除き、`chezmoi apply` 後に `~/.claude/skills/claudeception/` が自然に削除されるようにする。

---

## Problem Frame

`~/.claude/skills/claudeception/` は `.chezmoiexternal.toml` で外部アーカイブとして取り込まれ、毎プロンプトで `claudeception-activator.sh` が `UserPromptSubmit` フックとして実行されている。利用しなくなった以上、以下の不利益が残る:

- 不要な weekly archive refresh (168h refreshPeriod) と Renovate アップデート PR
- すべてのプロンプトで実行される無駄なフック処理（起動オーバーヘッド・ログ汚染）
- ドキュメント・スキル定義に残る誤誘導 (compound-harness-knowledge が claudeception を提案する)

---

## Requirements Trace

- R1. `.chezmoiexternal.toml` から claudeception エントリを削除し、Renovate adjacency contract を残存エントリで保つ。
- R2. `dot_claude/settings.json.tmpl` の `UserPromptSubmit` から `claudeception-activator.sh` を呼ぶフックエントリを削除し、JSON テンプレート構文を健全に保つ。
- R3. `CLAUDE.md` および `.claude/rules/renovate-external.md` の参照記述から Claudeception 言及を除去する。
- R4. `dot_claude/skills/compound-harness-knowledge/SKILL.md` から Claudeception 抽出評価ステップを削除し、description と output 記述を整合させる。
- R5. `chezmoi apply` 後に `~/.claude/skills/claudeception/` が削除され、`make lint` および `make check-templates` がグリーンであること。

---

## Scope Boundaries

- 履歴ドキュメント (`docs/brainstorms/*`, `docs/solutions/*`) は変更しない。これらは過去時点の記録であり、リライトしないのがリポジトリの慣習。
- `renovate.json` の regex custom manager 設定は変更しない。エントリ削除のみで Renovate は対象を見失うだけで挙動は壊れない。
- `compound-harness-knowledge` スキル全体の役割やワークフロー再設計は対象外。Step 3 のみを除去する最小変更にとどめる。

---

## Context & Research

### Relevant Code and Patterns

- `.chezmoiexternal.toml` — `type = "archive"` + `# renovate: branch=...` adjacency contract に従ったブロック構造。残存エントリ (`gstack`, `cco`) と同形式。
- `dot_claude/settings.json.tmpl:203-220` — `UserPromptSubmit` フック。同セクション内に `learning-briefing.sh` を呼ぶ別エントリがあり、こちらは保持する。
- `dot_claude/skills/compound-harness-knowledge/SKILL.md` — `description`, `Step 3`, `Output` の3カ所が claudeception に関連。
- `docs/brainstorms/2026-04-04-session-start-learning-injection-requirements.md:67` — 過去文書での参照。**変更しない**（履歴の整合性を優先）。
- `docs/solutions/...` — 過去の解決ドキュメント。**変更しない**。

### Institutional Learnings

- `.claude/rules/renovate-external.md` — `url` と `# renovate:` 行の隣接性が壊れると Renovate のサイレント失敗につながる。エントリ削除では残存エントリの adjacency が保たれていればよい。
- `CLAUDE.md` の "modify_ scripts: empty stdout = target deletion" 警告の対象は `modify_*` スクリプトで、本変更とは無関係。
- chezmoi が外部アーカイブで配置したファイルは、`.chezmoiexternal.toml` からエントリを除去すれば次回 `chezmoi apply` で削除される（管理外になるため）。

### External References

- 利用なし (リポジトリ内の既存パターンに従う変更のみ)。

---

## Key Technical Decisions

- **削除のみで完結させる**: `compound-harness-knowledge` の Step 3 は claudeception 依存のため、ステップごと除去する。後続ステップ番号の振り直しは不要 (Step 3 は末尾)。
- **history は触らない**: `docs/brainstorms`, `docs/solutions` 内の Claudeception 言及は意図的にそのまま残す。当時の意思決定履歴であり、削除すると過去のコンテキストが失われる。
- **Renovate 設定は無変更**: `renovate.json` の custom manager は `.chezmoiexternal.toml` を regex で走査するだけで、対象が無くなれば自動的に何も検出しない。設定を弄ると残存エントリの adjacency 検証が壊れる恐れがあるため触らない。

---

## Open Questions

### Resolved During Planning

- 履歴ドキュメントの扱い: 変更しない（リポジトリ慣習）。
- compound-harness-knowledge SKILL.md の Step 3 完全削除か、別代替記述への置換か: **完全削除**。代替案 (`Skill(continuous-learning-v2)` 等) を提案する根拠が無いため、最小差分にとどめる。

### Deferred to Implementation

- なし。

---

## Implementation Units

- U1. **`.chezmoiexternal.toml` から claudeception エントリ削除**

**Goal:** Claudeception アーカイブの取得を停止する。

**Requirements:** R1, R5

**Dependencies:** なし

**Files:**
- Modify: `.chezmoiexternal.toml`

**Approach:**
- `[".claude/skills/claudeception"]` ブロック (6 行: `[…]`, `type`, `url`, `# renovate:`, `stripComponents`, `refreshPeriod`) を丸ごと削除し、ブロック後の空行も整える。
- 残存する `[".claude/skills/gstack"]` と `[".local/share/cco"]` の `url` / `# renovate:` 隣接が崩れていないことを確認。

**Patterns to follow:**
- `.claude/rules/renovate-external.md` の adjacency contract。

**Test scenarios:**
- Test expectation: none -- 純粋な設定削除。コード経路に分岐なし。`make check-templates` で TOML 構文と chezmoi テンプレート全体の妥当性が確認される。

**Verification:**
- `grep -i claudeception .chezmoiexternal.toml` がヒット 0。
- `chezmoi apply --dry-run` がエラー無く完了し、claudeception ディレクトリ削除が予告される。

---

- U2. **`dot_claude/settings.json.tmpl` から claudeception フック削除**

**Goal:** プロンプト送信ごとに走るフックの呼び出しを止める。

**Requirements:** R2, R5

**Dependencies:** U1 (順序依存ではなくレビューしやすさのため)

**Files:**
- Modify: `dot_claude/settings.json.tmpl`

**Approach:**
- `UserPromptSubmit` 配列内の、`hooks` -> `command: "$HOME/.claude/skills/claudeception/scripts/claudeception-activator.sh"` を含むオブジェクト (208 行付近のブロック) を削除する。
- 同セクションに残る `learning-briefing.sh` フックエントリは保持する。
- JSON 配列のカンマ整合性を維持し、`UserPromptSubmit` 配列要素が 1 個になる形に調整。
- `make check-templates` で chezmoi テンプレートが render 可能なことを確認する。

**Patterns to follow:**
- 同ファイル内の他のフックエントリの削除パターン（既存テンプレートの素朴な配列要素削除）。
- `CLAUDE.md` の "Inline hook commands: keep simple or use jq" 注記（編集後に複雑化させない）。

**Test scenarios:**
- Test expectation: none -- 設定削除のみ。`make check-templates` が template render を検証する。

**Verification:**
- `grep -i claudeception dot_claude/settings.json.tmpl` がヒット 0。
- `make check-templates` がパスし、テンプレート展開後に有効な JSON が生成される。
- `chezmoi apply` 後、`jq '.hooks.UserPromptSubmit | length' ~/.claude/settings.json` が learning-briefing のみを反映した値になる。

---

- U3. **ドキュメント参照の更新**

**Goal:** 残存ドキュメントから Claudeception 言及を除去し、誤誘導を防ぐ。

**Requirements:** R3

**Dependencies:** なし

**Files:**
- Modify: `CLAUDE.md`
- Modify: `.claude/rules/renovate-external.md`

**Approach:**
- `CLAUDE.md` の `.chezmoiexternal.toml` 説明 (97 行付近): "Claudeception skill, gstack skills, cco" → "gstack skills, cco" に更新。
- `.claude/rules/renovate-external.md` の "Existing Entries" 段落 (34 行): "(Claudeception skill, cco)" → "(gstack skills, cco)" に更新（残存エントリの記述に合わせる）。
- `docs/brainstorms/`, `docs/solutions/` は履歴文書として変更しない。

**Patterns to follow:**
- 既存の同種記述パターン (リスト列挙)。

**Test scenarios:**
- Test expectation: none -- ドキュメント更新のみ。`make scan-sensitive` で機密文字列混入が無いことを確認。

**Verification:**
- 上記 2 ファイルから "Claudeception" / "claudeception" が消えていること。
- `make lint` がグリーン。

---

- U4. **`compound-harness-knowledge` スキルから Claudeception 抽出評価を削除**

**Goal:** スキル本体から claudeception 依存の Step 3 を除去し、description と output を整合させる。

**Requirements:** R4

**Dependencies:** なし

**Files:**
- Modify: `dot_claude/skills/compound-harness-knowledge/SKILL.md`

**Approach:**
- frontmatter `description` から "Adds harness failure classification and Claudeception skill extraction evaluation," 部分を "Adds harness failure classification," に更新。
- 本文 `## Step 3: Evaluate Claudeception Skill Extraction` セクション全体（コードブロックと最後の `Then invoke Skill(claudeception)...` 段落含む）を削除。
- `## Output` の項目 2 「Skill extraction recommendation (if applicable)」を削除し、項目 1 のみに整理。
- `version` フィールドは現状維持（マイナーな表現削除のみで挙動に変化なしのため bump 不要）。

**Patterns to follow:**
- 同 frontmatter / セクション構造を保つ。

**Test scenarios:**
- Test expectation: none -- ドキュメント形式のスキル定義のみ。実行コードの追加・削除はない。

**Verification:**
- `grep -i claudeception dot_claude/skills/compound-harness-knowledge/SKILL.md` がヒット 0。
- frontmatter が依然有効 YAML として読める（前後の `---` を維持）。
- `make lint` がグリーン。

---

- U5. **検証: lint・テンプレート・apply ドライラン**

**Goal:** 変更全体を統合検証し、CI 失敗ポイントを潰す。

**Requirements:** R5

**Dependencies:** U1, U2, U3, U4

**Files:**
- なし（既存スクリプトの実行のみ）

**Approach:**
- `make lint` を実行し、secretlint・shellcheck・shfmt・oxlint・oxfmt・actionlint・zizmor・modify テスト・script テスト・テンプレート・sensitive スキャンが全パスすることを確認。
- `chezmoi apply --dry-run` で削除予告 (`~/.claude/skills/claudeception` の除去) を確認。
- `chezmoi apply` を実行し、実体ディレクトリが消えていることを `ls ~/.claude/skills/claudeception` で確認 (No such file or directory が期待挙動)。
- ローカルセッションで Claude Code を再起動し `UserPromptSubmit` で claudeception-activator が呼ばれないこと（プロセス・ログ・エラー無し）を簡易確認。

**Patterns to follow:**
- `CLAUDE.md` "Verification" セクションの make ターゲット呼び出しパターン。

**Test scenarios:**
- Test expectation: none -- 既存テストの再走および手動確認のみ。

**Verification:**
- `make lint` 全グリーン。
- `chezmoi apply` 後、`ls ~/.claude/skills/claudeception` が ENOENT。
- `git grep -i claudeception -- ':!docs/brainstorms' ':!docs/solutions' ':!docs/plans/2026-04-27-001-*'` がヒット 0。

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| `settings.json.tmpl` の JSON 配列カンマを誤って残し、テンプレート展開後の JSON が壊れる | `make check-templates` で render 検証。`jq . ~/.claude/settings.json` で apply 後の構文も追加確認 |
| Renovate の adjacency contract を残存エントリで誤って壊す | 削除はブロック単位で行い、残存 (`gstack`, `cco`) の `url` / `# renovate:` 隣接性を grep で確認 |
| `chezmoi apply` 時に Claudeception 配下のローカル変更（あれば）が失われる | 配下は外部アーカイブで管理されており、ユーザの編集を想定していない。ローカル変更が無いことを `ls ~/.claude/skills/claudeception` で事前確認 |
| compound-harness-knowledge スキルのワークフローが利用者の習慣と衝突する | 削除は末尾の Step 3 のみ。Step 1/2 と Output 項目 1 はそのまま残るため、上流呼び出しは破綻しない |

---

## Documentation / Operational Notes

- 履歴ドキュメント (`docs/brainstorms`, `docs/solutions`) は当時のコンテキストとして残す。将来「なぜ消えたのか」を追う場合はこの計画ドキュメントを参照点とする。
- 今後 claudeception 系スキルを再導入する場合、`.chezmoiexternal.toml` への再追加と `settings.json.tmpl` のフック復活、および `compound-harness-knowledge` の評価ステップ復活が必要。

---

## Sources & References

- `.chezmoiexternal.toml`
- `dot_claude/settings.json.tmpl`
- `CLAUDE.md`
- `.claude/rules/renovate-external.md`
- `dot_claude/skills/compound-harness-knowledge/SKILL.md`
