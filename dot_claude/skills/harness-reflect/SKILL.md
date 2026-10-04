---
name: harness-reflect
description: |
  Extract harness-worthy learnings from sessions into the improvement queue.
  Triggers: (1) /harness-reflect command, (2) invoked as the first step of
  /harness-review when unreflected sessions are pending, (3) SessionStart
  briefing warns about unreflected sessions piling up. Reads the current
  session and/or transcripts recorded in ~/.claude/harness/pending.jsonl,
  appends structured candidates to ~/.claude/harness/queue.md. Extraction
  only — dedup and adoption decisions belong to /harness-review.
---

# Harness Reflect

Extract learnings worth a permanent harness improvement (rule, CLAUDE.md
pitfall, docs/solutions entry) from sessions, and append them to the queue.

## Inputs

1. **The current session** (always, when invoked interactively): review the
   conversation so far with full context. This is the highest-quality input.
2. **Pending transcripts**: read `~/.claude/harness/pending.jsonl`. Each line
   is `{"session_id", "transcript_path", "cwd", "recorded_epoch"}`. For each
   entry, read the transcript file and analyze it. If the transcript file no
   longer exists, drop the entry (note it in your summary).
   transcript_path が `~/.claude/projects/` 配下の `.jsonl` でなければ読まずに
   drop し、要約にそのパスを明記する。判定は `realpath` で正規化した後のパスで行い、
   比較先も `realpath ~/.claude/projects` で正規化する(リテラルのままだと、`~/.claude`
   かその途中に symlink が入った時点で全エントリが黙って drop される)。
   `..` を含むパスは正規化前に drop する(`~/.claude/projects/../../tmp/x.jsonl` は
   文字列の前方一致だけなら通ってしまう)。`~/.claude/harness/` はサンドボックス内の
   任意のプロセスが書けるため、pending.jsonl に書かれた任意のファイルを読むと
   その内容が queue を経て public な PR に載りうる。

Skip an entry silently if its session_id matches the current session (it is
already covered by input 1).

## Select inputs with the failure detector

失敗の検出器(Evaluator の一部。ADR 0011)で入力を選んでから抽出する。LLM の判断で
入力を選ばない。

1. pending を読む前に `bash ~/.claude/scripts/harness-select-pending.sh` を 1 回実行する。
   各エントリの transcript を検出器にかけ、失敗が 1 件も無いエントリを pending.jsonl から外し、
   セッションごとの信号別の件数を `~/.claude/harness/detections.jsonl` に記録する。
   失敗したら抽出に進まずに止め、出力をそのまま報告する。
2. 残ったエントリごとに `bash ~/.claude/scripts/harness-detect-failures.sh <transcript_path>`
   を実行する。出力は 1 行 1 件の `{"line":<transcript の行番号>,"signal":<信号>}`。
   抽出はその行の周辺から始め、検出された失敗の根本原因を探す。信号の意味は
   スクリプトのヘッダにある。
3. transcript_path の検査(上の Inputs の 2)に通らないエントリは、選別が触れずに残す。
   ここでも drop して要約に明記する。

input 1(現在のセッション)はこの選別の対象外。

## What to extract

- A wrong assumption the agent made, and its root cause
- A user correction or pushback on agent behavior (include the why)
- A repeated pattern that took multiple attempts to get right
- Drift between what rules/CLAUDE.md say and what is actually true

## What NOT to extract

- One-off circumstances unlikely to recur
- Things the codebase/docs already state (check before queueing)
- Conversation-local context with no cross-session value
- Vague platitudes — every entry needs a concrete, actionable proposed change

When in doubt, lean toward NOT queueing. A short high-signal queue beats a
long noisy one; the review step and human PR review both cost real attention.

## Queue entry format

Append to `~/.claude/harness/queue.md` (create parent entries exactly like
this; the review skill parses `^## ` headers and `- **Key:**` fields):

```markdown
## [YYYY-MM-DD] <short imperative title>

- **What happened:** <1-3 sentences, concrete>
- **Root cause:** <the wrong assumption / missing context / bad pattern>
- **Proposed change:** <exact rule text or doc change to make>
- **Scope:** global | dotfiles | project:<repo-name>
- **Source:** session <session_id>
```

Write entry bodies in Japanese, per `~/.claude/rules/common/documentation-language.md`.
Keep the field labels above (`## [date] title`, `- **What happened:**` …) verbatim — the
review skill parses them.

## Bookkeeping (after appending)

1. Remove processed lines from `pending.jsonl` by filtering the file **as it
   exists now** — e.g. one `grep -vF '"session_id":"<sid>"'` per processed id
   into a temp file, then `mv` over the original. Never write back a copy you
   read earlier: the SessionEnd hook appends concurrently, and a stale
   write-back silently drops sessions recorded in between.
2. Update state: `jq '.last_reflect_epoch = now | .last_reflect_epoch |= floor'`
   on `~/.claude/harness/state.json` (write via temp file + `mv`).
3. Report a summary: the selector's summary line, N sessions analyzed, M entries
   queued, dropped entries (missing transcripts) if any. If nothing was worth queueing, say so —
   an empty result is a valid outcome, not a failure.
