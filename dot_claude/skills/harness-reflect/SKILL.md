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

Skip an entry silently if its session_id matches the current session (it is
already covered by input 1).

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

Write entries in English (they feed English-language rules and docs).

## Bookkeeping (after appending)

1. Remove processed lines from `pending.jsonl` (rewrite the file without
   them; keep unprocessed lines intact).
2. Update state: `jq '.last_reflect_epoch = now | .last_reflect_epoch |= floor'`
   on `~/.claude/harness/state.json` (write via temp file + `mv`).
3. Report a summary: N sessions analyzed, M entries queued, dropped entries
   (missing transcripts) if any. If nothing was worth queueing, say so —
   an empty result is a valid outcome, not a failure.
