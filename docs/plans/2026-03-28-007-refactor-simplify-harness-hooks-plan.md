---
title: "refactor: Simplify Harness Engineering Hooks to Claudeception Pattern"
type: refactor
status: completed
date: 2026-03-28
origin: docs/plans/2026-03-28-002-feat-autonomous-harness-engineering-plan.md
---

# refactor: Simplify Harness Engineering Hooks to Claudeception Pattern

## Overview

現在の harness engineering 自律実行の仕組み（4フック、2スクリプト、/tmp クロスセッション状態管理）を、claudeception パターン（1フック、1スクリプト、状態なし）に倣ってシンプル化する。bash での grep ベーストランスクリプト解析をやめ、LLM に知性を委譲する。

## Problem Frame

現在の harness engineering 自律実行は以下の構成で冗長：

| コンポーネント | 行数 | 役割 |
|---|---|---|
| `harness-check.sh` | 87行 | UserPromptSubmit: CLAUDE.md チェック + 前回フィードバック読み取り |
| `harness-feedback-collector.sh` | 111行 | Stop: transcript grep 解析 → /tmp ファイル書き出し |
| SessionStart "clear" インラインフック | — | /clear 時のフラグリセット |
| SessionStart "startup" インラインフック | — | 24h超の /tmp ファイル掃除 |

一方、claudeception は同等の「自律的な知識抽出」を**1スクリプト（39行）+ 1スキル**で実現：
- bash でパターン検出 → LLM 自身に評価を委譲
- クロスセッション状態なし → 毎セッションでリアルタイム評価
- /tmp 管理なし → フラグファイル不要

**核心の問題:** bash grep によるトランスクリプト解析は、LLM のコンテキスト内評価に比べて精度が低く、保守コストが高い。

## Requirements Trace

- R1. セッション中にハーネス改善の機会を検知し、エージェントに伝える（現状の feedback-collector + harness-check の役割を統合）
- R2. CLAUDE.md 不在時のスキャフォールド提案を維持する（初回プロンプト時のみ）
- R3. 既存の claudeception フック・notify フックと共存する
- R4. フック処理は軽量で、Claude Code のパフォーマンスに影響しない
- R5. 削除するスクリプトとフック設定を完全に撤去する（中途半端に残さない）

## Scope Boundaries

- claudeception スキル自体は変更しない（独立した仕組みとして維持）
- `/scaffold-claude-md`, `/harness-health`, `/capture-harness-feedback` コマンドは残す（手動実行用）
- harness-engineering.md ルールファイルは残す（原則ガイダンスとして有効）

## Context & Research

### Relevant Code and Patterns

- `~/.claude/skills/claudeception/scripts/claudeception-activator.sh` — 単純な `cat << 'EOF'` でプロンプトを出力するだけ。状態管理なし
- `dot_claude/settings.json.tmpl:220-237` — 現在の UserPromptSubmit フック登録
- `dot_claude/settings.json.tmpl:148-167` — SessionStart フック（clear, startup）
- `dot_claude/settings.json.tmpl:200-218` — Stop フック
- `docs/solutions/integration-issues/claude-code-hook-exit-code-and-stderr-semantics.md` — exit(0) + stdout でフィードバック表示

### Institutional Learnings

- フックの stdout は Claude Code にフィードバックとして表示される（claudeception activator が実証済み）
- `/tmp` フラグ管理は `session_id` ベースで安定だが、clear フックとの連携が必要で複雑化の原因
- bash grep によるトランスクリプト解析は誤検知/見逃しが多い（"error" 文字列の単純カウントは文脈を無視）

## Key Technical Decisions

- **LLM 委譲パターンを採用**: bash grep によるトランスクリプト解析を廃止し、claudeception と同じ「プロンプト注入 → LLM が評価」パターンを使う。理由：LLM はセッション中の全コンテキストを持っており、grep よりも正確にハーネス改善の機会を検知できる。bash は「何を見つけたか」しか伝えられないが、LLM は「なぜそれが問題か」「どう改善すべきか」まで判断できる
- **CLAUDE.md チェックはアクティベータ内に統合**: 初回プロンプトのみ実行する軽量チェック。理由：このチェックは fs 操作のみで高速、かつ即座にフィードバックが必要（セッション終了時では遅い）
- **初回プロンプト制限を維持**: claudeception は毎プロンプトで発火するが、harness activator は初回のみにする。理由：CLAUDE.md 不在メッセージが毎プロンプト出ると邪魔。ハーネス評価リマインダーもセッション初期に一度で十分（エージェントは会話全体を通じてコンテキストを保持する）
- **クロスセッションフィードバックを廃止**: /tmp ファイルによるセッション間状態伝達を削除。理由：LLM がリアルタイムで自己評価する方が高精度。過去セッションの grep 結果を次のセッションに渡すより、各セッションで LLM が直接評価する方が有効。トレードオフ：セッション横断のパターン検出能力は失われるが、各セッション内の検出精度が向上する

