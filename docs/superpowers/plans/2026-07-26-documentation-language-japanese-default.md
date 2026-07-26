# Documentation Language Japanese Default Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite `dot_claude/rules/common/documentation-language.md` so its default policy is Japanese instead of English, per the approved spec.

**Architecture:** Single markdown rule file, full content replacement. No code, no tests — this is a documentation-only change confined to one file with content already fully specified in the spec.

**Tech Stack:** Markdown, chezmoi-managed dotfiles repo.

## Global Constraints

- New file content must match the spec's "New File Content" section verbatim (spec: `docs/superpowers/specs/2026-07-26-documentation-language-japanese-default-design.md`).
- The `date:` frontmatter field stays `2026-03-29` (unchanged), matching the no-date-bump convention already used by `harness-engineering.md` and `github-actions.md`.
- This is the one exception to "no bulk translation of existing files" — only this single file is rewritten; no other existing English doc in the repo is touched.
- `make lint` (specifically `secretlint` and `scan-sensitive`) must pass after the change, mirroring CI.

---

### Task 1: Rewrite documentation-language.md to Japanese default

**Files:**
- Modify: `dot_claude/rules/common/documentation-language.md` (full replacement)

**Interfaces:**
- Consumes: nothing (no other task).
- Produces: nothing consumed by later tasks — this plan has a single task.

- [ ] **Step 1: Replace the file content**

Overwrite the entire content of `dot_claude/rules/common/documentation-language.md` with exactly this:

```markdown
---
date: 2026-03-29
trigger: "エージェントが、明示的な英語指示や外部フォーマット制約なしに新規ドキュメントを英語で書いた"
---

# ドキュメントの言語

## 新規ドキュメントは日本語で記載する

新規作成時は以下を日本語で記載する:

- `CLAUDE.md` / `AGENTS.md` — プロジェクト指示
- `.claude/rules/**/*.md` — ルールファイル
- `docs/solutions/**/*.md` — 解決策ドキュメント
- コードコメント
- コミットメッセージ

既存の英語ドキュメントに新規項目を追記・編集する場合も、追記部分は日本語で記載する（ファイル全体の一括翻訳は行わない。1ファイル内で英語と日本語が混在する状態を許容する）。

**理由:** これらのドキュメントは最終的に人間（日本語話者）が読むもの。最新のLLM（Sonnet 5など）は日本語も十分な精度で扱えるため、英語で書くことによる解釈精度上のメリットは小さく、人間の可読性を優先すべき。

**例外（英語での記載を許容する場合）:**

- **明示的に英語での記載を指示された場合** — その指示に従い英語で記載する
- **Skillなどの出力フォーマットでセクション名や構造が英語で指定されている場合** — 指定された構造部分（セクション名、フロントマターのキー名、Conventional Commitsの `feat:`/`fix:` などのtype等）はそのまま英語を使う。本文の言語について特に指定がなければ、本文は日本語で記載する
```

- [ ] **Step 2: Verify the file matches exactly**

Run: `cat dot_claude/rules/common/documentation-language.md`
Expected: Output matches the block in Step 1 character-for-character, including the frontmatter.

- [ ] **Step 3: Confirm no other files changed**

Run: `git status --short`
Expected: Only `dot_claude/rules/common/documentation-language.md` shows as modified. No other file (e.g. `CLAUDE.md`, other rule files) appears — this change is scoped to the one file per the spec's "Out of Scope" section.

- [ ] **Step 4: Run lint checks**

Run: `make secretlint && make scan-sensitive`
Expected: Both report `Passed`. (Full `make lint` also works but these two are the only targets relevant to a markdown-only, non-`.tmpl` file — `shellcheck`/`shfmt`/`oxlint`/`oxfmt`/`actionlint`/`zizmor`/`check-templates` all skip with "no files to check" for this diff.)

- [ ] **Step 5: Commit**

```bash
git add dot_claude/rules/common/documentation-language.md
git commit -m "$(cat <<'EOF'
docs: flip documentation-language rule to Japanese default

New agent-facing docs (CLAUDE.md/AGENTS.md, rules, docs/solutions, code
comments, commit messages) default to Japanese now that current LLMs
handle it accurately, prioritizing human readability. English remains
allowed when explicitly requested or when an external format (e.g. a
skill's section names, Conventional Commits types) requires it.
Existing English docs are not bulk-translated.
EOF
)"
```
