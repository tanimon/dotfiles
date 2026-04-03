---
title: "fix: Use stdin session_id for stable per-session hook flags"
type: fix
status: completed
date: 2026-03-28
---

# fix: Use stdin session_id for stable per-session hook flags

## Overview

`harness-check.sh` の per-session フラグ機構が壊れている。`$PPID` を session ID として使用しているが、hook は `bash -c` ラッパー経由で毎回新しいプロセスとして実行されるため、PPID が毎回異なる値になる。Claude Code は stdin JSON に安定した `session_id` を提供しているので、これを使うよう修正する。

## Problem Frame

- `harness-check.sh` は「セッション中1回だけチェック」のために `/tmp/claude-harness-checked-<ID>` フラグファイルを使用
- `${CLAUDE_SESSION_ID:-$PPID}` をキーとして使用しているが、`CLAUDE_SESSION_ID` 環境変数は Claude Code では提供されない
- フォールバックの `$PPID` は `bash -c` ラッパーの PID（毎回一意）になる
- 結果: フラグが毎回新規作成され、「1回だけ実行」が「毎回実行」になる
- 副作用: `/tmp` に stale なフラグファイルが蓄積（1日で31個）
- SessionStart(clear) hook も同じ問題で、正しいフラグを削除できない

## Requirements Trace

- R1. harness-check.sh が同一セッション内で1回だけ実行される
- R2. `/clear` 後にフラグがリセットされ、次のプロンプトで再チェックが走る
- R3. stale なフラグファイルが無制限に蓄積しない
- R4. フィードバックファイルの読み取り・削除が確実に動作する

## Scope Boundaries

- harness-feedback-collector.sh は変更しない（project-keyed で正常動作中）
- hook の機能追加や新しいチェック項目の追加はしない
- notify 系 hook は対象外

## Context & Research

### Relevant Code and Patterns

- `dot_claude/settings.json.tmpl:148-229` — hook 設定（SessionStart, UserPromptSubmit）
- `~/.claude/scripts/harness-check.sh` — デプロイ済みスクリプト（chezmoi 非管理）
- `~/.claude/scripts/harness-feedback-collector.sh` — 正常動作中の参考実装（stdin JSON を `grep` で解析）

### Institutional Learnings

- `docs/solutions/integration-issues/claude-code-hook-exit-code-and-stderr-semantics.md` — exit 0 で skip、exit 1 + stderr でエラー
- `docs/solutions/developer-experience/autonomous-harness-engineering-hooks-2026-03-28.md` — 現在のアーキテクチャの設計意図

### Key Finding: session_id は stdin JSON に含まれる

Claude Code の全 hook は stdin に JSON を渡す。`session_id` フィールドはセッション内で安定しており、per-session 識別子として使用できる。`harness-feedback-collector.sh` は既に stdin JSON を `grep` で解析するパターンを使用している。

## Key Technical Decisions

- **jq ではなく grep で JSON 解析**: harness-feedback-collector.sh と同じパターン。jq 依存を避け、新規マシンでのブートストラップ時にも動作する
- **SessionStart clear hook をスクリプトファイルに切り出さない**: session_id を grep で取得する1行コマンドで十分。インライン bash -c で対応
- **stale ファイルのクリーンアップは SessionStart startup で実施**: 新セッション開始時に古いフラグファイルを掃除する

## Open Questions

### Resolved During Planning

- **Q: /clear は session_id を変えるか？** → 変えない（同一プロセス）。SessionStart(clear) hook でフラグ削除が必要
- **Q: stdin を読むと他の hook に影響するか？** → しない。各 hook は独立した stdin パイプを受け取る

### Deferred to Implementation

- **Q: session_id の正確なフォーマット（UUID等）** → 実装時に確認。grep パターンは汎用的に設計する

## Implementation Units

- [ ] **Unit 1: harness-check.sh で stdin session_id を使用**

**Goal:** フラグファイルのキーを $PPID から stdin JSON の session_id に変更

**Requirements:** R1, R4

**Dependencies:** None

**Files:**
- Modify: `~/.claude/scripts/harness-check.sh`

**Approach:**
- スクリプト冒頭で stdin JSON を読み取り、`session_id` を grep で抽出
- `harness-feedback-collector.sh:20-21` の既存パターンに倣う: `INPUT=$(cat)`, `grep -o '"session_id"...'`
- session_id 取得失敗時は `exit 0`（非ブロッキング skip）
- フラグファイル名: `/tmp/claude-harness-checked-<session_id>`
- `CLAUDE_SESSION_ID` 環境変数フォールバックは削除（存在しないため）

**Patterns to follow:**
- `harness-feedback-collector.sh:19-21` — stdin JSON の grep 解析パターン

