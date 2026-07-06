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
3. **Placement:** cross-project behavior → `dot_claude/rules/common/` (or
   `dot_claude/CLAUDE.md` for behavioral guidelines); this-repo pitfall →
   repo `CLAUDE.md` Known Pitfalls or `.claude/rules/`; incident record →
   `docs/solutions/`. Scope `project:<other-repo>` → verdict
   `handoff (belongs in <repo>)`; tell the user what to add there — do not
   modify other repos from this review.
4. Related queue entries may be merged into one change; record
   `merged into <title>` on the absorbed entries.

## Step 4: Staleness scan

Sample existing rules for rot (do all of `.claude/rules/` and
`dot_claude/rules/common/` when the queue is small; otherwise at least the
files touched by adopted changes plus one more):

- Referenced files, commands, and workflows still exist?
- Contradicted by newer learnings or by how work is actually done now?

Propose deletions/edits for stale rules in the same PR. Rules kept alive out
of caution are noise — deprecate aggressively; git history preserves them.

## Step 5: Implement and open ONE PR

1. Create a branch `harness/review-YYYY-MM-DD` off `main`.
2. Apply all adopted changes (new rules in English, following
   `~/.claude/rules/common/harness-engineering.md` writing guidelines).
3. Run `make lint` and fix findings.
4. Open one PR (body in Japanese) listing: adopted entries with their queue
   titles, rejected/handoff counts, staleness findings. Do NOT merge it.

If nothing was adopted and nothing is stale, skip the PR — record verdicts
and say so. An empty review is a valid outcome.

## Step 6: Bookkeeping

1. Move every processed entry from `queue.md` to
   `~/.claude/harness/queue-archive.md`, appending a verdict line to each:
   `- **Verdict:** adopted (PR <url>) | rejected (<reason>) | handoff (<repo>) | merged into <title>`
2. Update state (temp file + `mv`):
   `jq '.last_review_epoch = now | .last_review_epoch |= floor'` on
   `~/.claude/harness/state.json`.
3. Report: doctor result, N adopted / M rejected / K handoff, PR link,
   staleness findings.
