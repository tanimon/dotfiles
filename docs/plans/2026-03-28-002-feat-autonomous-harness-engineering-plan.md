---
title: "feat: Autonomous Harness Engineering Process"
type: feat
status: completed
date: 2026-03-28
origin: docs/plans/2026-03-28-001-feat-cross-project-harness-engineering-plan.md
---

# feat: Autonomous Harness Engineering Process

## Overview

前回のイテレーションで作成した手動ハーネスコマンド群（`/scaffold-claude-md`, `/capture-harness-feedback`, `/harness-health`, `/scaffold-project-rules`）を、Claude Codeのフックシステムを活用して自律的に駆動する仕組みを構築する。

## Problem Frame

現在のハーネスエンジニアリングは完全に手動プロセスに依存している：
1. ユーザーが明示的に `/capture-harness-feedback` を呼ばなければ、失敗パターンは記録されない
2. 新規プロジェクトでCLAUDE.mdが不在でも自動提案されない
3. セッション終了時に学びを振り返る仕組みがない
4. ハーネスの健全性が定期的にチェックされない

ハーネスエンジニアリングの核心原則は「失敗するたびに、その失敗を二度と起こさないよう仕組みを工学的に解決する」こと。この原則自体を自動化する必要がある。

## Requirements Trace

- R1. セッション終了時に、問題行動があればハーネス改善提案をstderrフィードバックとして返す
- R2. CLAUDE.mdが存在しないプロジェクトで作業開始時に、自動的にスキャフォールド提案する
- R3. 既存のフックパターン（notify-wrapper.sh, claudeception-activator.sh）と整合する
- R4. フック処理は軽量で、Claude Codeのパフォーマンスに影響しない
- R5. フックの失敗がClaude Codeセッションをブロックしない

## Scope Boundaries

- LLMを使ったリアルタイム分析は行わない（フックはシェルスクリプトで静的チェックのみ）
- フック内でファイル変更は行わない（提案のみ）
- 既存のclaudeception skillとの重複を避ける（claudeceptionは汎用学習抽出、本機能はハーネス改善に特化した軽量チェック）

## Context & Research

### Relevant Code and Patterns

- `dot_claude/scripts/executable_notify-wrapper.sh` — /tmp キャッシュパターン、Seatbelt対応
- `dot_claude/scripts/executable_notify.mts` — stdinからJSON入力を読み取るフックスクリプトパターン
- `dot_claude/settings.json.tmpl` — hooks セクション構造
- `docs/solutions/integration-issues/claude-code-hook-exit-code-and-stderr-semantics.md` — exit(0)=スキップ, exit(1)+stderr=フィードバック

### Institutional Learnings

- フックのstderrは Claude Code にフィードバックとして表示される（exit 1時）
- フックのstdout は無視される
- Seatbelt下では `$HOME` 内のNode.jsスクリプトがrealpathSync EPERMで失敗する → /tmpキャッシュで回避

## Key Technical Decisions

- **Stopフック + シェルスクリプトで実装**: Node.js/TypeScriptではなくbashで軽量に。理由：フックは高速である必要があり、Node.jsの起動コストを避ける。静的チェック（ファイル存在確認、パターンマッチ）にはbashで十分
- **stderrフィードバックで自律提案**: フックがexit(1) + stderrで改善提案を返す。理由：Claude Codeがフィードバックとしてエージェントに伝え、エージェントが自律的に対応できる
- **UserPromptSubmitフックでプロジェクトチェック**: セッション開始時の最初のプロンプト送信時にCLAUDE.mdの存在チェック。理由：Stopフックではなく入力時にチェックすることで、作業開始前に提案できる
- **冪等なチェック**: 同一セッション内で同じ提案を繰り返さないよう一時ファイルでフラグ管理。理由：毎回のプロンプトで同じ提案が出ると邪魔

## Open Questions

### Resolved During Planning

- **Stopフックでのハーネスフィードバックは可能か？**: Yes。ただしexit(1)を返すとClaude Codeに「エラー」として表示される。セッション終了時に改善提案を「表示するだけ」にするにはexit(0) + stdoutは不可（無視される）。代替: Stopフックでファイルに書き出し、次のセッション開始時にUserPromptSubmitフックで読み取り・表示する
- **フック内でClaude Codeのトランスクリプトを読めるか？**: Yes。Stopフックの入力JSONに`transcript_path`が含まれる（notify.mtsで実証済み）

### Deferred to Implementation

- **トランスクリプト解析の具体的な失敗パターン検出ロジック**: 実際のトランスクリプト構造をテストしながら決定

## Implementation Units

- [x] **Unit 1: プロジェクトハーネスチェック（UserPromptSubmitフック）**

**Goal:** セッションの最初のプロンプト送信時に、プロジェクトのCLAUDE.mdの有無をチェックし、不在なら`/scaffold-claude-md`の利用を提案する

**Requirements:** R2, R3, R4, R5

**Dependencies:** None

**Files:**
- Create: `dot_claude/scripts/executable_harness-check.sh`
- Modify: `dot_claude/settings.json.tmpl`

**Approach:**
- UserPromptSubmitフックとして追加
- `$PWD` でプロジェクトルートを検出し、`CLAUDE.md`の存在をチェック
- 一時ファイル（`/tmp/claude-harness-checked-$$`）でセッション内の重複提案を防止
- CLAUDE.mdが不在の場合、stderrに提案メッセージを出力し、exit(2)（非ブロッキング）で終了
- exit code のセマンティクス: exit(0)=成功/スキップ, exit(2)=非ブロッキングフィードバック

**Patterns to follow:**
- `dot_claude/scripts/executable_notify-wrapper.sh` のスクリプトパターン
- `docs/solutions/integration-issues/claude-code-hook-exit-code-and-stderr-semantics.md`

