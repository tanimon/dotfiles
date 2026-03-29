---
title: "feat: Self-Learning Autonomous Harness Engineering System"
type: feat
status: completed
date: 2026-03-29
---

# Self-Learning Autonomous Harness Engineering System

## Overview

Build an autonomous, self-learning harness engineering system that closes the feedback loop between agent failures and harness improvements. The system detects agent mistakes, proposes rule/tool/skill updates, validates them, and applies them -- minimizing manual intervention while maintaining quality gates.

## Problem Frame

The current harness engineering infrastructure has three gaps:

1. **Detection is automated but remediation is manual** -- `harness-analysis.yml` creates GitHub Issues weekly, but fixing them requires manual `/resolve-harness-issues` invocation
2. **Session-level learning relies on prompt injection** -- Claudeception and harness-activator hooks inject evaluation prompts, but the agent's decision to act is non-deterministic and unreliable
3. **No cross-session compounding** -- Knowledge captured in `docs/solutions/` is not automatically surfaced as rules, and rules are not validated for effectiveness

The goal is a system where harness improvements compound automatically: each agent session makes future sessions more reliable.

## Requirements Trace

- R1. Automate the failure-to-rule pipeline end-to-end (detect -> propose -> validate -> apply)
- R2. Capture session-level learnings into structured knowledge (skills, rules, solutions)
- R3. Validate that proposed changes actually improve harness quality before applying
- R4. Surface relevant institutional knowledge during active work sessions
- R5. Maintain human oversight via quality gates and review checkpoints
- R6. Integrate with existing infrastructure (chezmoi, hooks, CI, Claudeception, compound-engineering)
- R7. Support both greenfield (new rules/skills) and brownfield (refine existing rules) improvements

## Scope Boundaries

- **In scope**: Hook improvements, new skills/commands, CI workflow enhancements, rule lifecycle management
- **Out of scope**: Model fine-tuning, external SaaS integrations beyond GitHub, changes to Claude Code core behavior
- **Non-goal**: Full autonomy without human review -- the system proposes and applies safe changes, but flags high-risk changes for review

## Context & Research

### Relevant Code and Patterns

- `dot_claude/scripts/executable_harness-activator.sh` -- Current one-shot session hook
- `dot_claude/commands/capture-harness-feedback.md` -- Manual feedback capture command
- `dot_claude/commands/resolve-harness-issues.md` -- CI issue remediation workflow
- `dot_claude/commands/harness-health.md` -- Project harness diagnostic
- `.github/workflows/harness-analysis.yml` -- Weekly CI analysis creating GitHub Issues
- `.chezmoiexternal.toml` -- Claudeception skill pinning (SHA `62dbb91`)
- `docs/solutions/` -- 34 solution documents with YAML frontmatter
- `.claude/rules/shell-scripts.md` -- Hook conventions (exit codes, session ID, one-shot flags)

### Institutional Learnings

