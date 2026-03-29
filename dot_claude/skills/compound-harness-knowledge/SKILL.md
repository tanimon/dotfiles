---
name: compound-harness-knowledge
description: |
  Converts resolved harness issues into structured docs/solutions/ documents.
  Triggers: (1) /compound-harness-knowledge command, (2) After a harness improvement
  is successfully applied, (3) When a non-trivial debugging session resolves a problem.
  Cross-references existing solutions to avoid duplicates. Suggests Claudeception skill
  extraction when the solution involves a novel technique.
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
  - Skill
---

# Harness Knowledge Compounder

You convert resolved issues and debugging sessions into structured solution documents under
`docs/solutions/`, ensuring knowledge compounds across sessions.

## Input

Accept all of:
1. **Resolved issue description** - What was the problem?
2. **Applied fix** - What change resolved it?
3. **Context** - How was it discovered? What was tried first?

If any input is missing, ask the user before proceeding.

## Workflow

### Step 1: Duplicate Check

Search `docs/solutions/` for existing documents covering the same problem:

```
Grep: pattern=<key terms from the issue> path=docs/solutions/
```

If a closely matching document exists:
- Show the user the existing document path and title
- Ask whether to update the existing doc or create a new one
- If updating, edit the existing doc to incorporate new information

### Step 2: Classify Subdirectory

Place the document in the correct subdirectory based on problem type:

| Subdirectory | Criteria |
|---|---|
| `integration-issues/` | Tool/service integration, config mismatches, API changes |
| `runtime-errors/` | Sandbox EPERM, crash, process failures |
| `developer-experience/` | Harness engineering, CI pipeline, lint, DX tooling |
| `logic-errors/` | Algorithmic bugs, wrong assumptions in code logic |

### Step 3: Generate Solution Document

Follow the exact format used by existing docs. Use YAML frontmatter:

```yaml
---
title: <Descriptive Title>
date: <YYYY-MM-DD>
category: <subdirectory name>
tags:
  - <relevant tags>
severity: <low|medium|high|critical>
component: <affected component>
symptom: "<user-visible symptom>"
root_cause: <concise root cause>
problem_type: <developer_experience|integration|runtime_error|logic_error>
---
```

Document body sections (in order):

1. **Problem** - What went wrong and why it matters
2. **Symptoms** - Observable indicators
3. **What Didn't Work** - Failed approaches (include for non-trivial debugging sessions)
4. **Solution** - The fix, with code snippets where helpful
5. **Why This Works** - Technical explanation of the root cause and fix
6. **Prevention** - How to avoid recurrence (rules, hooks, CI checks)
7. **Related** - Links to related `docs/solutions/` documents

Filename format: `<kebab-case-title>-<YYYY-MM-DD>.md`

### Step 4: Cross-Reference

After creating the document:
- Search for related existing solutions
- Add links in the **Related** section of the new document
- If existing documents would benefit from a backlink, edit them to add one

### Step 5: Evaluate Skill Extraction

If the solution involves a **novel debugging technique or reusable workflow**, suggest
Claudeception skill extraction:

```
Consider: This solution involves [technique]. Extract as a Claudeception skill?
- Skill name: <suggested-name>
- Trigger: <when the skill would activate>
- Reuse potential: <high|medium|low>
```

Only suggest when reuse potential is medium or high. Do not suggest for one-off fixes.

## Quality Gates

Before finalizing, verify ALL of these:

- [ ] **Verified fix**: The solution actually worked (not theoretical)
- [ ] **No duplicates**: No existing `docs/solutions/` document covers the same problem
- [ ] **Format compliance**: YAML frontmatter and section structure match existing docs exactly
- [ ] **"What Didn't Work" included**: Required for any multi-step debugging session
- [ ] **Prevention section present**: Required for any issue that could recur
- [ ] **Cross-references added**: Related docs linked bidirectionally

If any gate fails, fix the issue before writing the file. If the fix is unverified,
add a `status: unverified` field to the frontmatter and note it in the document.

## Output

After completion, report:
1. Path to the created/updated document
2. Any cross-references added to existing documents
3. Skill extraction recommendation (if applicable)