**Test scenarios:**
- Happy path: CLAUDE.mdが存在するプロジェクトでは何も出力せずexit(0)
- Happy path: CLAUDE.mdが不在のプロジェクトでは提案メッセージをstderrに出力
- Edge case: 同一セッション内で2回目以降のプロンプトではチェックをスキップ
- Edge case: ホームディレクトリ直下や`~/.claude/`内では実行しない

**Verification:**
- フックが設定され、CLAUDE.mdのないディレクトリでClaude Codeを起動すると提案が表示される

---

- [x] **Unit 2: セッション終了時のハーネスフィードバック収集（Stopフック）**

**Goal:** セッション終了時にトランスクリプトを軽量解析し、エージェントのエラーパターンや改善ポイントを次のセッション用のフィードバックファイルに書き出す

**Requirements:** R1, R3, R4, R5

**Dependencies:** None

**Files:**
- Create: `dot_claude/scripts/executable_harness-feedback-collector.sh`
- Modify: `dot_claude/settings.json.tmpl`

**Approach:**
- Stopフックとして追加（既存のnotifyフックと並列）
- stdinからJSON入力を読み取り、`transcript_path`を取得（notify.mtsと同じパターン）
- トランスクリプトの最後のN行を`tail`で読み取り、軽量なパターンマッチで以下を検出：
  - ツール実行の繰り返し失敗（同じコマンドが3回以上失敗）
  - ファイルの頻繁な書き換え（同じファイルへの5回以上のEdit/Write）
  - エラーメッセージの連続（"error", "failed", "EPERM"等のパターン）
- 検出結果をプロジェクト固有の一時ファイル（`/tmp/claude-harness-feedback-<project-hash>.md`）に書き出す
- 次のセッション開始時にUnit 1のUserPromptSubmitフックが読み取って提案

**Patterns to follow:**
- `dot_claude/scripts/executable_notify.mts` のトランスクリプト読み取りパターン（ただしbash実装）
- `executable_notify-wrapper.sh` のエラーハンドリング

**Test scenarios:**
- Happy path: 正常なセッション終了ではフィードバックファイルが空か生成されない
- Happy path: 繰り返しエラーがあるセッションでは具体的なフィードバックが記録される
- Edge case: トランスクリプトが存在しない場合、静かにexit(0)
- Edge case: トランスクリプトが巨大な場合でも末尾のみ読み取り、パフォーマンスに影響しない
- Error path: jqが利用できない場合、grepフォールバックで最低限の解析

**Verification:**
- エラーが多いセッション後にフィードバックファイルが生成される
- 次のセッション開始時にフィードバックが表示される

---

- [x] **Unit 3: フィードバックループの結合（Unit 1 + Unit 2の連携）**

**Goal:** Unit 2で収集したフィードバックをUnit 1のUserPromptSubmitフックが読み取り、次のセッション開始時に改善提案として表示する仕組みを結合する

**Requirements:** R1, R2, R3

**Dependencies:** Unit 1, Unit 2

**Files:**
- Modify: `dot_claude/scripts/executable_harness-check.sh`

**Approach:**
- Unit 1のharness-check.shを拡張し、CLAUDE.mdチェックに加えて以下を実行：
  - `/tmp/claude-harness-feedback-<project-hash>.md` の存在チェック
  - 存在すればフィードバック内容をstderrに出力し、ファイルを削除（一度だけ表示）
- プロジェクトハッシュは `echo "$PWD" | md5` で生成

**Patterns to follow:**
- 既存のUnit 1スクリプトパターン

**Test scenarios:**
- Happy path: 前セッションのフィードバックファイルが存在する場合、内容がstderrに出力され、ファイルが削除される
- Happy path: フィードバックファイルが存在しない場合、CLAUDE.mdチェックのみ実行
- Edge case: フィードバックファイルが空の場合、何も表示しない

**Verification:**
- エラーの多いセッション→終了→新セッション開始の流れで、フィードバックが自動的に表示される

## System-Wide Impact

- **Interaction graph:** UserPromptSubmitフックは全プロンプト送信時に実行される。軽量チェック（ファイル存在確認のみ）で影響最小化。Stopフックは既存のnotifyフックと並列実行。
- **Error propagation:** 全フックは `|| true` でラップし、失敗時もClaude Codeをブロックしない。stderrフィードバックは exit(2) の非ブロッキングステータスを使用。
- **State lifecycle risks:** /tmpのフィードバックファイルはOS再起動で消失するが、これは意図的（古いフィードバックは不要）
- **Unchanged invariants:** 既存のNotification, PostToolUse, Stop（notify）, UserPromptSubmit（claudeception）フックは変更しない

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| UserPromptSubmitフックの遅延がユーザー体験を損なう | ファイル存在チェック1回のみ、50ms以内に完了 |
| トランスクリプト解析で誤検知（正常な繰り返しをエラーと判定） | 保守的な閾値（3回以上の失敗、5回以上の書き換え）と具体的パターンマッチ |
| /tmpファイルの衝突（複数セッション） | プロジェクトハッシュ + PIDでファイル名を一意化 |
| Seatbelt下でのスクリプト実行制限 | bashスクリプトはNode.jsと違いrealpathSync問題がない。/tmpへのアクセスは許可されている |

## Sources & References

- Related code: `dot_claude/settings.json.tmpl`, `dot_claude/scripts/executable_notify.mts`
- Related solutions: `docs/solutions/integration-issues/claude-code-hook-exit-code-and-stderr-semantics.md`
- Origin: `docs/plans/2026-03-28-001-feat-cross-project-harness-engineering-plan.md`