- **Simplified hook architecture wins** -- Four-hook system was over-engineered; single hook + LLM self-evaluation is proven (from `docs/solutions/developer-experience/autonomous-harness-engineering-hooks-2026-03-28.md`)
- **Prompt injection is the activation mechanism** -- Both Claudeception and harness-activator work by printing instructions to context; effectiveness depends on LLM judgment
- **CI feedback loop validated** -- First `harness-analysis.yml` run found 8 actionable issues (#72-#79)
- **One-shot flag after guards** -- Setting flags before context guards causes silent skips in project contexts
- **Exit code contract** -- `exit 0` = skip, `exit 1` + stderr = error; never `exit 1` without stderr

### External Research (from article analysis)

Key patterns from industry harness engineering literature:

| Pattern | Source | Applicability |
|---------|--------|---------------|
| Failure-to-rule pipeline | Hashimoto, OpenAI | Already partially implemented; needs automation |
| Generator-evaluator separation | Anthropic | Split proposal from validation to counter self-evaluation bias |
| Reasoning sandwich (high-plan, medium-impl, high-verify) | LangChain | Budget reasoning compute by phase |
| PreCompletionChecklist middleware | LangChain | Force verification before marking tasks complete |
| Trace analysis with parallel error-analysis agents | LangChain | Mirrors boosting algorithms -- each iteration targets prior failures |
| Pointer-based docs (AGENTS.md -> deeper sources) | OpenAI | Already follows this pattern with rules/ hierarchy |
| Periodic entropy management / garbage collection | OpenAI | Background agents detecting stale rules and documentation drift |
| Sprint contracts with JSON registries | Anthropic | Structured feature tracking over Markdown |

## Key Technical Decisions

- **Enhance existing hooks rather than add new ones**: The simplified single-hook architecture works. Adding hooks increases complexity and maintenance burden. Instead, make the existing harness-activator smarter by improving the prompt and adding structured output guidance.
  - *Rationale*: The four-hook architecture was already tried and rolled back. Lesson learned.

- **Use skills (not scripts) for learning logic**: Complex learning workflows belong in Claude Code skills (Markdown-based, discoverable, composable) rather than bash scripts.
  - *Rationale*: Skills can leverage the full Claude Code tool set including sub-agents, web search, and file manipulation. Bash scripts are limited to shell operations.

- **Separate proposal from validation (generator-evaluator)**: Rule proposals are generated by one agent and validated by a different agent to counter self-evaluation bias.
  - *Rationale*: Anthropic's research shows agents confidently approve their own mediocre work.

- **CI as the autonomous backbone, hooks as opportunistic enrichment**: The weekly CI workflow is the reliable, deterministic detection mechanism. Session hooks are supplementary -- they catch issues faster but are non-deterministic.
  - *Rationale*: CI runs in a clean environment with full repo access. Hooks run in user sessions with variable context.

- **Quality gates before any rule/skill creation**: Every proposed change must pass specificity, actionability, deduplication, and effectiveness checks before being applied.
  - *Rationale*: Claudeception's quality gates prevent skill sprawl; same principle applies to rules.

## Open Questions

### Resolved During Planning

- **Q: Should cross-session transcript analysis be reimplemented?** No. The previous system was removed during simplification. LLM self-evaluation via prompt injection is simpler and sufficient. The CI workflow handles systematic analysis.
- **Q: Should rules be auto-applied or require human approval?** Tiered approach: low-risk changes (documentation, formatting rules) auto-apply; high-risk changes (behavioral rules, scope changes) require PR review.

### Deferred to Implementation

- **Q: Exact threshold for "high-risk" rule changes** -- Will be refined during implementation based on initial classification attempts
- **Q: Optimal frequency for rule effectiveness validation** -- Weekly CI may be sufficient; could increase to daily if issues accumulate

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

```
Autonomous Harness Engineering Loop:

  ┌─────────────────────────────────────────────────────────────────┐
  │                     DETECTION LAYER                             │
  │                                                                 │
  │  ┌──────────────┐    ┌───────────────────┐    ┌─────────────┐  │
  │  │ CI Weekly     │    │ Session Hook      │    │ Manual       │  │
  │  │ harness-      │    │ harness-activator │    │ /capture-    │  │
  │  │ analysis.yml  │    │ (prompt inject)   │    │ harness-     │  │
  │  │               │    │                   │    │ feedback     │  │
  │  └──────┬───────┘    └───────┬───────────┘    └──────┬──────┘  │
  │         │                    │                       │          │
  │         ▼                    ▼                       ▼          │
  │  ┌──────────────────────────────────────────────────────────┐   │
  │  │              PROPOSAL GENERATION (Skill)                 │   │
  │  │  /propose-harness-improvement                            │   │
  │  │  - Analyze detected issue                                │   │
  │  │  - Search existing rules/solutions for duplicates        │   │
  │  │  - Generate structured proposal (rule, skill, or doc)    │   │
  │  │  - Classify risk tier (auto-apply vs review-required)    │   │
  │  └──────────────────────┬───────────────────────────────────┘   │
  │                         │                                       │
  └─────────────────────────┼───────────────────────────────────────┘
                            │
  ┌─────────────────────────┼───────────────────────────────────────┐
  │                         ▼              VALIDATION LAYER          │
  │  ┌──────────────────────────────────────────────────────────┐   │
  │  │              VALIDATION (Separate Agent)                 │   │
  │  │  - Deduplication check (grep existing rules/skills)      │   │
  │  │  - Specificity check (actionable, not vague)             │   │
  │  │  - Consistency check (no conflicts with existing rules)  │   │
  │  │  - Scope check (global vs project vs this-repo-only)     │   │
  │  └──────────────────────┬───────────────────────────────────┘   │
  │                         │                                       │
  │              ┌──────────┴──────────┐                            │
  │              ▼                     ▼                             │
  │     ┌────────────┐       ┌─────────────┐                       │
  │     │ Auto-Apply │       │ PR Review   │                       │
  │     │ (low-risk) │       │ (high-risk) │                       │
  │     └──────┬─────┘       └──────┬──────┘                       │
  │            │                    │                                │
  └────────────┼────────────────────┼────────────────────────────────┘
               │                    │
  ┌────────────┼────────────────────┼────────────────────────────────┐
  │            ▼                    ▼       APPLICATION LAYER        │
  │  ┌──────────────────────────────────────────────────────────┐   │
  │  │  Apply to chezmoi source tree                            │   │
  │  │  - Edit rule files (dot_claude/rules/, .claude/rules/)   │   │
  │  │  - Create/update skills                                  │   │
  │  │  - Update docs/solutions/                                │   │
  │  │  - Update CLAUDE.md Known Pitfalls                       │   │
  │  │  - Run make lint to validate                             │   │
  │  └──────────────────────┬───────────────────────────────────┘   │
  │                         │                                       │
  │                         ▼                                       │
  │  ┌──────────────────────────────────────────────────────────┐   │
  │  │  EFFECTIVENESS TRACKING                                  │   │
  │  │  - Tag rules with creation date and trigger context      │   │
  │  │  - CI tracks recurrence of same failure class            │   │
  │  │  - Stale rule detection (>90 days, no related failures)  │   │
  │  │  - Rule deprecation workflow                             │   │
  │  └──────────────────────────────────────────────────────────┘   │
  │                                                                 │
  └─────────────────────────────────────────────────────────────────┘
```

## Implementation Units

- [ ] **Unit 1: Harness Improvement Proposal Skill**

**Goal:** Create a skill that generates structured harness improvement proposals from detected issues

**Requirements:** R1, R2, R5

**Dependencies:** None

**Files:**
- Create: `dot_claude/skills/propose-harness-improvement/SKILL.md`
- Test: Manual invocation test via `/propose-harness-improvement`

**Approach:**
- Skill accepts an issue description (from CI, hook, or manual input)
- Searches existing rules (`dot_claude/rules/`, `.claude/rules/`) and `docs/solutions/` for duplicates
- Generates a structured proposal with: rule text, target file, scope (global/project), risk tier, rationale
- Risk classification: documentation/formatting changes = low-risk (auto-apply); behavioral rules, scope changes = high-risk (PR review)
- Output format: structured Markdown that can be consumed by the validation unit

**Patterns to follow:**
- Claudeception's `SKILL.md` format with YAML frontmatter and quality gates
- `dot_claude/commands/capture-harness-feedback.md` for issue analysis workflow

**Test scenarios:**
- Happy path: Given a specific agent failure description, generates a proposal with correct target file, scope, and risk tier
- Happy path: Given a duplicate issue, detects existing rule and suggests amendment rather than new rule
- Edge case: Given a vague issue description, asks for clarification rather than generating a vague rule
- Error path: Given an issue that spans multiple scopes (global + project), correctly separates into multiple proposals

**Verification:**
- Skill can be invoked via `/propose-harness-improvement` and produces structured output
- Proposals include all required fields (rule text, target, scope, risk tier, rationale)

---

- [ ] **Unit 2: Harness Proposal Validator Skill**

**Goal:** Create a separate validation skill that reviews proposals from Unit 1, enforcing quality gates

**Requirements:** R3, R5

**Dependencies:** Unit 1

**Files:**
- Create: `dot_claude/skills/validate-harness-proposal/SKILL.md`
- Test: Manual invocation with sample proposals

**Approach:**
- Accepts a proposal (output from Unit 1) as input
- Runs quality gate checklist: specificity, actionability, deduplication, consistency, scope correctness
- Uses generator-evaluator separation -- this skill must NOT have been involved in generating the proposal
- Returns verdict: approve (with optional suggestions), reject (with reason), or revise (with specific feedback)
- For approved low-risk proposals, outputs the exact file edit to apply
- For approved high-risk proposals, outputs PR description and branch naming

**Patterns to follow:**
- Claudeception's quality gates (specific, reusable, verified, not duplicate)
- `harness-engineering.md` rule writing guidelines

**Test scenarios:**
- Happy path: Valid, specific proposal passes all gates and receives approval
- Error path: Vague proposal ("handle errors better") is rejected with specific feedback
- Error path: Duplicate proposal (rule already exists) is rejected with pointer to existing rule
- Edge case: Proposal that conflicts with an existing rule is flagged for manual resolution
- Integration: Proposal from Unit 1 flows through validation and receives structured verdict

**Verification:**
- Validator catches known-bad proposals (vague, duplicate, conflicting)
- Approved proposals include actionable file edits or PR descriptions

---

- [ ] **Unit 3: Enhanced Harness Activator Hook**

**Goal:** Improve the session-level hook to produce structured output that feeds into the proposal skill

**Requirements:** R1, R2, R6

**Dependencies:** Unit 1

**Files:**
- Modify: `dot_claude/scripts/executable_harness-activator.sh`
- Test: `Makefile` target `test-scripts` (existing smoke tests)

**Approach:**
- Keep the one-shot flag pattern and context guards unchanged
- Enhance the prompt injection text to instruct the agent to:
  1. Evaluate session for harness improvement opportunities (existing behavior)
  2. If improvement found, invoke `/propose-harness-improvement` skill (new behavior)
  3. Include structured context: what failed, why, proposed fix category
- Add guidance for the agent to check `docs/solutions/` before proposing (avoid reinventing known solutions)
- Keep the script under ~80 lines; move complex logic to the skill

**Patterns to follow:**
- Existing `harness-activator.sh` structure
- Claudeception activator's prompt injection pattern
- `.claude/rules/shell-scripts.md` hook conventions

**Test scenarios:**
- Happy path: Script outputs structured evaluation prompt when run in a project directory with a valid session ID
- Happy path: Script exits 0 silently on duplicate session (one-shot flag works)
- Edge case: Script exits 0 when run from HOME directory (context guard)
- Error path: Script handles missing `jq` gracefully (exit 0 with warning)

**Verification:**
- Existing `make test-scripts` passes
- Output text includes reference to `/propose-harness-improvement` skill
- One-shot flag is set AFTER context guards

---

- [ ] **Unit 4: Automated Rule Application Command**

**Goal:** Create a command that applies validated proposals to the chezmoi source tree

**Requirements:** R1, R7

**Dependencies:** Unit 2

**Files:**
- Create: `dot_claude/commands/apply-harness-proposal.md`
- Modify: `dot_claude/commands/resolve-harness-issues.md` (integrate proposal workflow)

**Approach:**
- For low-risk approved proposals: directly edit the target file, run `make lint`, commit
- For high-risk approved proposals: create feature branch, apply changes, create PR with proposal rationale
- Both paths validate changes with `make lint` before committing
- Integrate with existing `/resolve-harness-issues` by adding an option to use the proposal workflow instead of ad-hoc fixes
- Track applied proposals in a lightweight log (append to `docs/solutions/` or a dedicated tracking file)

**Patterns to follow:**
- `dot_claude/commands/resolve-harness-issues.md` for branch/PR workflow
- Git workflow rules from `~/.claude/rules/common/git-workflow.md`

**Test scenarios:**
- Happy path: Low-risk proposal is applied directly, lint passes, change is committed
- Happy path: High-risk proposal creates a feature branch and opens a PR
- Error path: Proposal that causes lint failure is rolled back with error message
- Edge case: Proposal targeting a `.tmpl` file includes template-safe modifications
- Integration: End-to-end flow from detection -> proposal -> validation -> application

**Verification:**
- Applied changes pass `make lint`
- PR descriptions include proposal rationale and risk classification
- No changes applied to deployed targets (only chezmoi source)

---

- [ ] **Unit 5: Rule Effectiveness Tracking**

**Goal:** Add metadata to rules and a CI check that tracks whether rules prevent recurrence

**Requirements:** R3, R7

**Dependencies:** Unit 4

**Files:**
- Modify: `.github/workflows/harness-analysis.yml` (add effectiveness check)
- Create: `dot_claude/commands/harness-rule-lifecycle.md` (rule lifecycle management)

**Approach:**
- Add optional YAML frontmatter to rule files: `date`, `trigger` (what failure prompted this rule), `last_validated` (date of last CI pass)
- Enhance `harness-analysis.yml` to include a rule effectiveness check phase:
  1. List all rules with `trigger` metadata
  2. Search recent CI issues and session logs for recurrence of the same trigger
  3. Flag rules that have not prevented their target failure (ineffective)
  4. Flag rules older than 90 days with no related activity (potentially stale)
- Create `/harness-rule-lifecycle` command for manual rule review: list rules by age, effectiveness, and scope

**Patterns to follow:**
- `harness-analysis.yml` existing prompt structure
- YAML frontmatter pattern from `docs/solutions/` documents

**Test scenarios:**
- Happy path: New rule with trigger metadata is tracked in subsequent CI runs
- Happy path: Stale rule (>90 days, no activity) is flagged for review
- Edge case: Rule without frontmatter is skipped gracefully (not all rules need tracking)
- Error path: CI workflow handles missing `gh` CLI or API failures without blocking other checks

**Verification:**
- CI workflow includes rule effectiveness reporting in `GITHUB_STEP_SUMMARY`
- `/harness-rule-lifecycle` lists rules with age and effectiveness indicators

---

- [ ] **Unit 6: Knowledge Compounding Integration**

**Goal:** Connect the harness improvement loop with `docs/solutions/` and Claudeception for persistent knowledge capture

**Requirements:** R2, R4, R6

**Dependencies:** Units 1, 2

**Files:**
- Create: `dot_claude/skills/compound-harness-knowledge/SKILL.md`
- Modify: `dot_claude/scripts/executable_harness-activator.sh` (add compounding prompt)

**Approach:**
- Create a skill that converts resolved harness issues into structured `docs/solutions/` documents
- Follow the existing solution document format: YAML frontmatter + Problem/Solution/Prevention/Related sections
- Cross-reference with existing solutions to avoid duplicates
- Update the harness-activator prompt to suggest compounding after successful improvements
- Integrate with Claudeception: if the improvement involved a novel debugging technique, suggest skill extraction

**Patterns to follow:**
- Existing `docs/solutions/` document format
- Claudeception skill extraction workflow
- `/ce:compound` command from compound-engineering plugin

**Test scenarios:**
- Happy path: Resolved harness issue produces a properly formatted solution document
- Happy path: Duplicate detection prevents creating a redundant solution document
- Edge case: Issue that spans multiple categories is filed under the most relevant one
- Integration: Full loop -- CI detects issue -> proposal -> validation -> application -> solution document

**Verification:**
- Generated solution documents match existing format and pass any structure checks
- Cross-references to related solutions are accurate

---

- [ ] **Unit 7: Autonomous Orchestration Enhancement**

**Goal:** Enhance `harness-analysis.yml` to optionally auto-remediate low-risk findings

**Requirements:** R1, R5

**Dependencies:** Units 1-4

**Files:**
- Modify: `.github/workflows/harness-analysis.yml`
- Create: `.github/workflows/harness-auto-remediate.yml` (separate workflow for safety)

**Approach:**
- Keep the existing analysis workflow unchanged (detection only)
- Create a new workflow `harness-auto-remediate.yml` triggered by `harness-analysis` label on issues
- This workflow:
  1. Reads the issue body (structured harness finding)
  2. Invokes the proposal skill via `claude-code-action`
  3. Runs the validation skill
  4. For approved low-risk proposals: creates a PR automatically
  5. For high-risk proposals: adds a comment to the issue with the proposal for human review
- Use `workflow_dispatch` for manual trigger and `issues.labeled` for automatic trigger
- Safety: the workflow only creates PRs, never pushes to main. Human merge required.

**Patterns to follow:**
- `harness-analysis.yml` workflow structure
- `claude-code-review.yml` for `claude-code-action` configuration
- `docs/solutions/integration-issues/claude-code-review-workflow-tool-permissions-2026-03-29.md` for permission setup

**Test scenarios:**
- Happy path: Low-risk issue triggers auto-remediation and creates a PR
- Happy path: High-risk issue triggers proposal comment but no PR
- Error path: Workflow handles `claude-code-action` failures gracefully (posts error comment on issue)
- Edge case: Multiple issues labeled simultaneously are processed without race conditions (sequential, not parallel)
- Integration: End-to-end from issue creation to PR creation

**Verification:**
- PRs created by auto-remediation pass `make lint` in CI
- High-risk issues receive informative comments rather than auto-PRs
- Workflow permissions are correctly scoped (issues: write, pull-requests: write, contents: write)

## System-Wide Impact

- **Interaction graph**: Harness-activator hook -> propose-harness-improvement skill -> validate-harness-proposal skill -> apply-harness-proposal command -> chezmoi source tree. CI workflow -> harness-auto-remediate workflow -> claude-code-action -> same proposal/validation pipeline.
- **Error propagation**: Hook failures exit 0 (silent skip, no user disruption). Skill failures surface as normal Claude Code errors. CI workflow failures post error comments on issues.
- **State lifecycle risks**: One-shot flags in `/tmp` auto-clean on reboot. Rule metadata in YAML frontmatter is persistent but optional. No database or external state store.
- **API surface parity**: No external API. All interactions via Claude Code skills, commands, hooks, and GitHub Actions.
- **Integration coverage**: Full pipeline test (detection -> proposal -> validation -> application -> verification) needed as an integration scenario.
- **Unchanged invariants**: Existing hook exit code contract, existing CI lint targets, existing `docs/solutions/` format, existing chezmoi naming conventions. The system adds new files and modifies existing ones but does not change established patterns.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Self-evaluation bias in proposals | Generator-evaluator separation (Units 1 vs 2); validation by a different agent |
| Rule sprawl from excessive proposals | Quality gates in validator skill; deduplication check against existing rules |
| CI cost from auto-remediation workflow | Workflow only triggers on labeled issues; rate-limit via GitHub Actions concurrency |
| Breaking existing hooks with activator changes | Existing smoke tests (`make test-scripts`) validate before deployment |
| Stale rules accumulating over time | Rule lifecycle tracking (Unit 5) with 90-day staleness flag |
| Auto-applied low-risk changes introducing regressions | All changes must pass `make lint`; auto-apply only creates commits, never pushes to main |

## Sources & References

- Related code: `dot_claude/scripts/executable_harness-activator.sh`, `.github/workflows/harness-analysis.yml`
- Related docs: `docs/solutions/developer-experience/autonomous-harness-engineering-hooks-2026-03-28.md`
- External: [Martin Fowler - Harness Engineering](https://martinfowler.com/articles/exploring-gen-ai/harness-engineering.html)
- External: [Anthropic - Harness Design for Long-Running Apps](https://www.anthropic.com/engineering/harness-design-long-running-apps)
- External: [Anthropic - Effective Harnesses for Long-Running Agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents)
- External: [Mitchell Hashimoto - My AI Adoption Journey](https://mitchellh.com/writing/my-ai-adoption-journey)
- External: [LangChain - Improving Deep Agents with Harness Engineering](https://blog.langchain.com/improving-deep-agents-with-harness-engineering/)
- External: [Claudeception](https://github.com/blader/Claudeception)
- External: [Compound Engineering Plugin](https://github.com/EveryInc/compound-engineering-plugin)
