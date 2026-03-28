# Harness Engineering

## Core Principle

CLAUDE.md is a **bug tracker for agent behavior**. Every time an agent makes a mistake that should not be repeated, add an entry. This is the highest-ROI harness investment.

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

1. **Hooks** (automatic, immediate): Format, lint, secret detection — fires on every tool use
2. **Rules** (contextual, session-scoped): Read at session start, guides all decisions
3. **CLAUDE.md** (project-scoped): Project architecture, commands, pitfalls
4. **docs/solutions/** (historical): Past problems and their resolutions — referenced when similar issues arise

## Anti-Patterns

- Adding rules without verifying the agent actually reads and follows them
- Writing rules so long the agent deprioritizes them in context
- Duplicating rules across CLAUDE.md and `~/.claude/rules/` — pick one location
- Adding defensive rules for problems that only happened once in unusual circumstances
