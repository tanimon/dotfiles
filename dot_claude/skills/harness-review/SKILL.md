---
name: harness-review
description: |
  Periodic harness health check and improvement-queue triage. Triggers:
  (1) /harness-review command, (2) SessionStart briefing warns the review is
  overdue (7-day cadence). Runs the deterministic doctor, reflects over any
  pending sessions, triages queued candidates against existing rules, then
  implements adopted changes as ONE pull request for human review. The human
  PR review is the only quality gate — this skill must present honest
  trade-offs, not advocacy.
---

# Harness Review

週次ジョブ(`~/.claude/scripts/harness-weekly.sh`)も、このスキルをプロンプトで一部だけ
変えて headless で実行する(作業場所はジョブが切った worktree、push と PR の作成はジョブが
行う)。ここを変えると両方の経路が変わる。節は見出しで参照されているので、見出しを
変えるときはジョブのプロンプトも直す。

Operate on the chezmoi source repo: `cd "$(chezmoi source-path)"` (fallback:
`~/.local/share/chezmoi`). All rule/doc changes are made there, never on
deployed files under `~/`.

## Step 1: Liveness check

Run `bash ~/.claude/scripts/harness-doctor.sh`. If any FAIL line appears,
fixing the loop itself is this review's first-priority deliverable — include
the fix in the PR (or apply `chezmoi apply` if the fix is deploy-only) before
touching the queue.

## Step 2: Reflect over pending sessions

If `~/.claude/harness/pending.jsonl` is non-empty, execute the
harness-reflect skill (`~/.claude/skills/harness-reflect/SKILL.md`) first so
this review sees the full queue.

## Step 3: Triage the queue

For each `^## ` entry in `~/.claude/harness/queue.md`:

1. **Dedup:** search existing rules (`.claude/rules/`, `dot_claude/rules/`),
   `CLAUDE.md` Known Pitfalls, and `docs/solutions/` for the same guidance.
   Already covered → verdict `rejected (duplicate of <path>)`.
2. **Value test:** would this rule have prevented the original failure? Is it
   specific, actionable, and likely to recur? Vague or one-off → verdict
   `rejected (<reason>)`.
3. **Placement:**
   - cross-project behavior → `dot_claude/rules/common/`
   - Claude Code-only mechanics (the Agent tool, the Bash tool,
     sandbox/permission matching) → `dot_claude/rules/claude-code/`, which is
     not concatenated into `~/.codex/AGENTS.md`
   - behavioral guidelines → the shared body
     `.chezmoitemplates/agent-instructions-common` if product-neutral,
     `dot_claude/CLAUDE.md.tmpl` if it names Claude-only tools
   - this-repo pitfall → `harness/modules/project/50-pitfalls.md` (then run
     `just harness-sync`; `CLAUDE.md` is generated from it) or `.claude/rules/`
   - incident record → `docs/solutions/`

   Scope `project:<other-repo>` → verdict
   `handoff (belongs in <repo>)`; tell the user what to add there — do not
   modify other repos from this review.
4. Related queue entries may be merged into one change; record
   `merged into <title>` on the absorbed entries.

## Step 4: Staleness scan

Sample existing rules for rot (do all of `.claude/rules/`,
`dot_claude/rules/common/`, and `dot_claude/rules/claude-code/` when the
queue is small; otherwise at least the files touched by adopted changes plus one more):

