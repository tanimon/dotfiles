---
title: "chore: orca agent-hooks を settings.json.tmpl へ反映"
type: chore
date: 2026-07-18
status: planned
---

# chore: orca agent-hooks を settings.json.tmpl へ反映

## Summary

orca が live な `~/.claude/settings.json` の 10 種類のフックイベントへ注入した agent-hook エントリを、chezmoi ソーステンプレート `dot_claude/settings.json.tmpl` に反映する。`settings.json.tmpl` は完全所有型テンプレート（`modify_` ではない）のため、次回 `chezmoi apply` でデプロイ済みファイルが上書きされ、ソースに無い orca フックは消失する。ソースへ反映することで orca フックを版管理下に置き、apply 後も存続させる。

ハードコードされた絶対パス（`~/.orca/...`）はテンプレート規約に従い `{{ .chezmoi.homeDir }}` へ置換する。

---

## Problem Frame

orca ツールが起動時に live settings.json へ自身の agent-hook を書き込んだが、chezmoi ソースには未反映。`settings.json.tmpl` は fully-owned template なので `chezmoi apply` で orca フックが失われる（CLAUDE.md「Never edit deployed targets directly」の裏返し: デプロイ先の runtime 変更は版管理されず apply で上書きされる）。

### 反映対象（orca フックのみ）

全て同一コマンドで、`~/.orca/agent-hooks/claude-hook.sh` が存在・読取・実行可能なら `/bin/sh` で実行、そうでなければ no-op（`cat >/dev/null 2>&1 || :`）する防御的スクリプト。`timeout: 10` 付き。orca 未導入マシンでも安全に no-op するため、テンプレートへ含めても他マシンに影響しない。

| フックイベント | matcher | ソースでの扱い |
|---|---|---|
| `PostToolUse` | `*` | 既存配列へ追記（3 つ目のエントリ） |
| `Stop` | (なし) | 既存配列へ追記（2 つ目のエントリ） |
| `UserPromptSubmit` | (なし) | 新規イベント（orca エントリのみ） |
| `PreToolUse` | `*` | 新規イベント |
| `PostToolUseFailure` | `*` | 新規イベント |
| `StopFailure` | (なし) | 新規イベント |
| `SubagentStart` | (なし) | 新規イベント |
| `SubagentStop` | (なし) | 新規イベント |
| `TeammateIdle` | (なし) | 新規イベント |
| `PermissionRequest` | `*` | 新規イベント |

### スコープ境界（重要）

デプロイ済み settings.json には orca フック以外にも多数の runtime ドリフトが存在する（`session-cleanup.sh` への SessionStart 差し替え、`learning-briefing.sh` の UserPromptSubmit、plugin セット差異、`sandbox.enabled:false`、`skipDangerousModePermissionPrompt`、`tui` 等）。**これらはタスク対象外**。本計画は orca agent-hook エントリのみをソースへ追加し、既存ソースの他の設定（`ask` 配列、`sandbox` 有効化、`harness-briefing.sh`、SessionEnd 等）は一切変更しない。特に `UserPromptSubmit` へは orca エントリのみを追加し、非 orca の `learning-briefing.sh` は取り込まない。

---

## Requirements

- R1: orca の agent-hook エントリを、上表 10 イベントすべてに対応する位置へ `settings.json.tmpl` の `hooks` セクションへ追加する。
- R2: コマンド内のハードコード絶対パスは `{{ .chezmoi.homeDir }}` テンプレート変数へ置換する。
- R3: 各エントリの `timeout: 10` と matcher（該当イベントのみ `*`）を live 設定と一致させる。
- R4: orca 以外の runtime ドリフトは反映しない（既存ソース設定を保持）。
- R5: `chezmoi execute-template` でテンプレートが有効な JSON にレンダリングされ、`make check-templates` が通る。

---

## Key Technical Decisions

- **KTD1: パスのテンプレート化** — live 設定の `~/.orca/agent-hooks/claude-hook.sh` を `{{ .chezmoi.homeDir }}/.orca/agent-hooks/claude-hook.sh` へ置換。理由: 他マシンへのポータビリティ確保。既存テンプレートの `HOME`・`Read(...)` 行と同じ規約（chezmoi-patterns.md「Template Syntax」）。
- **KTD2: orca フックのみを対象にする** — 大量の他ドリフトは取り込まない。理由: ユーザー指示が「orca 関連の hook」に明示限定。他ドリフト（sandbox 無効化・plugin 差異等）を取り込むと、ソースで意図的に設定した値（`sandbox.enabled:true`、`ask` gating 等）を退行させる恐れがある。
- **KTD3: 既存配列へは追記、新規イベントは新設** — `PostToolUse`/`Stop` は既存 hooks オブジェクト配列の末尾へ orca エントリを追加。他 8 イベントは新しいトップレベルキーとして `hooks` 内へ追加。理由: live 設定の構造を忠実に再現しつつ、既存の非 orca フックを壊さない。
- **KTD4: `modify_` へは変更しない** — 本タスクの範囲では `settings.json.tmpl`（fully-owned）のまま。runtime ドリフト全般の恒久対処（`modify_` 化等）は別スコープの検討事項として Deferred に記載。

---

## Implementation Units

