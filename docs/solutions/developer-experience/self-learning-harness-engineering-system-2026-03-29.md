---
module: harness-engineering
date: 2026-03-29
problem_type: developer_experience
component: tooling
symptoms:
  - "Harness analysis CI detects issues but remediation is entirely manual"
  - "Session-level learning relies on non-deterministic prompt injection"
  - "No automated pipeline from failure detection to rule creation"
  - "Rule effectiveness is not tracked — stale rules accumulate silently"
root_cause: missing_tooling
resolution_type: tooling_addition
severity: medium
tags:
  - harness-engineering
  - self-learning
  - generator-evaluator
  - ci-automation
  - rule-lifecycle
  - autonomous-improvement
---

# Self-Learning Autonomous Harness Engineering System

## Problem

The harness engineering pipeline had a gap between automated detection and manual remediation. Weekly CI (`harness-analysis.yml`) created GitHub Issues for harness improvements, but fixing them required manual invocation of `/resolve-harness-issues`. Session-level hooks (`harness-activator.sh`) injected evaluation prompts, but the agent's decision to act was non-deterministic. No mechanism existed to automatically generate, validate, and apply improvement proposals, or to track whether rules actually prevented the failures they were created for.

## Symptoms

- Harness-analysis issues accumulated without remediation
- Same agent mistakes recurred across sessions despite being detected
- Rule files grew without effectiveness tracking — no way to detect stale rules
- Knowledge from debugging sessions was lost unless manually captured via `/ce:compound`

## What Didn't Work

- **Four-hook architecture** (2026-03-28): Over-engineered approach with SessionStart, UserPromptSubmit x2, and Stop hooks. Rolled back to single hook + LLM self-evaluation. Documented in `docs/solutions/developer-experience/autonomous-harness-engineering-hooks-2026-03-28.md`.
- **Bash-based transcript analysis**: Attempted grep-based analysis of session transcripts in hook scripts. Unreliable pattern matching, replaced by delegating intelligence to the LLM.
- **Manual `/capture-harness-feedback`**: Requires human initiative to invoke, inconsistently used. Good for explicit review but cannot serve as the backbone of an autonomous loop.

## Solution

Implemented a three-layer autonomous system with 8 new/modified files (+1313 lines):

### Detection Layer (enhanced)

- **`harness-analysis.yml`**: Added rule effectiveness tracking (item 7 in analysis scope). Scans rule files for YAML frontmatter with `date`/`trigger` fields, flags rules older than 90 days as potentially stale.
- **`harness-activator.sh`**: Updated prompt injection to reference new skills (`Skill(propose-harness-improvement)`, `Skill(compound-harness-knowledge)`).

### Proposal/Validation Layer (new — generator-evaluator pattern)

- **`propose-harness-improvement` skill**: Generates structured proposals from detected failures. Searches existing rules/solutions for duplicates, classifies scope (project/global/hook/skill) and risk tier (low-risk auto-apply vs high-risk PR review).
- **`validate-harness-proposal` skill**: Quality gates enforcing generator-evaluator separation. Checks specificity, actionability, deduplication, consistency, scope correctness, and risk classification. Returns APPROVE/REJECT/REVISE verdicts. The validator has no Write/Edit permissions — only read-only tools.
- **`compound-harness-knowledge` skill**: Thin wrapper around `/ce:compound` adding harness-specific context (failure classification, Claudeception skill extraction evaluation).

### Application Layer (new)

- **`apply-harness-proposal` command**: Applies validated proposals with risk-tiered workflow: direct commit for low-risk changes, feature branch + PR for high-risk changes.
- **`harness-rule-lifecycle` command**: Inventories rules across all scopes, detects staleness (>90 days), supports deprecation and rule merging.
- **`harness-auto-remediate.yml` CI workflow**: Triggered by `harness-analysis` label on issues. Uses `claude-code-action` to analyze issues and auto-create PRs for low-risk fixes. High-risk findings get structured comments for human review.

### Security hardening

- `author_association` guard on CI workflow (OWNER/MEMBER/COLLABORATOR required)
- Issue content isolated from agent instructions (prompt injection mitigation — marked as data, read from structured JSON)
- PR body uses heredoc pattern (not `\n` escapes)

## Why This Works

The system closes the feedback loop that was previously open-ended:

1. **Generator-evaluator separation** prevents self-approval bias. Anthropic's research shows agents confidently approve their own mediocre work. Having a separate validation agent with read-only permissions ensures proposals are independently assessed.

2. **CI as deterministic backbone** provides reliable weekly detection regardless of session-level variability. The `harness-auto-remediate.yml` workflow runs in a clean environment with consistent context, unlike session hooks which depend on LLM judgment in variable contexts.

3. **Risk tiering** ensures safety: documentation/formatting changes auto-apply, while behavioral rules, hooks, CI, and template modifications require human PR review.

4. **Rule lifecycle tracking** prevents rule accumulation by flagging stale rules (>90 days without related activity) and providing deprecation/merge workflows.

## Prevention

1. **Generator-evaluator separation for all automated rule creation**: Never let the same agent that proposes a change also validate it. The `validate-harness-proposal` skill enforces this by design — if invoked by the same agent that generated the proposal, it delegates to a sub-agent.

2. **Risk classification before auto-application**: Any change touching hook scripts, CI workflows, templates, or security settings must be classified high-risk and go through PR review. Low-risk is reserved for documentation, formatting, and non-behavioral additions.

3. **Periodic rule lifecycle audits**: Run `/harness-rule-lifecycle` monthly to inventory rules, detect staleness, and merge overlapping rules. The CI workflow flags potentially stale rules automatically.

4. **Prompt injection isolation in CI agents**: When CI workflows pass user-provided content (issue titles, bodies) to agent prompts, always mark it as data, read from structured files, and separate it from instructions.

5. **Separate CI workflows for detection vs remediation**: Keep `harness-analysis.yml` (read-only, `contents: read`) separate from `harness-auto-remediate.yml` (write access, `contents: write`). Never combine detection and remediation in the same permission envelope.

## Related

- [Autonomous Harness Engineering via Claude Code Hooks](autonomous-harness-engineering-hooks-2026-03-28.md) — the hook-based detection foundation this system builds upon
- [Project-Specific Harness Rules and CI](chezmoi-project-harness-rules-and-ci-2026-03-28.md) — CI and rules infrastructure
- [Martin Fowler - Harness Engineering](https://martinfowler.com/articles/exploring-gen-ai/harness-engineering.html) — industry context
- [Anthropic - Harness Design for Long-Running Apps](https://www.anthropic.com/engineering/harness-design-long-running-apps) — generator-evaluator pattern source
- [LangChain - Improving Deep Agents with Harness Engineering](https://blog.langchain.com/improving-deep-agents-with-harness-engineering/) — trace analysis methodology
