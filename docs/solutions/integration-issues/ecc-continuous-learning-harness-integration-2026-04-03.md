---
title: Integrating ECC Continuous Learning v2.1 with harness engineering system
date: 2026-04-03
category: integration-issues
module: harness-engineering
problem_type: developer_experience
component: tooling
severity: high
applies_when:
  - Integrating external plugin learning systems with existing harness workflows
  - Needing deterministic observation capture instead of agent-initiative-based learning
  - Bridging confidence-scored instincts to quality-gated rule pipelines
tags:
  - harness-engineering
  - continuous-learning
  - ecc-plugin
  - observer
  - instincts
  - dual-path-learning
---

# Integrating ECC Continuous Learning v2.1 with harness engineering system

## Context

The existing self-learning harness engineering system relies on non-deterministic agent initiative for learning capture. The harness-activator hook prints a reminder, but whether the agent acts on it is probabilistic. Key gaps:

1. **No deterministic observation capture** — learning depends on the agent remembering to self-evaluate
2. **No cross-session feedback mechanism** — removed during the 2026-03-28 hook simplification
3. **No confidence scoring or temporal decay** — rules are binary (exists or doesn't)
4. **Memory system disconnected from harness pipeline** — MEMORY.md accumulates passively

ECC's Continuous Learning v2.1 (from the [everything-claude-code](https://github.com/affaan-m/everything-claude-code) plugin) provides hook-based 100% observation capture, a background Haiku-model observer, confidence-scored instincts with decay, and an evolution pipeline. The challenge was bridging this with the existing propose/validate/apply rule pipeline without replacing the existing infrastructure.

## Guidance

### 1. Enable observer via CLV2_CONFIG env var, not plugin file patches

ECC's `observe.sh` (line 317) checks the `CLV2_CONFIG` environment variable to override the config.json path. This enables chezmoi-managed configuration without patching plugin files that get overwritten on marketplace updates.

```json
// dot_claude/settings.json.tmpl (env section)
"CLV2_CONFIG": "{{ .chezmoi.homeDir }}/.claude/continuous-learning-config.json"
```

```json
// dot_claude/continuous-learning-config.json
{
  "version": "2.1",
  "observer": {
    "enabled": true,
    "run_interval_minutes": 5,
    "min_observations_to_analyze": 20
  }
}
```

The observer lazy-starts from `observe.sh` when enabled — no separate startup hook needed.

### 2. Detect project ID using ECC's git remote URL hash

ECC identifies projects by hashing the git remote URL (SHA256, first 12 chars) for portable cross-machine identification. The harness-activator can reimplement this in ~7 lines of bash without Python dependency:

```bash
REMOTE_URL=$(git -C "$PROJECT_ROOT" remote get-url origin 2>/dev/null || true)
if [[ -n "$REMOTE_URL" ]]; then
    REMOTE_URL=$(printf '%s' "$REMOTE_URL" | sed -E 's|://[^@]+@|://|')
fi
HASH_INPUT="${REMOTE_URL:-$PROJECT_ROOT}"
PROJECT_ID=$(printf '%s' "$HASH_INPUT" | shasum -a 256 2>/dev/null | cut -c1-12)
```

Instincts are stored at `~/.claude/homunculus/projects/<PROJECT_ID>/instincts/personal/`.

### 3. Load instincts in harness-activator for cross-session context

Enhance the existing harness-activator.sh (UserPromptSubmit hook, one-shot per session) to read high-confidence instincts (>= 0.7) from YAML frontmatter and surface them as session context:

```bash
for f in "$INSTINCT_DIR"/*.md "$INSTINCT_DIR"/*.yaml "$INSTINCT_DIR"/*.yml; do
    [[ -f "$f" ]] || continue
    CONFIDENCE=$(grep -m1 '^confidence:' "$f" 2>/dev/null | awk '{print $2}' || true)
    [[ "$CONFIDENCE" =~ ^[0-9]*\.?[0-9]+$ ]] || continue
    IS_HIGH=$(awk -v c="$CONFIDENCE" 'BEGIN {print (c+0 >= 0.7) ? 1 : 0}' 2>/dev/null || echo "0")
    [[ "$IS_HIGH" != "1" ]] && continue
    # Extract trigger, domain and display
done
```

### 4. Bridge instincts to rules via /promote-instincts command

Create a command that bridges the two systems: scans instincts, filters by confidence, generates structured proposals compatible with `propose-harness-improvement`, and delegates to `validate-harness-proposal` for quality gating. This preserves generator-evaluator separation.

### 5. Manage ~/.claude/homunculus/ as runtime state

Add to `.chezmoiignore` — this is runtime state like `projects/`, `sessions/`, `cache/`. chezmoi manages only the observer configuration, not the learned instincts.

### 6. No sandbox changes needed

`~/.claude/homunculus/` falls under `~/.claude/` which is already allowed rw in both safehouse (built-in `claude-code.sb`) and cco (`allow-paths.tmpl` line 28). No additional sandbox allowlist entries required.

## Why This Matters

The dual-path architecture addresses a fundamental reliability gap: the initiative path (harness-activator reminder) is effective when agents act on it, but non-deterministic. The deterministic path (ECC hooks → observations → observer → instincts) captures every tool call automatically. Together:

- **Instincts** capture patterns through repeated observation with confidence scoring (0.3-0.9)
- **Rules** are validated, permanent, high-quality guidelines created through the propose/validate/apply pipeline
- **/promote-instincts** bridges the two: high-confidence instincts can be promoted to rules with quality gating

The 5-tier feedback loop hierarchy becomes:
1. **Hooks** (automatic, immediate): Format, lint, secret detection
2. **Instincts** (automatic, confidence-scored): ECC observer detects patterns from observations
3. **Rules** (contextual, session-scoped): Validated and permanent guidelines
4. **CLAUDE.md** (project-scoped): Architecture, commands, pitfalls
5. **docs/solutions/** (historical): Past problem resolutions

## When to Apply

- Integrating an external learning plugin that generates observations and stores them under `~/.claude/`
- Needing chezmoi-managed configuration for a marketplace plugin (use env var overrides, not file patches)
- Building a bridge between automatic pattern detection and quality-gated rule creation
- Adding cross-session learning context to existing hook-based systems

Do NOT use this if:
- The plugin doesn't support configuration externalization via env vars
- Observations should remain completely private (never promoted to shared rules)

## Examples

### Dual-path learning flow

```
Session Activity
    │
    ├──→ ECC Plugin Hooks (pre/post:observe)
    │       │
    │       ▼
    │    observations.jsonl (deterministic)
    │       │
    │       ▼
    │    Observer (Haiku bg) → Instincts (confidence-scored)
    │                              │
    │                              ▼
    │                     /promote-instincts (bridge)
    │                              │
    ├──→ harness-activator ────────┤
    │    (agent self-evaluation)   │
    │                              ▼
    └──────────────────→ propose → validate → apply (rules)
```

### CLV2_CONFIG override pattern

The key insight: instead of patching `~/.claude/plugins/marketplaces/everything-claude-code/skills/continuous-learning-v2/config.json` (overwritten on marketplace update), set `CLV2_CONFIG` env var to point to a chezmoi-managed file. ECC's `observe.sh` checks this var before reading the default config path. (auto memory [claude]: Plugin Lifecycle — marketplace → install → enabledPlugins; chezmoi manages only the toggle and marketplace list, not plugin internals.)

## Related

- `docs/solutions/developer-experience/self-learning-harness-engineering-system-2026-03-29.md` — Original 3-layer harness system architecture (detection → proposal → application)
- `docs/solutions/developer-experience/autonomous-harness-engineering-hooks-2026-03-28.md` — Hook architecture evolution; LLM self-evaluation > bash grep
- `docs/solutions/integration-issues/ecc-plugin-enablement-and-selective-rules-install-2026-04-03.md` — ECC plugin enablement and declarative rules installation
- `docs/solutions/integration-issues/claude-code-hook-exit-code-and-stderr-semantics.md` — Hook exit code contract
- PR #124 — Implementation PR
