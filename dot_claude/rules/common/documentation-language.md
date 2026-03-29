---
date: 2026-03-29
trigger: "Agent wrote agent-facing documentation or rules in non-English language"
---

# Documentation Language

## Agent-Facing Documents Must Be Written in English

All files that serve as instructions or context for coding agents must be written in English:

- `CLAUDE.md` / `AGENTS.md` — project instructions
- `.claude/rules/**/*.md` — rule files
- `docs/solutions/**/*.md` — solution documents
- Code comments, commit messages

**Why:** Agent-facing documentation is consumed by LLMs whose training data is predominantly English. English rules are parsed more reliably, reduce ambiguity in technical terms, and avoid mixed-language inconsistencies (e.g., Japanese section headers with English content).

**Exceptions:**
- **PR descriptions** — written in the user's preferred language, as they are primarily for human reviewers
- **Chat responses** — follow the user's language preference