### U1. orca agent-hook を settings.json.tmpl の hooks セクションへ追加

**Goal:** live settings.json の 10 イベントに存在する orca agent-hook エントリを、テンプレート化したパスで `dot_claude/settings.json.tmpl` の `hooks` オブジェクトへ反映する。

**Requirements:** R1, R2, R3, R4

**Dependencies:** なし

**Files:**
- `dot_claude/settings.json.tmpl` (modify) — `hooks` セクション（現状 141〜206 行付近）

**Approach:**
- 既存 `PostToolUse` 配列（`Edit|Write` と `Write` の 2 エントリ）の末尾に、matcher `*` の orca hooks オブジェクトを追記。
- 既存 `Stop` 配列（`notify-wrapper.sh` 1 エントリ）の末尾に、matcher なしの orca hooks オブジェクトを追記。
- `hooks` オブジェクト内に新規キーを追加: `UserPromptSubmit`・`PreToolUse`（matcher `*`）・`PostToolUseFailure`（matcher `*`）・`StopFailure`・`SubagentStart`・`SubagentStop`・`TeammateIdle`・`PermissionRequest`（matcher `*`）。各々 orca エントリ 1 つのみ。
- orca コマンド文字列（テンプレート化後）:
  ```
  if [ -f '{{ .chezmoi.homeDir }}/.orca/agent-hooks/claude-hook.sh' ] && [ -r '{{ .chezmoi.homeDir }}/.orca/agent-hooks/claude-hook.sh' ] && [ -x '{{ .chezmoi.homeDir }}/.orca/agent-hooks/claude-hook.sh' ]; then /bin/sh '{{ .chezmoi.homeDir }}/.orca/agent-hooks/claude-hook.sh'; else cat >/dev/null 2>&1 || :; fi
  ```
  各エントリに `"timeout": 10` を付与。
- 既存の `SessionEnd`・`Notification` 等、他フックは一切変更しない。
- 反映元 orca エントリは orca が生成したもの。何をしているか分かりにくいコマンドのため、`hooks` セクション先頭付近か各新規イベント群の直前に、テンプレートコメント（`{{/* ... */ -}}`）で「orca agent-hooks 連携。claude-hook.sh が無ければ no-op」の 1 行説明を添える（既存テンプレートが env 各行にコメントを付す慣習に倣う）。

**Patterns to follow:**
- パス置換: 既存 `"HOME": "{{ .chezmoi.homeDir }}"`（6 行目）、`Read({{ .chezmoi.homeDir }}/ghq/...)`（75 行目）。
- テンプレートコメント: 既存 `env` セクションの `{{/* ... */ -}}` 説明コメント群。
- JSON 構造: 既存 `PostToolUse`/`Stop` の hooks オブジェクト配列形状。

**Test scenarios:**
- Covers R5. `chezmoi execute-template`（テスト用 `chezmoi.toml` の `[data]` で `ghOrg`/`profile` を与え `--config <path> --source "$(pwd)"`）でレンダリングし、出力が有効な JSON であること（`jq .` が成功）。
- レンダリング後 JSON の `.hooks` に 10 イベントすべてが存在し、各 orca エントリの `command` が `{{ .chezmoi.homeDir }}` 展開後の実 home パスを含むこと。
- `.hooks.PostToolUse` が 3 エントリ（Edit|Write / Write / orca `*`）、`.hooks.Stop` が 2 エントリ（notify-wrapper / orca）であること。
- `.hooks.UserPromptSubmit` が orca エントリのみ（`learning-briefing.sh` を含まない）であること。
- 既存設定の非退行: `.permissions.ask` が存在、`.sandbox.enabled == true`、`.hooks.SessionEnd` が存在すること。
- `make check-templates` が通ること。

**Verification:**
- `make check-templates` が成功。
- `chezmoi diff` で `~/.claude/settings.json` の差分を確認し、orca フックがソース側に取り込まれた結果として live との orca 部分の差分が解消（もしくは意図通り）であること。他の runtime ドリフト差分は残存して構わない（スコープ外）。

---

## Scope Boundaries

### Deferred to Follow-Up Work

- **runtime ドリフト全般の恒久対処** — `settings.json.tmpl` が fully-owned template のため、Claude Code / orca 等が live に書き込む runtime 状態（plugin state、`session-cleanup.sh`、`learning-briefing.sh` 等）は apply の度に消える。これを保全するには `modify_dot_claude.json` と同様の `modify_` 部分管理パターンへの移行が要検討。本タスクの範囲外。
- **orca 以外のドリフト精査** — sandbox 無効化・plugin セット差異・`skipDangerousModePermissionPrompt`・`tui` などが live と source で乖離している。意図的な runtime 差異か反映漏れかの切り分けは別途。

### Out of Scope

- `~/.claude/settings.json`（デプロイ先）の直接編集（CLAUDE.md 禁止事項）。ソースのみ編集し apply で反映。

---

## Risks & Dependencies

- **低リスク**: orca コマンドは防御的（スクリプト非存在時 no-op）で、他マシンでも安全。
- **JSON 妥当性**: 手編集で末尾カンマ・括弧崩れの恐れ → `make check-templates` + `jq` で担保（Test scenarios）。
- **依存**: なし（単一ファイル編集）。
