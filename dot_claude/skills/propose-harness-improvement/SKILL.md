---
name: propose-harness-improvement
description: |
  Generates structured harness improvement proposals from detected agent failures or issues.
  Triggers: (1) /propose-harness-improvement command, (2) Called by harness-activator hook when
  agent detects a mistake, (3) Called by harness-auto-remediate CI workflow via issue body.
  Searches existing rules and docs/solutions/ for duplicates before proposing. Classifies risk
  tier (auto-apply vs review-required). Outputs structured proposal for validation.
author: Claude Code
version: 1.0.0
date: "2026-03-29"
allowed-tools:
  - Read
  - Write
  - Edit
  - Grep
  - Glob
  - Bash
  - Agent
---

# Harness Improvement Proposal Generator

You generate structured harness improvement proposals from detected agent failures, CI findings,
or manual observations. Each proposal is specific, actionable, and classified by risk tier.

## Core Principle: Failure-to-Rule Pipeline

Every agent mistake that is likely to recur should become a rule, skill, or documented solution.
This skill automates the "propose" step of that pipeline.

## Input

Accept one of:
- A description of what went wrong (from session hook or manual invocation)
- A GitHub Issue body (from harness-analysis CI workflow)
- A specific error or pattern observed during work

## Proposal Workflow

### Step 1: Understand the Issue

Parse the input to extract:
- **What happened**: The concrete bad behavior or failure
- **Root cause**: Why the agent did this (wrong assumption, missing context, no rule)
- **Recurrence likelihood**: Is this likely to happen again? (Skip one-off mistakes)

If the issue description is too vague to generate a specific proposal, ask for clarification
rather than generating a vague rule. Good proposals require concrete examples.

### Step 2: Search for Duplicates

Before proposing anything new, check existing harness infrastructure:

Use the Grep tool (not `rg` or `grep` commands) to search:

- `dot_claude/rules/` and `.claude/rules/` for related rule content
- `CLAUDE.md` for related Known Pitfalls entries
- `docs/solutions/` for related problem resolutions
- `dot_claude/skills/` for related skill knowledge

When running inside the chezmoi repository, always search chezmoi source paths
(`dot_claude/`), not deployed target paths (`~/.claude/`).

If a related rule, solution, or skill already exists:
- **Exact duplicate**: Stop. Report that this is already covered and cite the source.
- **Partial overlap**: Propose amending the existing rule/doc rather than creating a new one.
- **Related but different**: Proceed with a new proposal, noting the related existing content.

### Step 3: Classify Scope

Determine where the improvement belongs:

| Scope | When | Target |
|-------|------|--------|
| **Project rule** | Issue is specific to this repository's patterns or tooling | `.claude/rules/<category>.md` or `CLAUDE.md` Known Pitfalls |
| **Global rule** | Issue applies across all projects (language pattern, tool behavior) | `dot_claude/rules/<lang>/<topic>.md` (chezmoi source) |
| **Hook enhancement** | Issue is automatable (formatting, linting, validation) | `dot_claude/scripts/` or `dot_claude/settings.json.tmpl` |
| **Skill** | Issue involves a reusable multi-step workflow or debugging technique | `dot_claude/skills/<name>/SKILL.md` |
| **Solution doc** | Issue is a resolved problem worth documenting for future reference | `docs/solutions/<category>/` |

### Step 4: Classify Risk Tier

| Tier | Criteria | Action |
|------|----------|--------|
| **Low risk (auto-apply)** | Documentation additions, formatting rules, new solution docs, non-behavioral changes | Can be applied directly after validation |
| **High risk (review required)** | Behavioral rules (change how agent works), scope changes, hook modifications, CI workflow changes | Requires PR and human review |

Risk escalation signals (always high-risk):
- Modifies hook scripts or CI workflows
- Changes permission settings or tool allowlists
- Affects security, authentication, or secret handling
- Modifies template files (`.tmpl`) that deploy to multiple machines
- Could cause `modify_` scripts to produce empty output (target deletion risk)

### Step 5: Generate Proposal

Output a structured proposal in this exact format:

```markdown
## Harness Improvement Proposal

**Issue:** [Brief description of the problem]
**What happened:** [Concrete description of the bad behavior]
**Root cause:** [Why the agent did this]
**Recurrence likelihood:** High / Medium

### Classification

- **Scope:** Project rule / Global rule / Hook / Skill / Solution doc
- **Risk tier:** Low (auto-apply) / High (review required)
- **Target file:** [Exact file path in chezmoi source tree]

### Proposed Change

**Action:** Create / Amend / Replace

[The exact content to add or change, ready to apply]

### Rationale

**Why this rule:** [Specific explanation grounded in the observed failure]
**How to apply:** [When/where this guidance kicks in during agent work]

### Related Existing Content

- [Link to any related rules, solutions, or skills found in Step 2]

### Validation Checklist

- [ ] Specific (names exact patterns, files, or behaviors)
- [ ] Actionable (tells the agent what TO DO, not just what to avoid)
- [ ] Non-duplicate (checked existing rules and solutions)
- [ ] Scoped correctly (right file, right scope level)
- [ ] Risk-classified correctly (low vs high risk)
```

## Quality Gates

Before finalizing a proposal, verify:

1. **Specificity**: "Use `fmt.Errorf` with `%w` for error wrapping" not "Handle errors properly"
2. **Actionability**: Tells the agent what TO DO, includes the "why" for edge case judgment
3. **Non-duplication**: No existing rule covers this (checked in Step 2)
4. **Correct scope**: Global rules don't belong in project files; project rules don't belong in global
5. **Grounded rationale**: The "why" references the actual observed failure, not hypotheticals

## Anti-Patterns

- Do NOT propose rules for one-off mistakes caused by ambiguous user instructions
- Do NOT propose vague platitudes ("write clean code", "handle errors properly")
- Do NOT propose rules that duplicate what the codebase already demonstrates via patterns
- Do NOT propose rules without the "why" — rules without rationale get ignored
- Do NOT propose rules so long they get deprioritized in agent context
