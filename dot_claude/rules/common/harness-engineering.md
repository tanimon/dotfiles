---
date: 2026-03-28
trigger: "Agent made a repeatable mistake without creating a preventive rule"
---

# Harness Engineering

## Core Principle

CLAUDE.md とルールは**エージェントの振る舞いのバグトラッカー**として扱う。繰り返してはいけない失敗を見つけたら記録する。今作業中のリポに閉じた学びなら理由を添えてその修正と同じ PR に載せる。セッション横断の学びや別リポ向けの学びは `/harness-reflect` で queue に入れ、`/harness-review` の PR で反映する(下の「Feedback Loop Hierarchy」)。どちらの経路でも人間の PR レビューを通す。

## Failure-to-Rule Pipeline

When an agent produces a bad outcome:
1. Identify the root cause (wrong assumption, missing context, bad pattern)
2. Determine scope: project-specific (CLAUDE.md or `.claude/rules/`) vs global (`~/.claude/rules/`)
3. Write a concise, actionable rule that prevents recurrence
4. Include the "why" — rules without rationale get ignored or misapplied

## Rule Writing Guidelines

Good rules are:
- **Specific**: "Use `fmt.Errorf` with `%w` for error wrapping" not "Handle errors properly"
- **Actionable**: Tell the agent what TO DO, not just what to avoid
- **Contextual**: Include when the rule applies and when it doesn't
- **Grounded**: Reference existing code patterns or files when possible

Bad rules:
- Vague platitudes ("write clean code")
- Duplicates of what the codebase already shows
- Rules that conflict with other rules without priority guidance

## Harness Maintenance

- Review rules periodically — remove rules that models no longer need
- Test rules by observing agent behavior — if a rule isn't changing behavior, rewrite or remove it
- Keep CLAUDE.md focused on project-specific pitfalls, not general coding advice
- Use `~/.claude/rules/` for cross-project patterns, `.claude/rules/` for project-specific ones

## Feedback Loop Hierarchy

1. **Hooks** (automatic, immediate): secret detection on `Write`, and the `PreToolUse` guards on `Bash` (git push / curl localhost) — fire per tool use
2. **Harness loop** (semi-automatic): SessionEnd hook records substantial sessions;
   `/harness-reflect` extracts learnings into `~/.claude/harness/queue.md`;
   `/harness-review` (7-day cadence, nudged by the SessionStart briefing) triages the
   queue into a single human-reviewed PR. Every harness change goes through PR review —
   there is no auto-apply tier.
3. **Rules** (contextual, persistent): Read at session start and guide decisions
   throughout the session
4. **CLAUDE.md** (project-scoped): Project architecture, commands, pitfalls
5. **docs/solutions/** (historical): Past problems and their resolutions

## Operating the Harness Loop

- The SessionStart briefing prints one status line every session. Silence across
  sessions means the briefing hook itself is dead — investigate immediately.
- A warning that stays for weeks is itself a harness bug: queue it.
- Diagnostics: `bash ~/.claude/scripts/harness-doctor.sh`.
- All monitoring is deterministic shell; LLM judgment runs only inside
  /harness-reflect and /harness-review, in interactive sessions where failures
  are visible.

## Anti-Patterns

- Adding rules without verifying the agent actually reads and follows them
- Writing rules so long the agent deprioritizes them in context
- Duplicating rules across CLAUDE.md and `~/.claude/rules/` — pick one location
- Adding defensive rules for problems that only happened once in unusual circumstances
