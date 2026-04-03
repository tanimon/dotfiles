Bridge ECC continuous learning instincts into the harness engineering rule pipeline. Reviews high-confidence instincts and promotes them to permanent rules through the existing propose/validate/apply workflow.

## Overview

ECC's continuous learning system creates "instincts" — atomic learned behaviors with confidence scores, triggers, and domain tags. This command bridges instincts with the harness rule system by:
1. Scanning project and global instincts
2. Filtering to promotion candidates (high confidence, not already covered by rules)
3. Transforming instincts into structured harness proposals
4. Delegating to the validate-harness-proposal skill for quality gating
5. Applying approved promotions via the apply-harness-proposal workflow

## Process

### Step 1: Detect project and scan instincts

Identify the current project using ECC's project detection (git remote URL hash). Read instincts from:
- Project scope: `~/.claude/homunculus/projects/<project-hash>/instincts/personal/`
- Global scope: `~/.claude/homunculus/instincts/personal/`

If no instincts exist, report "No instincts found. The ECC continuous learning observer needs to run for a few sessions to build up instincts. Use /instinct-status to check current state."

### Step 2: Filter promotion candidates

For each instinct, check:
- **Confidence >= 0.7** (strong confidence threshold)
- **Not already covered by an existing rule**: Search `dot_claude/rules/`, `.claude/rules/`, and CLAUDE.md for matching patterns using the instinct's trigger and action text
- **Not contradicting an existing rule**: Check that the instinct's action does not conflict with established rules

Report:
- Total instincts scanned
- Candidates that pass filters
- Instincts skipped (with reason: low confidence, already covered, contradicting)

If no candidates pass filters, report the summary and exit.

### Step 3: Present candidates for review

For each candidate, show:
```
Instinct: <id>
Domain: <domain>
Trigger: <trigger>
Action: <action>
Confidence: <score> (based on <N> observations)
Scope: project | global
Evidence: <evidence summary>
```

Ask the user which instincts to promote. Options:
1. Promote all candidates
2. Select specific instincts (by number)
3. Skip — no promotion needed
4. Evolve instead — run `/evolve` to cluster instincts into skills

### Step 4: Generate harness proposals

For each selected instinct, create a structured proposal:
- **Scope**: Determine from instinct scope and domain
  - Global instincts with domain `security`, `git`, `workflow` → Global rule (`dot_claude/rules/common/`)
  - Project instincts → Project rule (`.claude/rules/`)
  - Instincts about code style for a specific language → Language-specific rule directory
- **Risk tier**: Low (documentation, style rules) or High (hooks, CI, security)
- **Target file**: Choose appropriate rule file (create new or amend existing)
- **Content**: Transform instinct into rule format:
  ```markdown
  ## <Instinct trigger as section header>

  <Action text, expanded into actionable guidance>

  _Promoted from ECC instinct `<id>` (confidence: <score>, observations: <N>)_
  ```

### Step 5: Validate and apply

For each proposal:
1. Invoke `Skill(validate-harness-proposal)` — this enforces generator-evaluator separation
2. If APPROVED: apply using the `/apply-harness-proposal` workflow
3. If REJECTED: report the rejection reason and skip
4. If REVISE: show the revision suggestions and let the user decide

After all promotions are applied, run `make lint` to verify.

## Constraints

- **Generator-evaluator separation**: This command generates proposals. Validation MUST be delegated to the validate-harness-proposal skill (via a sub-agent if in the same session).
- **Never auto-promote without user confirmation**: Always present candidates for review first.
- **Preserve instinct after promotion**: Do not delete the source instinct. It continues to receive confidence updates from the observer.
- **Never edit deployed targets**: All rule changes go through chezmoi source files.

## Related Commands

- `/instinct-status` — View all instincts with confidence bars
- `/evolve` — Cluster related instincts into skills/commands/agents (alternative to promotion)
- `/prune` — Delete expired pending instincts (30-day TTL)
- `/harness-rule-lifecycle` — Inventory and manage promoted rules
- `/apply-harness-proposal` — Apply validated proposals to chezmoi source tree