## Open Questions

### Resolved During Planning

- **claudeception activator と harness activator を1つに統合すべきか？**: No。claudeception は汎用的な「知識抽出」、harness は「ハーネス改善」という異なる関心事。分離を維持する
- **harness activator もスキルとして実装すべきか？**: No。claudeception はスキルファイル（SKILL.md）に評価ロジックを持つが、harness の評価ロジックは既存のコマンド群（`/harness-health`, `/capture-harness-feedback`）に委譲できる。新たなスキルファイルは不要

### Deferred to Implementation

- CLAUDE.md チェックの具体的な出力メッセージの最終調整

## Implementation Units

- [ ] **Unit 1: harness-activator.sh の作成**

**Goal:** claudeception-activator.sh と同じパターンで、ハーネス評価リマインダーと CLAUDE.md チェックを統合した単一アクティベータスクリプトを作成する

**Requirements:** R1, R2, R4

**Dependencies:** None

**Files:**
- Create: `dot_claude/scripts/executable_harness-activator.sh`
- Test: 手動テスト（`echo '{"session_id":"test"}' | bash dot_claude/scripts/executable_harness-activator.sh`）

**Approach:**
- claudeception-activator.sh をモデルに、`cat << 'EOF'` でプロンプトを stdout に出力
- CLAUDE.md 存在チェック（`git rev-parse --show-toplevel` → `test -f CLAUDE.md`）は先頭で実行
- 初回プロンプト制限は `session_id` ベースの `/tmp` フラグで実装（既存パターンを簡素化）
- フラグファイル1個のみ（フィードバックファイルなし）
- CLAUDE.md 不在時は追加メッセージを出力、存在時はハーネス評価リマインダーのみ

**Patterns to follow:**
- `~/.claude/skills/claudeception/scripts/claudeception-activator.sh` の構造と出力パターン

**Test scenarios:**
- Happy path: CLAUDE.md が存在するプロジェクトでハーネス評価リマインダーが出力される
- Happy path: CLAUDE.md が不在のプロジェクトで追加のスキャフォールド提案が出力される
- Edge case: 同一セッション内の2回目以降のプロンプトでは何も出力されない（フラグファイル）
- Edge case: ホームディレクトリや `~/.claude/` 内では何も出力されない
- Edge case: git リポジトリ外では何も出力されない
- Error path: jq が未インストールでも静かにスキップ

**Verification:**
- スクリプトが40-60行程度に収まる
- `/tmp` フラグファイルは1種類のみ（`claude-harness-checked-*`）
- フィードバックファイル（`claude-harness-feedback-*`）を使わない

---

- [ ] **Unit 2: settings.json.tmpl のフック設定を更新**

**Goal:** 旧フック（4箇所）を削除し、新アクティベータ（1箇所）に置き換える

**Requirements:** R3, R5

**Dependencies:** Unit 1

**Files:**
- Modify: `dot_claude/settings.json.tmpl`

**Approach:**
- **削除する設定:**
  - SessionStart "clear" フック（harness フラグリセット）
  - SessionStart "startup" フック（/tmp クリーンアップ）
  - Stop フックの `harness-feedback-collector.sh` エントリ
  - UserPromptSubmit の `harness-check.sh` エントリ
- **追加する設定:**
  - UserPromptSubmit に `harness-activator.sh` エントリ（既存の claudeception エントリと並列）
- SessionStart "clear" フック削除に伴い、`harness-activator.sh` 自体に `/clear` 対応は不要（activator は初回のみ発火するフラグ管理を持つが、/clear でのリセットは不要 — ハーネス評価リマインダーは一度で十分）

**Patterns to follow:**
- 既存の claudeception UserPromptSubmit フック登録パターン

