---
title: "feat: Integrate ECC Continuous Learning into harness engineering system"
type: feat
status: completed
date: 2026-04-03
deepened: 2026-04-03
---

# feat: Integrate ECC Continuous Learning into harness engineering system

## Overview

Integrate the Continuous Learning v2.1 system from [everything-claude-code](https://github.com/affaan-m/everything-claude-code) (ECC) into the existing self-learning harness engineering system. ECC provides deterministic observation capture, confidence-scored instincts, background pattern analysis, and an evolution pipeline that complement the existing propose/validate/apply harness pipeline. The integration bridges ECC's automatic learning with the existing rule/solution/skill storage tiers.

## Problem Frame

The current harness engineering system relies on **agent initiative** to capture learnings — the harness-activator hook prints a reminder, but whether the agent acts on it is non-deterministic. Key gaps identified in repo research:

1. **No deterministic observation capture** — learning depends on the agent remembering to self-evaluate
2. **No cross-session feedback mechanism** — removed during the 2026-03-28 simplification
3. **No quantitative rule effectiveness measurement** — staleness is proxied by file age only
4. **Memory system disconnected from harness pipeline** — MEMORY.md accumulates passively
5. **No confidence scoring or temporal decay** — rules are binary (exists or doesn't)

ECC's Continuous Learning v2.1 addresses all five gaps with: hook-based 100% observation capture, a background Haiku-model observer, confidence-scored instincts with decay, project-scoped learning, and an evolution pipeline that crystallizes patterns into skills.

## Requirements Trace

- R1. Enable ECC observation capture hooks for deterministic data collection
- R2. Configure and manage the ECC observer (background Haiku analysis) via chezmoi
- R3. Bridge ECC instincts with the existing harness storage tiers (rules, docs/solutions, skills)
- R4. Add SessionStart hook to load project-scoped instincts into session context
- R5. Integrate instinct confidence scoring with rule effectiveness tracking
- R6. Manage `~/.claude/homunculus/` directory lifecycle via `.chezmoiignore`
- R7. Create a bridge command that promotes high-confidence instincts to harness rules
- R8. Preserve the existing generator-evaluator separation for rule creation

## Scope Boundaries

- NOT replacing the existing harness pipeline — ECC continuous learning augments it
- NOT modifying ECC plugin source files — all integration is through configuration and bridge scripts
- NOT enabling ECC's `install.sh` module system — rules are already managed via the declarative sync pattern
- NOT building a custom observer — using ECC's existing observer-loop.sh with Haiku
- NOT managing `~/.claude/homunculus/` contents via chezmoi — this is runtime state (like `~/.claude/projects/`)

## Context & Research

### Relevant Code and Patterns

- `dot_claude/settings.json.tmpl` — hook configuration (lines 148-217)
- `dot_claude/scripts/executable_harness-activator.sh` — existing session hook with one-shot pattern
- `dot_claude/skills/propose-harness-improvement/SKILL.md` — proposal generator
- `dot_claude/skills/validate-harness-proposal/SKILL.md` — proposal validator
- `dot_claude/commands/harness-rule-lifecycle.md` — rule inventory and staleness
- `.chezmoiignore` — exclusion patterns for dynamic directories
- ECC plugin: `~/.claude/plugins/marketplaces/everything-claude-code/`
  - `skills/continuous-learning-v2/config.json` — observer config (disabled by default)
  - `skills/continuous-learning-v2/hooks/observe.sh` — observation capture hook
  - `skills/continuous-learning-v2/agents/observer-loop.sh` — background analysis daemon
  - `hooks/hooks.json` — plugin hooks including `pre:observe` and `post:observe`
  - `commands/learn-eval.md` — quality-gated learning extraction
  - `commands/instinct-status.md` — instinct visualization
  - `commands/evolve.md` — instinct clustering into skills/commands/agents

### Institutional Learnings

- `docs/solutions/developer-experience/self-learning-harness-engineering-system-2026-03-29.md` — system architecture doc; three-layer detection/proposal/application design
- `docs/solutions/developer-experience/autonomous-harness-engineering-hooks-2026-03-28.md` — hook evolution; LLM-based analysis > bash grep; session identity via jq
- `docs/solutions/integration-issues/claude-code-hook-exit-code-and-stderr-semantics.md` — hook exit code contract

### External References

- ECC repository: https://github.com/affaan-m/everything-claude-code
- ECC Continuous Learning v2.1 SKILL.md — instinct model, confidence scoring, project detection
- ECC instinct-cli.py — Python CLI for instinct management (status, evolve, promote, prune)

## Key Technical Decisions

- **Use ECC plugin hooks as-is**: The `pre:observe` and `post:observe` hooks in ECC's `hooks.json` are already active via the plugin system. No need to duplicate in `settings.json.tmpl`. The plugin hook system merges hooks from all enabled plugins.

- **Enable observer via chezmoi-managed config override**: ECC's `config.json` has `observer.enabled: false` by default. Rather than modifying the plugin file (which gets overwritten on marketplace update), create a chezmoi-managed config override or use environment variables to enable the observer.

- **Bridge instincts to rules via a new command, not automation**: High-confidence instincts should be reviewed before becoming harness rules. A new `/promote-instincts` command bridges the gap, using the existing propose/validate pipeline for quality gating. This preserves generator-evaluator separation.

- **`.chezmoiignore` for homunculus**: The `~/.claude/homunculus/` directory is runtime state (observations, instincts, project registry). Add it to `.chezmoiignore` like other dynamic directories.

- **SessionStart instinct loading via harness-activator enhancement**: Rather than adding a separate SessionStart hook, enhance the existing harness-activator to also surface relevant instincts on first prompt. This avoids hook proliferation.

## Open Questions

### Resolved During Planning

- **Q: How do ECC plugin hooks interact with user hooks in settings.json.tmpl?**
  Resolution: Claude Code merges hooks from all sources (settings.json + enabled plugins). ECC's `hooks.json` provides `pre:observe` and `post:observe` as async hooks with 10s timeout. They coexist with user hooks. No conflict since they use different IDs.

- **Q: Will the observer daemon work inside the Seatbelt sandbox?**
  Resolution: The observer spawns `claude --model haiku` which would need sandbox access. Since the observer runs from the ECC plugin directory (under `~/.claude/plugins/`), and the sandbox wrapper only wraps the initial `claude` invocation, the background daemon should work. However, observation files write to `~/.claude/homunculus/` which needs to be in the sandbox allowlist. This will be verified during implementation.

- **Q: Does enabling the observer require Python?**
  Resolution: Yes — `instinct-cli.py` requires Python 3. macOS ships with Python 3 via Xcode CLT. The observer-loop.sh itself is pure bash but spawns `claude` CLI for analysis. The `/instinct-status`, `/evolve`, and `/prune` commands use Python.

### Deferred to Implementation

- **Exact sandbox allowlist entries for homunculus directory** — depends on testing with the observer running inside sandbox
- **Observer resource consumption** — Haiku calls are cheap but frequency tuning may be needed after observing real usage patterns
- **Instinct-to-rule format mapping** — the exact transformation from ECC YAML-frontmatter instinct format to the existing rule markdown format will be determined when building the bridge command

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

```
┌─────────────────────────────────────────────────────────────┐
│                    Session Activity                          │
└─────────────┬───────────────────────────────────────────────┘
              │
              ▼
┌─────────────────────────┐     ┌──────────────────────────┐
│  ECC Plugin Hooks       │     │  Existing Harness Hooks   │
│  (pre/post:observe)     │     │  (harness-activator)      │
│  100% tool capture      │     │  (claudeception-activator)│
└─────────┬───────────────┘     └──────────┬───────────────┘
          │                                │
          ▼                                ▼
┌─────────────────────────┐     ┌──────────────────────────┐
│  ~/.claude/homunculus/  │     │  Agent self-evaluation    │
│  observations.jsonl     │     │  (non-deterministic)      │
│  (deterministic)        │     └──────────┬───────────────┘
└─────────┬───────────────┘                │
          │                                ▼
          ▼                     ┌──────────────────────────┐
┌─────────────────────────┐     │  propose → validate →    │
│  Observer (Haiku bg)    │     │  apply pipeline           │
│  Pattern detection      │     │  (rules, docs/solutions)  │
└─────────┬───────────────┘     └──────────────────────────┘
          │                                ▲
          ▼                                │
┌─────────────────────────┐     ┌──────────────────────────┐
│  Instincts              │────▶│  /promote-instincts      │
│  (confidence-scored)    │     │  Bridge command           │
│  (project/global scope) │     │  (quality-gated)         │
└─────────┬───────────────┘     └──────────────────────────┘
          │
          ▼
┌─────────────────────────┐
│  /evolve                │
│  Instincts → Skills     │
│  (ECC native)           │
└─────────────────────────┘
```

Two learning paths operate in parallel:
1. **Deterministic path** (new): ECC hooks → observations → observer → instincts → optional promotion to rules
2. **Initiative path** (existing): harness-activator reminder → agent self-evaluation → propose/validate/apply

The bridge command (`/promote-instincts`) connects the deterministic path to the existing quality-gated pipeline.

## Implementation Units

- [ ] **Unit 1: Add homunculus to .chezmoiignore**

  **Goal:** Ensure `~/.claude/homunculus/` is excluded from chezmoi management as runtime state.

  **Requirements:** R6

  **Dependencies:** None

  **Files:**
  - Modify: `.chezmoiignore`

  **Approach:**
  - Add `homunculus/` pattern to the `.claude/` exclusion block in `.chezmoiignore`
  - Follow existing pattern used for `projects/`, `sessions/`, `cache/` etc.

  **Patterns to follow:**
  - Existing `.chezmoiignore` exclusion block for `~/.claude/` dynamic directories

  **Test scenarios:**
  - Happy path: `chezmoi managed | grep homunculus` returns no results after adding exclusion
  - Edge case: Verify existing exclusions for `projects/`, `sessions/` still work

  **Verification:**
  - `chezmoi managed | grep homunculus` returns empty

- [ ] **Unit 2: Enable ECC observer via chezmoi-managed environment variable**

  **Goal:** Enable the ECC background observer that analyzes observations and creates instincts, managed declaratively via chezmoi.

  **Requirements:** R1, R2

  **Dependencies:** Unit 1

  **Files:**
  - Modify: `dot_claude/settings.json.tmpl` (env section)

  **Approach:**
  - ECC's `observe.sh` checks environment variables for configuration overrides. Add `ECC_OBSERVER_ENABLED: "true"` to the `env` section of `settings.json.tmpl`
  - Also set `ECC_OBSERVER_SIGNAL_EVERY_N: "20"` (default, explicit for visibility)
  - The observer lazy-starts from `observe.sh` when enabled — no separate startup hook needed
  - If ECC does not support env-based observer enablement, the fallback approach is a `run_onchange_` script that patches `~/.claude/plugins/marketplaces/everything-claude-code/skills/continuous-learning-v2/config.json` to set `observer.enabled: true`. This requires re-running when the plugin updates.

  **Patterns to follow:**
  - Existing `env` entries in `settings.json.tmpl` (e.g., `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`, `_ZO_DOCTOR`)

  **Test scenarios:**
  - Happy path: After `chezmoi apply`, verify environment variables are set in Claude Code sessions
  - Edge case: Verify observer does not start if Python 3 is unavailable (graceful degradation)
  - Integration: After a session with multiple tool uses, verify `~/.claude/homunculus/` contains observation data

  **Verification:**
  - `chezmoi apply --dry-run` shows the new env vars
  - After a session, `~/.claude/homunculus/projects/` contains project-specific directories

- [ ] **Unit 3: Add sandbox allowlist entries for homunculus**

  **Goal:** Ensure the observer and observation capture work inside the macOS Seatbelt sandbox.

  **Requirements:** R1, R2

  **Dependencies:** Unit 2

  **Files:**
  - Modify: `dot_config/safehouse/config.tmpl` (if safehouse is the active sandbox)
  - Modify: `dot_config/cco/allow-paths.tmpl` (cco fallback)

  **Approach:**
  - Add `~/.claude/homunculus/` to the sandbox write allowlist
  - The observer writes to `observations.jsonl` and `instincts/` under this path
  - The observer also spawns `claude --model haiku` — verify this works within sandbox context (the spawned process may inherit sandbox restrictions)

  **Patterns to follow:**
  - Existing sandbox allowlist entries for `~/.claude/` paths

  **Test scenarios:**
  - Happy path: Observation capture works inside sandboxed Claude Code session
  - Error path: If sandbox blocks writes, observe.sh exits 0 gracefully (it has error handling)
  - Integration: Observer daemon can spawn Haiku analysis from within sandbox

  **Verification:**
  - Observation files appear in `~/.claude/homunculus/` after sandboxed session
  - No EPERM errors in `~/.claude/logs/`

- [ ] **Unit 4: Enhance harness-activator with instinct context loading**

  **Goal:** Surface relevant project-scoped instincts to the agent at session start, connecting ECC's learned patterns to the existing harness reminder flow.

  **Requirements:** R4, R5

  **Dependencies:** Unit 1, Unit 2

  **Files:**
  - Modify: `dot_claude/scripts/executable_harness-activator.sh`

  **Approach:**
  - After the existing harness evaluation reminder, add a section that reads high-confidence instincts (>= 0.7) from the detected project's instinct directory
  - Use the same project detection approach as ECC (git remote URL hash) to find the right project directory
  - Output a concise summary of active instincts (trigger + action, max 10) as additional context
  - Keep it lightweight — the instinct files are small YAML-frontmatter markdown, parse with `grep`/`awk` not Python
  - Preserve the one-shot behavior (instincts loaded once per session, same flag file)

  **Patterns to follow:**
  - Existing harness-activator.sh structure (guards, one-shot flag, session ID extraction)
  - ECC's `detect-project.sh` for project hash computation

  **Test scenarios:**
  - Happy path: With 3 instincts at confidence >= 0.7, all 3 are surfaced in the reminder
  - Edge case: No instincts exist yet — reminder outputs normally without instinct section
  - Edge case: More than 10 high-confidence instincts — only top 10 by confidence shown
  - Error path: homunculus directory does not exist — skip instinct loading gracefully (exit 0)
  - Integration: Instinct context appears in harness-activator output alongside the existing evaluation reminder

  **Verification:**
  - After a session in a project with instincts, the harness-activator output includes an instinct summary
  - Without instincts, the output is identical to the current behavior

- [ ] **Unit 5: Create /promote-instincts bridge command**

  **Goal:** Create a command that bridges ECC's instinct system with the existing harness rule pipeline, allowing quality-gated promotion of high-confidence instincts to permanent rules.

  **Requirements:** R3, R7, R8

  **Dependencies:** Unit 2

  **Files:**
  - Create: `dot_claude/commands/promote-instincts.md`

  **Approach:**
  - The command reads instincts from the current project and global scope
  - Filters to high-confidence (>= 0.7) instincts that are not already covered by existing rules
  - For each candidate, generates a structured rule proposal compatible with the existing `propose-harness-improvement` format
  - Delegates to the validate-harness-proposal skill for quality gating (preserving generator-evaluator separation)
  - Approved instincts are transformed into rule files in the appropriate scope (project `.claude/rules/` or global `dot_claude/rules/`)
  - The command also suggests when instincts should become skills via `/evolve` instead of rules

  **Patterns to follow:**
  - `dot_claude/commands/apply-harness-proposal.md` — risk-tiered application
  - `dot_claude/commands/harness-rule-lifecycle.md` — rule inventory pattern
  - ECC's instinct format (YAML frontmatter with id, trigger, confidence, domain, scope)

  **Test scenarios:**
  - Happy path: 2 instincts at confidence 0.8+ are promoted to rules after validation
  - Edge case: All instincts already covered by existing rules — command reports "nothing to promote"
  - Edge case: Instinct contradicts existing rule — validation catches the conflict and rejects
  - Error path: No instincts exist — clear message and exit
  - Integration: Promoted rule passes `make lint` and integrates with `harness-rule-lifecycle` inventory

  **Verification:**
  - New rule files appear in the correct scope directory
  - `make lint` passes after promotion
  - `/harness-rule-lifecycle` lists the new rules in its inventory

- [ ] **Unit 6: Add instinct confidence to harness-analysis CI**

  **Goal:** Extend the weekly harness-analysis CI to include instinct health reporting alongside rule effectiveness.

  **Requirements:** R5

  **Dependencies:** Unit 2

  **Files:**
  - Modify: `.github/workflows/harness-analysis.yml`

  **Approach:**
  - Add a new analysis area to the harness-analysis prompt: "Instinct Health"
  - Check for instincts with decaying confidence (< 0.3), contradicting instincts (same trigger, different actions), and instincts ready for promotion (>= 0.8 in 2+ projects)
  - Report as part of the existing issue creation flow
  - Keep the existing 7 analysis areas unchanged; add this as area 8

  **Patterns to follow:**
  - Existing harness-analysis.yml prompt structure with numbered analysis areas
  - Existing issue creation format (## Problem, ## Files, ## Suggested Action)

  **Test scenarios:**
  - Happy path: CI run detects 2 instincts ready for promotion, creates issue
  - Edge case: No homunculus directory exists — analysis area reports "Continuous learning not yet initialized" and moves on
  - Edge case: Instincts exist but all healthy — no issue created for this area

  **Verification:**
  - `actionlint` passes on the modified workflow
  - CI prompt includes the new analysis area

- [ ] **Unit 7: Update CLAUDE.md with continuous learning documentation**

  **Goal:** Document the integrated continuous learning system in CLAUDE.md so future agents understand the dual-path learning architecture.

  **Requirements:** R1-R8 (documentation)

  **Dependencies:** Units 1-6

  **Files:**
  - Modify: `CLAUDE.md`

  **Approach:**
  - Add a section under Architecture explaining the dual-path learning system
  - Document new commands: `/instinct-status`, `/evolve`, `/promote-instincts`, `/prune`
  - Note the relationship between ECC instincts and harness rules
  - Keep it concise — reference ECC's own SKILL.md for full documentation
  - Add to Common Commands section

  **Patterns to follow:**
  - Existing CLAUDE.md Architecture section structure
  - Existing Common Commands format

  **Test scenarios:**
  - Test expectation: none -- documentation only

  **Verification:**
  - `make lint` passes (no sensitive info in docs)
  - Documentation accurately describes the implemented system

- [ ] **Unit 8: Update harness-engineering rule with instinct integration guidance**

  **Goal:** Extend the harness-engineering rule to guide agents on when to use instincts vs rules vs docs/solutions.

  **Requirements:** R3, R8

  **Dependencies:** Units 1-6

  **Files:**
  - Modify: `dot_claude/rules/common/harness-engineering.md`

  **Approach:**
  - Add a section on the instinct-rule relationship: instincts are automatic, low-friction, confidence-scored observations; rules are validated, permanent, high-quality guidelines
  - Update the Feedback Loop Hierarchy to include instincts as a new tier between hooks and rules
  - Provide guidance: when an agent detects a pattern, prefer letting the observer capture it as an instinct first; only escalate to propose-harness-improvement for clear, immediate rule-worthy fixes

  **Patterns to follow:**
  - Existing harness-engineering.md structure (Core Principle, Pipeline, Guidelines, Hierarchy, Anti-Patterns)

  **Test scenarios:**
  - Test expectation: none -- rule documentation only

  **Verification:**
  - Rule file is well-formed markdown
  - Guidance is consistent with the implemented system

## System-Wide Impact

- **Interaction graph:** ECC plugin hooks fire on every tool use (async, non-blocking). The observer daemon runs in background, spawning Haiku analysis. The harness-activator now reads instinct files. The new `/promote-instincts` command invokes the existing validate-harness-proposal skill.
- **Error propagation:** ECC hooks exit 0 on all errors (async, non-blocking design). Observer failures are logged but do not affect main session. Harness-activator instinct loading failures are caught and skipped silently.
- **State lifecycle risks:** `observations.jsonl` grows unbounded without the observer running — ECC handles auto-archiving at 10MB and auto-purging at 30 days. If observer is disabled but hooks are active, observations accumulate. The `.chezmoiignore` ensures chezmoi never touches this state.
- **API surface parity:** The existing `/learn-eval` (ECC) and `/claudeception` (Claudeception plugin) commands remain available alongside the new `/promote-instincts`. Each serves a different purpose: `/learn-eval` for session-level extraction, `/claudeception` for skill creation, `/promote-instincts` for instinct-to-rule promotion.
- **Unchanged invariants:** The existing propose/validate/apply pipeline is not modified. Generator-evaluator separation is preserved. Risk-tiered application (auto-apply vs PR) is unchanged. The harness-activator's one-shot behavior and context guards are preserved.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Observer Haiku calls add cost | Observer is lazy-started, rate-limited (5min interval, 20 observation minimum), and uses cheapest model. Cost is ~$0.01-0.05 per analysis cycle |
| Sandbox blocks observer writes | Add homunculus to sandbox allowlist (Unit 3). ECC hooks fail gracefully on write errors |
| Observer daemon accumulates stale processes | ECC has idle detection (30min timeout) and PID file management. Add monitoring note to CLAUDE.md |
| Python 3 not available on fresh machine | instinct-cli.py features degrade gracefully. Core observation capture (bash) still works |
| ECC plugin updates overwrite config.json | Use environment variables (Unit 2) rather than patching config.json directly |
| Instinct-rule duplication | `/promote-instincts` checks for existing rules before promoting. harness-analysis CI detects contradictions |

## Documentation / Operational Notes

- New commands available after integration: `/instinct-status`, `/evolve`, `/promote-instincts`, `/prune`
- Observer health can be checked via `~/.claude/plugins/marketplaces/everything-claude-code/skills/continuous-learning-v2/agents/start-observer.sh status`
- Observation data is ephemeral (30-day auto-purge) — not backed up
- Instincts are persistent but have confidence decay (-0.02/week without confirming observations)

## Sources & References

- **ECC repository:** https://github.com/affaan-m/everything-claude-code
- **ECC Continuous Learning v2.1 SKILL.md:** `~/.claude/plugins/marketplaces/everything-claude-code/skills/continuous-learning-v2/SKILL.md`
- Related plans: `docs/plans/2026-04-03-006-feat-enable-everything-claude-code-plugin-plan.md` (completed), `docs/plans/2026-04-03-007-feat-ecc-rules-declarative-install-plan.md` (completed)
- Related solution: `docs/solutions/developer-experience/self-learning-harness-engineering-system-2026-03-29.md`
- Related solution: `docs/solutions/developer-experience/autonomous-harness-engineering-hooks-2026-03-28.md`
