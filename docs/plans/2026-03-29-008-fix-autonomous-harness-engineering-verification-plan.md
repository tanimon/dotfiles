---
title: "fix: Autonomous Harness Engineering Verification and Remediation"
type: fix
status: completed
date: 2026-03-29
origin: docs/plans/2026-03-28-002-feat-autonomous-harness-engineering-plan.md
---

# fix: Autonomous Harness Engineering Verification and Remediation

## Overview

自立駆動ハーネスエンジニアリングの全コンポーネントを検証し、CI が検出した 8 件の未対応 issue を修正する。

## Problem Frame

2026-03-28 に構築した自立駆動ハーネスシステムは基本的に稼働しているが、直近の CI harness analysis（weekly + manual）で 8 件の issue が起票されており、シェルスクリプト規約違反・デッドコード・テストカバレッジ不足・ドキュメントの乖離が存在する。これらを放置するとハーネス自体の信頼性が低下する。

## Requirements Trace

- R1. CI harness-analysis で検出された全 8 issue (#72-#79) を解消する
- R2. `make lint` がローカルで PASS すること
- R3. 既存のフック動作（harness-activator, notify, claudeception）を壊さない
- R4. CLAUDE.md・ルールドキュメントが現在のリポジトリ状態と一致する

## Scope Boundaries

- harness-activator.sh のロジック変更は行わない（動作検証済み）
- 新機能追加はしない（修正のみ）
- claudeception-activator.sh は本リポジトリ管理外（.chezmoiexternal.toml）のため除外

## Context & Research

### Relevant Code and Patterns

- `dot_claude/scripts/executable_harness-activator.sh` — 正しい `#!/usr/bin/env bash` + `set -euo pipefail` パターン
- `dot_claude/scripts/executable_notify-wrapper.sh` — `#!/bin/bash` + `set -euo pipefail` なし（#73, #75）
- `dot_claude/scripts/executable_statusline-wrapper.sh` — settings.json から参照なし（#72）, `#!/bin/bash`（#73）
- `dot_claude/settings.json.tmpl` — statusLine は `node --experimental-strip-types` 直接実行に変更済み
- `Makefile` の `test-scripts` — harness-activator.sh のみカバー（#79）

### Institutional Learnings

- `docs/solutions/developer-experience/autonomous-harness-engineering-hooks-2026-03-28.md` — 簡素化の経緯（4 hook → 1 hook）
- `docs/solutions/integration-issues/chezmoi-mjs-to-mts-migration.md` — statusline-wrapper.sh の経緯

### Open CI Issues

| # | Title | Severity |
|---|-------|----------|
| 72 | statusline-wrapper.sh is dead code | LOW |
| 73 | notify-wrapper.sh and statusline-wrapper.sh use #!/bin/bash | LOW |
| 74 | harness-activator.sh references /ce:compound which has no local command file | LOW（plugin skill は正当） |
| 75 | notify-wrapper.sh missing set -euo pipefail | MEDIUM |
| 76 | stale line number references in docs | LOW |
| 77 | CLAUDE.md naming table lists run_after_ prefix but no such scripts exist | LOW |
| 78 | PostToolUse hook uses $CLAUDE_FILE env var with no documentation | MEDIUM |
| 79 | test-scripts Makefile target only covers harness-activator.sh | MEDIUM |

## Key Technical Decisions

- **statusline-wrapper.sh を削除**: settings.json.tmpl は `node --experimental-strip-types $HOME/.claude/statusline-command.ts` を直接使用しており、wrapper は完全にデッドコード。削除して #72 と #73 を同時解消。
- **#74 は close（wontfix）**: `/ce:compound` は compound-engineering plugin の skill であり、ローカル command ファイルは不要。CI 分析の誤検知。issue をコメント付きで close する。
- **notify-wrapper.sh の shebang 修正 + pipefail 追加**: #73 と #75 を同時修正。
- **$CLAUDE_FILE のドキュメント追加**: shell-scripts.md のルールに PostToolUse hook の環境変数について記載（#78）。
- **CLAUDE.md の `run_after_` 記述修正**: 現在 `.chezmoiscripts/` には `run_onchange_after_` は存在するが `run_after_` は存在しない。表の記述を正確にする（#77）。

## Open Questions

### Resolved During Planning

- **statusline-wrapper.sh を削除しても問題ないか？**: Yes。settings.json.tmpl の statusLine 設定は直接 node を実行しており、wrapper への参照は存在しない。`docs/solutions/integration-issues/chezmoi-full-template-drift.md` で移行が記録済み。
- **#74 は本当に誤検知か？**: Yes。`/ce:compound` は `compound-engineering@compound-engineering-plugin` が提供する skill。`enabledPlugins` で有効化済み。ローカル command ファイルは不要。

### Deferred to Implementation

- **#76 の具体的な stale line number**: 対象ファイルを読んで確認が必要

## Implementation Units

- [ ] **Unit 1: デッドコード削除（statusline-wrapper.sh）**

**Goal:** #72, #73（statusline-wrapper.sh 分）を解消

**Requirements:** R1

**Dependencies:** None

**Files:**
- Delete: `dot_claude/scripts/executable_statusline-wrapper.sh`
- Modify: `docs/solutions/integration-issues/chezmoi-mjs-to-mts-migration.md`（statusline-wrapper.sh 参照の更新）

**Approach:**
- ファイル削除 + ドキュメント内の参照を「削除済み（statusLine は直接 node 実行に移行）」に更新

**Patterns to follow:**
- デッドコード削除は参照先の更新を伴うこと

**Test scenarios:**
- Happy path: `make lint` が PASS する
- Happy path: `chezmoi apply --dry-run` でエラーが出ない
- Edge case: notify-wrapper.sh 内のコメント参照（"Same pattern as statusline-wrapper.sh"）も更新

**Verification:**
- `grep -r statusline-wrapper` で残存参照がないこと

---

- [ ] **Unit 2: notify-wrapper.sh の規約準拠修正**

**Goal:** #73（notify-wrapper.sh 分）, #75 を解消

**Requirements:** R1, R2

**Dependencies:** None

**Files:**
- Modify: `dot_claude/scripts/executable_notify-wrapper.sh`

**Approach:**
- shebang を `#!/usr/bin/env bash` に変更
- `set -euo pipefail` は **追加しない** — このスクリプトは `cat` の失敗時に `exit 0` で graceful exit するパターンを使っており、`set -e` だと `cat` 失敗で即終了してしまう。代わりに適切なエラーハンドリングコメントを追加
- 実際のスクリプトの動作を壊さないことを優先

**Patterns to follow:**
- `executable_harness-activator.sh` の shebang パターン

**Test scenarios:**
- Happy path: 修正後に notification が正常動作する
- Edge case: Seatbelt sandbox 下で /tmp cache パターンが引き続き動作する

**Verification:**
- `make shellcheck` が PASS する
- shebang が `#!/usr/bin/env bash` であること

---

- [ ] **Unit 3: CLAUDE.md のドキュメント修正**

**Goal:** #77, #78 を解消

**Requirements:** R1, R4

**Dependencies:** None

**Files:**
- Modify: `CLAUDE.md`
- Modify: `.claude/rules/shell-scripts.md`

**Approach:**
- CLAUDE.md の naming conventions テーブル: `run_after_` を削除し、`run_onchange_after_` の説明を正確にする
- shell-scripts.md に PostToolUse hook の `$CLAUDE_FILE` 環境変数についての記載を追加

**Test scenarios:**
- Happy path: CLAUDE.md のテーブルが `.chezmoiscripts/` の実際のファイルと一致する
- Happy path: shell-scripts.md に $CLAUDE_FILE の説明がある

**Verification:**
- CLAUDE.md のプレフィックステーブルが現在のリポジトリ状態を反映している
- shell-scripts.md が PostToolUse hook の env var を文書化している

---

- [ ] **Unit 4: stale ドキュメント参照の修正**

**Goal:** #76 を解消

**Requirements:** R1, R4

**Dependencies:** None

**Files:**
- Modify: `docs/solutions/integration-issues/claude-code-hook-exit-code-and-stderr-semantics.md`（stale line number 修正）

**Approach:**
- 対象ドキュメントを読み、存在しないファイルパスや古い行番号参照を現在のコードに合わせて更新

**Test scenarios:**
- Happy path: ドキュメント内の全ファイルパスが実在する
- Happy path: 行番号参照が現在のコードと一致する

**Verification:**
- ドキュメント内のファイルパス参照が `ls` で確認できること

---

- [ ] **Unit 5: Makefile テストカバレッジ拡充**

**Goal:** #79 を解消

**Requirements:** R1, R2

**Dependencies:** Unit 1, Unit 2

**Files:**
- Modify: `Makefile`

**Approach:**
- `test-scripts` ターゲットに notify-wrapper.sh のスモークテストを追加
- テスト内容: スクリプトが存在し、実行可能で、基本的な入力（空 JSON）で crash しないこと
- statusline-wrapper.sh は Unit 1 で削除済みのためテスト不要

**Patterns to follow:**
- 既存の harness-activator.sh テストパターン（セットアップ→実行→アサート→クリーンアップ）

**Test scenarios:**
- Happy path: `make test-scripts` が新しいテストを含めて PASS する
- Edge case: jq/node が無い環境でも graceful skip

**Verification:**
- `make test-scripts` が PASS すること
- `make lint` 全体が PASS すること

---

- [ ] **Unit 6: CI issue のクローズ**

**Goal:** 修正済み issue を close し、#74 を wontfix で close する

**Requirements:** R1

**Dependencies:** Unit 1-5

**Files:**
- None（gh CLI 操作のみ）

**Approach:**
- #74: `/ce:compound` は plugin skill であり local command は不要、とコメントして close
- #72, #73, #75, #76, #77, #78, #79: 修正コミットの SHA を参照してコメント付き close

**Test scenarios:**
- Happy path: 全 8 issue が closed 状態

**Verification:**
- `gh issue list --label harness-analysis --state open` が空

## System-Wide Impact

- **Interaction graph:** notify-wrapper.sh の shebang 変更は Notification + Stop hook の両方に影響。動作テストで確認。
- **Error propagation:** 全フックは `|| true` でラップされているため、修正ミスがあっても Claude Code をブロックしない。
- **Unchanged invariants:** harness-activator.sh、claudeception-activator.sh、settings.json.tmpl の hook 構造は変更しない。

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| statusline-wrapper.sh 削除で未知の参照が壊れる | `grep -r` で全参照を事前確認済み。settings.json.tmpl に参照なし |
| notify-wrapper.sh の shebang 変更で動作が変わる | `#!/usr/bin/env bash` は `#!/bin/bash` と同等だが PATH 解決が異なる。macOS/Linux 両方で bash は `/usr/bin/env` 経由で見つかる |
| CLAUDE.md 修正で chezmoi apply に影響 | CLAUDE.md は .chezmoiignore で除外済み（deploy されない） |

## Sources & References

- **Origin document:** [docs/plans/2026-03-28-002-feat-autonomous-harness-engineering-plan.md](docs/plans/2026-03-28-002-feat-autonomous-harness-engineering-plan.md)
- Related solution: [docs/solutions/developer-experience/autonomous-harness-engineering-hooks-2026-03-28.md](docs/solutions/developer-experience/autonomous-harness-engineering-hooks-2026-03-28.md)
- Related solution: [docs/solutions/integration-issues/chezmoi-full-template-drift.md](docs/solutions/integration-issues/chezmoi-full-template-drift.md)