- Referenced files, commands, and workflows still exist?
- Contradicted by newer learnings or by how work is actually done now?
- Project auto-memories (`~/.claude/projects/*/memory/`) that still prescribe
  a workaround a harness change has made unnecessary (e.g. "run git commit
  outside the sandbox" after signing moved to a local key)? Memories do not
  follow harness changes, so a stale workaround keeps being re-applied. grep
  them for the workaround's keywords and list stale ones in the report for
  the user to retire — they live outside the repo, so do not delete them from
  the review.

Propose deletions/edits for stale rules in the same PR. Rules kept alive out
of caution are noise — deprecate aggressively; git history preserves them.

## Step 5: Implement and open ONE PR

1. Create a branch `harness/review-YYYY-MM-DD` off `main`.
   この名前は変えない。CI は prefix `harness/review-` で自己改善ループの PR を
   見分け、`scripts/evaluator-paths.txt` のパスに触れた PR を落とす
   (`scripts/check-evaluator-guard.sh`)。そのパスの変更が要るときは採用せず、
   人が別の PR で行うものとして報告に書く。
2. Apply all adopted changes (new rules in Japanese per
   `~/.claude/rules/common/documentation-language.md`, structured per
   `~/.claude/rules/common/harness-engineering.md` writing guidelines).
3. Run `just lint` and fix findings.
4. Open one PR (body in Japanese) listing: adopted entries with their queue
   titles, rejected/handoff counts, staleness findings. Do NOT merge it.

If nothing was adopted and nothing is stale, skip the PR — record verdicts
and say so. An empty review is a valid outcome.

### Eval Case requests

採用したルールごとに、効果を測る Eval Case の依頼を書く(ADR 0011)。評価そのものは
`~/.claude/scripts/harness-eval-cases.sh`(Evaluator)が行い、run 数・予算・判定の基準は
スクリプトが決める。依頼は `~/.claude/harness/eval-requests-YYYY-MM-DD.json` に Write ツールで書く:

```json
{"cases": [
  {"title": "[YYYY-MM-DD] <queue の見出しのタイトル>", "rule": "<注入するルール本文>",
   "source_session": "<queue の Source の session id>",
   "prompt": "<ルールが無いと元の失敗が起きる依頼>",
   "graders": [{"name": "uses-x", "type": "regex", "pattern": "<JavaScript の正規表現>"}],
   "history_lines": 0},
  {"title": "[YYYY-MM-DD] <タイトル>", "exempt": "<Eval Case を書けない理由>"}
]}
```

- `title` は queue の見出しの `## ` より後ろをそのまま書く(採用と結果をこの文字列で突き合わせる)。
- prompt はルールをほのめかさない。prompt が答えを指定すると、ルールが無くても成功して無効になる(天井効果)。
- ツールは持たせず、「実行するコマンドを答えて」の形で書く。`allowed_tools` に `Bash` を入れたケースは、
  このマシンでは評価の事前確認で止まり「評価できなかった」になる(`.claude/rules/harness-weekly.md`)。
- grader は `regex`(`target`: `last_message` / `trace`、`match`: `contains` / `not_contains`)、
  `tool_used`(Read / Glob / Grep / Bash)、`llm`(`criteria`)だけを使える。
- `history_lines` を正にすると、出典の transcript のその行までを再開してから prompt を渡す(大きい履歴は評価しない)。
- 再現できる依頼を書けない(人の判断の誤り、外部サービスの状態など)ルールは `exempt` に理由を書く。

週次ジョブでは、ジョブが評価して効果の節を PR の本文に足す。手動の review では、PR を開く前に
`bash ~/.claude/scripts/harness-eval-cases.sh run --requests <依頼> --date <日付> --out ~/.claude/harness/eval-results-<日付>.json`
と `… section --results <結果>` を実行し、出力を本文に載せる(費用がかかる。既定の上限は $5)。

## Step 6: Bookkeeping

1. Move every processed entry from `queue.md` to
   `~/.claude/harness/queue-archive.md`, appending a verdict line to each:
   `- **Verdict:** adopted (PR <url>) | rejected (<reason>) | handoff (<repo>) | merged into <title>`
2. Update state (temp file + `mv`):
   `jq '.last_review_epoch = now | .last_review_epoch |= floor'` on
   `~/.claude/harness/state.json`.
3. Report: doctor result, N adopted / M rejected / K handoff, PR link,
   staleness findings.