**Test scenarios:**
- Happy path: session_id が正常に取得され、初回はチェック実行、2回目以降はフラグ存在で skip
- Edge case: stdin が空または不正 JSON → exit 0 で skip
- Integration: /clear 後にフラグが削除され、次のプロンプトでチェックが再実行される

**Verification:**
- 同一セッションで2回目のプロンプトを送信してもハーネスチェックメッセージが表示されない
- フラグファイル名に session_id が使われている

- [ ] **Unit 2: SessionStart(clear) hook で stdin session_id を使用**

**Goal:** /clear 時に正しいフラグファイルを削除する

**Requirements:** R2

**Dependencies:** Unit 1（フラグファイルの命名規則が一致する必要がある）

**Files:**
- Modify: `dot_claude/settings.json.tmpl` (SessionStart hook)

**Approach:**
- インライン `bash -c` コマンドで stdin JSON から session_id を grep 抽出
- 抽出した session_id でフラグファイルを削除
- パターン: `bash -c 'SID=$(cat | grep -o "\"session_id\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed "s/.*\"session_id\"[[:space:]]*:[[:space:]]*\"//;s/\"$//"); [ -n "$SID" ] && rm -f "/tmp/claude-harness-checked-$SID" || true'`

**Patterns to follow:**
- 既存の inline hook command パターン（settings.json.tmpl:155-156）

**Test scenarios:**
- Happy path: /clear 実行後、フラグファイルが削除される
- Edge case: session_id 取得失敗 → || true で静かに skip

**Verification:**
- /clear → 次のプロンプトでハーネスチェックが再実行される

- [ ] **Unit 3: SessionStart(startup) でstale フラグファイルをクリーンアップ**

**Goal:** /tmp の stale フラグファイル蓄積を防止

**Requirements:** R3

**Dependencies:** Unit 1（フラグファイルの命名規則）

**Files:**
- Modify: `dot_claude/settings.json.tmpl` (SessionStart hook に startup matcher 追加)

**Approach:**
- `matcher: "startup"` で新しい SessionStart hook エントリを追加
- 24時間以上古いフラグファイルを削除: `find /tmp -name 'claude-harness-checked-*' -mtime +0 -delete`
- フィードバックファイルも同様にクリーンアップ: `find /tmp -name 'claude-harness-feedback-*' -mtime +0 -delete`

**Patterns to follow:**
- 既存の SessionStart hook エントリ構造（settings.json.tmpl:149-158）

**Test scenarios:**
- Happy path: 新セッション起動時に24時間超のフラグファイルが削除される
- Edge case: /tmp にフラグファイルがない → find が何もしない

**Verification:**
- 新セッション起動後、古いフラグファイルが残っていない

- [ ] **Unit 4: ドキュメント・メモリ更新**

**Goal:** 修正内容をドキュメントとメモリに反映

**Requirements:** 全体

**Dependencies:** Unit 1-3

**Files:**
- Modify: `docs/solutions/developer-experience/autonomous-harness-engineering-hooks-2026-03-28.md`
- Modify: memory file `claude_code_hook_events.md`

**Approach:**
- solutions ドキュメントの Prevention セクションを更新: `$PPID` ではなく stdin JSON の `session_id` を使う
- メモリの「$PPID for session flags」を「stdin JSON の session_id for session flags」に修正

**Verification:**
- ドキュメントが現在の実装と一致している

## System-Wide Impact

- **Interaction graph:** SessionStart(clear) と UserPromptSubmit(harness-check) が同じフラグファイル命名規則を共有する必要がある。session_id の grep パターンは両方で一致させること
- **Error propagation:** 全 hook は `|| true` で保護済み。session_id 取得失敗時は skip（exit 0）
- **State lifecycle risks:** /tmp フラグファイルは再起動で自動クリーンアップ。SessionStart(startup) hook で24時間超のファイルも削除
- **Unchanged invariants:** harness-feedback-collector.sh（Stop hook）は project-keyed で独立しており変更不要

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| session_id の JSON フィールド名や形式が変わる | grep パターンを汎用的に設計。取得失敗時は exit 0 で graceful skip |
| /clear が session_id を変更する場合がある | Unit 2 で session_id ベースの削除を行うので、変わっても変わらなくても正しく動作する |
| find -mtime +0 の粒度が荒い（24時間単位） | 十分。フラグファイルは小さく、数十個残っても問題ない |

## Sources & References

- Claude Code hook documentation (claude-code-guide agent による確認)
- `docs/solutions/developer-experience/autonomous-harness-engineering-hooks-2026-03-28.md`
- `docs/solutions/integration-issues/claude-code-hook-exit-code-and-stderr-semantics.md`
- Memory: `claude_code_hook_events.md`
