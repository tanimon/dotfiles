---
name: compound-harness-knowledge
description: |
  Thin wrapper around /ce:compound for harness-specific knowledge capture.
  Triggers: (1) /compound-harness-knowledge command, (2) After a harness improvement
  is successfully applied, (3) When a non-trivial debugging session resolves a problem.
  Adds harness failure classification and Claudeception skill extraction evaluation,
  then delegates actual documentation to Skill(ce:compound).
author: Claude Code
version: 2.0.0
date: "2026-03-29"
allowed-tools:
  - Read
  - Grep
  - Glob
  - Skill
---

# Harness Knowledge Compounder

Thin wrapper that adds harness-specific context before delegating to `/ce:compound`.

## Input

Accept all of:
1. **Resolved issue description** -- What was the problem?
2. **Applied fix** -- What change resolved it?
3. **Context** -- How was it discovered? What was tried first?

If any input is missing, ask the user before proceeding.

## Step 1: Classify the Harness Failure

Before documenting, classify the failure to enrich the context passed to `/ce:compound`:

| Category | Signal | Subdirectory hint |
|----------|--------|-------------------|
| **Hook/script failure** | Exit code issues, one-shot flag bugs, session ID problems | `developer-experience/` |
| **Rule gap** | Agent made a preventable mistake, no rule existed | `developer-experience/` |
| **CI pipeline issue** | Workflow misconfiguration, permission errors, expression bugs | `integration-issues/` |
| **Tool integration** | MCP server, plugin, sandbox, chezmoi interaction problem | `integration-issues/` |
| **Sandbox/runtime** | EPERM, process crash, nested sandbox conflict | `runtime-errors/` |
| **Logic error** | Wrong assumption in script logic, sort mismatch, template bug | `logic-errors/` |

## Step 2: Delegate to /ce:compound

Invoke `Skill(ce:compound)` with the following enriched context:

```
Document a resolved harness engineering issue:

**Problem:** <resolved issue description>
**Fix:** <applied fix>
**Context:** <how discovered, what was tried>
**Category:** <from Step 1 classification>
**Subdirectory:** <hint from Step 1>
**Tags:** harness-engineering, <additional relevant tags>
```

Let `/ce:compound` handle the actual document creation, formatting, and cross-referencing.

## Step 3: Evaluate Claudeception Skill Extraction

After `/ce:compound` completes, evaluate whether the solution warrants a reusable skill:

**Extract when** the solution involves:
- A novel debugging technique applicable beyond this specific issue
- A reusable workflow pattern (not just a config fix)
- A tool integration workaround that documentation doesn't cover

**Skip when** the solution is:
- A one-off configuration fix
- Already covered by an existing skill
- Specific to a single file or version

If extraction is warranted:

```
Consider: This solution involves [technique]. Extract as a Claudeception skill?
- Skill name: <suggested-name>
- Trigger: <when the skill would activate>
- Reuse potential: <high|medium|low>
```

Then invoke `Skill(claudeception)` if the user agrees or if reuse potential is high.

## Output

Report:
1. Path to the document created by `/ce:compound`
2. Skill extraction recommendation (if applicable)
