---
date: 2026-04-04
topic: autonomous-harness-evolution
focus: Improve the autonomous evolution harness engineering system, leveraging ECC and compound-engineering plugins
---

# Ideation: Autonomous Harness Evolution System

## Codebase Context

**Project shape:** chezmoi-managed dotfiles repo for macOS. Languages: Bash, JSON, YAML, TypeScript. Zero non-dotfile code; fully configuration-driven.

**Current harness architecture (5-tier feedback loop):**

1. **Hooks** (automatic, immediate): PostToolUse formatters, harness-activator prompt injection
2. **Instincts** (ECC observer): Haiku model analyzes tool calls -> confidence-scored behaviors (0.3-0.9, decay -0.02/week)
3. **Rules** (validated, permanent): Permanent guidelines via propose->validate->apply pipeline with generator-evaluator separation
4. **CLAUDE.md** (project-scoped): Architecture, commands, pitfalls
5. **docs/solutions/** (historical): Past problem resolutions

**Two learning paths:**

- **Deterministic path**: ECC hooks -> observations.jsonl -> Haiku observer -> instincts -> /promote-instincts -> validate -> apply
- **Initiative path**: harness-activator reminder -> agent self-evaluation -> propose -> validate -> apply

**Available plugin capabilities:**

- ECC: continuous-learning-v2 (observer + instincts), /evolve (instinct clustering -> skills), /promote-instincts (instinct -> rule bridge), eval-harness, agentic-engineering
- compound-engineering: ce:compound (knowledge capture), capture-harness-feedback, learnings-researcher

**Known gaps:**

- Instinct promotion not automated (manual /promote-instincts required)
- Rule effectiveness unmeasured (harness-rule-lifecycle detects staleness by heuristics, not impact)
- Cross-project learning blocked (instincts siloed per project hash)
- Session learning probabilistic (harness-activator fires once, agent may deprioritize)
- /evolve underutilized (no trigger mechanism)

**Past learnings:**

- Generator-evaluator separation is critical (self-approval bias is documented)
- LLM self-evaluation > bash grep for transcript analysis (two failed attempts at bash-based analysis)
- Risk tiering for auto-application must be maintained (hooks/CI/security require PR review)
- Deterministic path captures 100% of tool calls; initiative path is probabilistic — build on the former

## Ranked Ideas

### 1. Closed-Loop Rule Lifecycle (auto-promote + effectiveness measurement + auto-demote)

**Description:** When an instinct reaches confidence >= 0.7, automatically trigger the propose->validate->apply pipeline without human invocation. After application, attach effectiveness telemetry to each rule (adherence rate: how often the agent follows the rule when applicable; impact rate: how often violating the rule led to corrections). Rules that show no measurable impact within a rolling window are demoted back to instincts with decaying confidence. This transforms the one-way rule accumulation into a bidirectional, self-optimizing lifecycle.

**Rationale:** The single biggest bottleneck is the manual instinct->rule bridge. Auto-promotion alone is insufficient — without effectiveness measurement and auto-demotion, rules accumulate without accountability. Combining all three creates a closed loop where the rule set self-optimizes. The existing propose/validate/apply pipeline + ECC observer observations provide the infrastructure; only the trigger and feedback mechanisms are missing.

**Downsides:** Attribution is inherently hard — a rule that "prevented" a failure produces no observable event. Demotion threshold miscalibration could remove useful rules. Requires defining effectiveness metrics that balance false positives/negatives.

**Confidence:** 85%
**Complexity:** High
**Status:** Explored (brainstorm: `docs/brainstorms/2026-04-04-closed-loop-rule-lifecycle-requirements.md`)

### 2. Cross-Project Instinct Federation

**Description:** Create a shared instinct namespace at `~/.claude/homunculus/global/instincts.jsonl`. When an instinct reaches high confidence in 2+ project hashes, propagate it to the global namespace at reduced confidence (0.3). Global instincts are loaded in all projects filtered by relevance (language, framework, toolchain overlap) and must independently re-earn confidence through local observations. Cross-project confirmation gives a +0.1 confidence bonus, accelerating promotion to global rules.

**Rationale:** Every project starts from a blank instinct slate despite the user working across repositories with overlapping patterns. Federation creates network effects: N projects learning M instincts each produces N*M potential cross-pollinations. The ECC project hash (git remote URL SHA256) provides the identity mechanism; the instinct storage format is already defined.

**Downsides:** Context mismatch risk — instincts valid in one project may be harmful in another. Similarity filtering precision is critical. Adds complexity to the instinct store.

**Confidence:** 70%
**Complexity:** High
**Status:** Unexplored

### 3. Session-Start Deterministic Learning Injection

**Description:** Replace the probabilistic harness-activator with a data-driven deterministic briefing. At session start, a hook reads the last N observations + near-promotion instincts (confidence >= 0.6) + recently violated rules, summarizes them, and injects the summary as ephemeral context. Every session starts with accumulated wisdom rather than relying on agent initiative.

**Rationale:** Directly solves the "session learning probabilistic" known gap. The harness-activator hook already does prompt injection — this extends the pattern with actual data from the ECC observer's observations.jsonl. No new infrastructure required; purely an enhancement of the existing hook. The compounding effect: each session builds on all previous sessions' observations.

**Downsides:** Context window consumption increases. Summary quality depends on the Haiku model. Over-injection could overwhelm with irrelevant historical context.

**Confidence:** 90%
**Complexity:** Medium
**Status:** Explored (brainstorm: `docs/brainstorms/2026-04-04-session-start-learning-injection-requirements.md`)

### 4. Evolve-Driven Skill Crystallization Pipeline

**Description:** Schedule /evolve to run automatically (weekly via CI, or after instinct accumulation threshold: 5+ instincts in the same domain cluster). Feed clustering results (skill/command/agent candidates) into the propose->validate->apply pipeline. When 3+ related instincts all have confidence >= 0.6, auto-generate a skill definition and validate it.

**Rationale:** Instincts are atoms; skills are molecules. The jump from "I noticed X" to "here is a reusable capability for X-like situations" is where exponential returns live. /evolve already exists in ECC but is never triggered. The harness-analysis weekly scheduling mechanism can be reused.

**Downsides:** Auto-generated skill quality is hard to guarantee. Risk of skill proliferation without clear utility. Clustering algorithms may group unrelated instincts.

**Confidence:** 65%
**Complexity:** High
**Status:** Unexplored

### 5. Learning Pipeline Health Monitor

**Description:** Monitor the ECC observer pipeline end-to-end: observation capture rate, observer invocation frequency, instinct creation rate, confidence distribution, promotion rate, and decay casualties. Alert when any stage drops below expected throughput (e.g., observations accumulating with no instincts = observer stalled; all instincts dying before promotion = threshold miscalibrated or decay too aggressive). Implement as an extension of /instinct-status.

**Rationale:** The deterministic learning path is the foundation but operates as a black box. Pipeline silent failures mean the entire learning system could stop working without anyone noticing. This is low-cost to implement (JSONL statistics aggregation) and is a prerequisite for all other improvements — you cannot optimize what you cannot observe.

**Downsides:** Metric thresholds require empirical data to calibrate. Initial setup requires manual tuning.

**Confidence:** 90%
**Complexity:** Low
**Status:** Explored (brainstorm: `docs/brainstorms/2026-04-04-learning-pipeline-health-monitor-requirements.md`)

### 6. Context-Aware Graduated Rule Loading

**Description:** Replace "load all rules at session start" with a two-phase strategy. Phase 1: load only CLAUDE.md + high-effectiveness rules. Phase 2: when the agent encounters specific file types, directories, or tool patterns, dynamically load relevant rule subsets (e.g., shell-scripts.md when editing .sh files, renovate-external.md when touching .chezmoiexternal.toml). Track rule-to-task correlations via ECC observer to self-improve loading heuristics.

**Rationale:** Context window is the scarcest resource. Rule count will grow as the system learns more. The current directory structure (common/, web/, golang/) provides natural loading boundaries. Graduated loading keeps rules fresh in context when they matter.

**Downsides:** Depends on Claude Code's rule loading mechanism being customizable. Dynamic loading timing is tricky — load too late and the agent already made the mistake.

**Confidence:** 55%
**Complexity:** High
**Status:** Unexplored

### 7. Adversarial Rule Testing via Eval-Harness

**Description:** For each rule and high-confidence instinct, generate synthetic scenarios targeting its coverage area. Use eval-harness to compare agent behavior "with rule" vs "without rule" and verify the rule actually changes behavior. Rules that fail adversarial tests are flagged for revision.

**Rationale:** Rules are currently write-and-hope. The validate-harness-proposal skill checks structural quality but never verifies behavioral impact. The eval-harness plugin exists but is not integrated into the rule lifecycle. Connecting them creates a continuous stress-test for the knowledge base.

**Downsides:** Synthetic scenario quality determines test validity. High LLM cost (two agent runs per rule). May produce false negatives for rules that prevent rare but critical failures.

**Confidence:** 60%
**Complexity:** High
**Status:** Unexplored

## Rejection Summary

| # | Idea | Reason Rejected |
|---|------|-----------------|
| 1 | Kill the instinct layer entirely | Too extreme; throws away working infra; instincts serve as useful low-commitment buffer |
| 2 | Remove generator-evaluator for low-risk | Hard-won lesson; risk tiering already exists in apply step |
| 3 | Merge CLAUDE.md + docs/solutions/ into single KB | Different purposes (always-loaded vs. searched-on-demand); merging bloats context |
| 4 | Cookbook metaphor replacing bug-tracker | Reframing without mechanism change; current system already includes solutions |
| 5 | Counterfactual session replay | High complexity, low immediate value; forward-looking effectiveness measurement suffices |
| 6 | Cross-session diff learning | Mechanism too vague; unclear how "behavioral drift" would be detected |
| 7 | Operator friction log | Adds new workflow; capture-harness-feedback already covers this |
| 8 | Proposal dry-run / behavioral simulation | Requires running full agent sessions; prohibitive cost |
| 9 | Emergency rule kill switch | Premature optimization; file deletion sufficient at current scale |
| 10 | Abolish 5-tier hierarchy for knowledge graph | Radical rewrite; problem is bridge automation, not the hierarchy itself |
| 11 | Tool-call pair level learning | Requires new ML infrastructure beyond plugin capabilities |
| 12 | Context-conditional confidence vectors | Significant complexity added to instinct system; premature |
| 13 | Rule conflict detection engine | Premature optimization at current scale (~20 rules) |
| 14 | Event-driven harness reactions (replace batch) | Incremental improvement; weekly batch serves as safety net |
| 15 | Failure fingerprinting / pattern matching | High complexity; instincts + docs/solutions/ already cover this |
| 16 | Usage-based reinforcement (replace time decay) | Interesting but requires deep changes to ECC observer internals |
| 17 | Session-scoped ephemeral rules | Overlaps with context-aware loading; additional complexity |
| 18 | Bidirectional rule<->instinct flow (standalone) | Merged into Closed-Loop Rule Lifecycle (idea #1) |

## Session Log

- 2026-04-04: Initial ideation — 48 raw ideas generated (6 agents x 8), ~25 unique after dedupe, 7 survivors. User interest in #1 (Closed-Loop Rule Lifecycle), #3 (Session-Start Deterministic Learning Injection), #5 (Learning Pipeline Health Monitor).
- 2026-04-04: Brainstormed #1 (Closed-Loop Rule Lifecycle). Key decisions: snapshot commit for CI data access, auto-promoted rules only for demotion, instinct re-creation rate as effectiveness metric, 30-day rolling window, 90-day demotion threshold. Hard prerequisite on #5 (Health Monitor). Requirements doc: `docs/brainstorms/2026-04-04-closed-loop-rule-lifecycle-requirements.md`.
- 2026-04-04: Brainstormed #5 (Learning Pipeline Health Monitor). Key finding: ECC observer is broken (prompt file deleted before use). Key decisions: shell script (not command), binary ok/broken for v1 (graduated thresholds deferred), CI gate data produced here but gate logic lives in #1. Requirements doc: `docs/brainstorms/2026-04-04-learning-pipeline-health-monitor-requirements.md`.
- 2026-04-04: Implemented #5 (Learning Pipeline Health Monitor). PR #125 merged. Script at `scripts/pipeline-health.sh` with human + JSON output modes, CI smoke tests in Makefile.
- 2026-04-04: Brainstormed #3 (Session-Start Deterministic Learning Injection). Key decisions: full replacement of harness-activator.sh with learning-briefing.sh, tail-N raw observations (no LLM summary), ~500 token budget, pipeline-health.sh --json integration, instinct threshold lowered to 0.6. Requirements doc: `docs/brainstorms/2026-04-04-session-start-learning-injection-requirements.md`.