**Test scenarios:**
- Happy path: `chezmoi execute-template` でテンプレートが正しく展開される
- Happy path: Stop フックに notify-wrapper.sh のみが残る
- Edge case: SessionStart に他のフックが残っていない場合、セクション自体が空にならない（JSON validity）
- Integration: `chezmoi apply --dry-run` でエラーが出ない

**Verification:**
- `settings.json.tmpl` のフックセクションが短縮される
- `harness-check.sh` と `harness-feedback-collector.sh` への参照が消える

---

- [ ] **Unit 3: 旧スクリプトの削除**

**Goal:** 不要になった旧スクリプトファイルを完全に削除する

**Requirements:** R5

**Dependencies:** Unit 2

**Files:**
- Delete: `dot_claude/scripts/executable_harness-check.sh`
- Delete: `dot_claude/scripts/executable_harness-feedback-collector.sh`

**Approach:**
- 両ファイルを `git rm` で削除
- デプロイ済みのターゲットファイル（`~/.claude/scripts/harness-check.sh` と `~/.claude/scripts/harness-feedback-collector.sh`）は `chezmoi apply` 時に chezmoi が自動的に削除する（ソースから消えたファイルは target からも消える）

**Patterns to follow:**
- chezmoi のファイル削除パターン

**Test scenarios:**
- Happy path: `chezmoi managed | grep harness` で新しいアクティベータのみが表示される
- Integration: `chezmoi apply --dry-run` で旧ファイルの削除が予告される

**Verification:**
- リポジトリに `harness-check.sh` と `harness-feedback-collector.sh` が存在しない
- `harness-activator.sh` のみが存在する

---

- [ ] **Unit 4: ドキュメント更新**

**Goal:** CLAUDE.md と関連ドキュメントから旧仕組みの記述を更新する

**Requirements:** R5

**Dependencies:** Unit 3

**Files:**
- Modify: `CLAUDE.md`（harness-feedback-collector への言及を更新）
- Modify: `docs/solutions/developer-experience/autonomous-harness-engineering-hooks-2026-03-28.md`（アーキテクチャ説明を更新）

**Approach:**
- CLAUDE.md: `/tmp` フィードバックファイルや Stop フック解析の記述を削除し、新しい activator パターンの簡潔な説明に置き換え
- ソリューションドキュメント: 旧アーキテクチャの説明末尾に「簡素化リファクタ」セクションを追加

**Test scenarios:**
- Happy path: CLAUDE.md 内に `harness-feedback-collector` や `/tmp/claude-harness-feedback-*` の記述が残っていない

**Verification:**
- `grep -r "harness-feedback-collector" .` がヒットしない
- `grep -r "harness-check\.sh" .` がヒットしない

## System-Wide Impact

- **Interaction graph:** UserPromptSubmit フックの数が2→2（harness-check を harness-activator に置換、claudeception は変更なし）。Stop フックは notify-wrapper.sh のみに。SessionStart の harness 関連フック2つが完全に消える
- **Error propagation:** 新 activator は exit(0) + stdout のみ。exit(1) によるエラーフィードバックは使わない（claudeception と同じ）
- **State lifecycle risks:** /tmp フラグファイルは1種類に削減（`claude-harness-checked-*`）。フィードバックファイルは完全に廃止
- **Unchanged invariants:** claudeception, notify, PostToolUse, secretlint フックは一切変更しない

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| クロスセッションのパターン検出能力の喪失 | LLM のリアルタイム評価がより高精度。手動で `/capture-harness-feedback` も引き続き利用可能 |
| activator の毎回出力がノイズになる | 初回プロンプトのみに制限（session_id フラグ） |
| 旧 /tmp ファイルが残存 | startup クリーンアップ削除後も OS 再起動でクリアされる。急ぎなら手動 `rm /tmp/claude-harness-*` |

## Sources & References

- **Origin plan:** [docs/plans/2026-03-28-002-feat-autonomous-harness-engineering-plan.md](docs/plans/2026-03-28-002-feat-autonomous-harness-engineering-plan.md)
- Claudeception activator: `~/.claude/skills/claudeception/scripts/claudeception-activator.sh`
- Hook semantics: `docs/solutions/integration-issues/claude-code-hook-exit-code-and-stderr-semantics.md`
- Current harness scripts: `dot_claude/scripts/executable_harness-check.sh`, `dot_claude/scripts/executable_harness-feedback-collector.sh`
