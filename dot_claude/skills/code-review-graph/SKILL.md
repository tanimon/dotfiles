---
name: code-review-graph
description: |
  Use when exploring an unfamiliar codebase, tracing callers/callees/imports,
  assessing the blast radius or risk of a code change, reviewing a diff or PR,
  or answering architecture-level questions ("what depends on this?", "what
  breaks if I change this function?", "give me an overview of this codebase's
  structure"). Prefer this over Grep/Glob/Read for these tasks when the
  code-review-graph MCP server is connected (registered globally via
  dot_apm/apm.yml as `uvx code-review-graph serve`) — it returns a
  structural, token-efficient answer instead of requiring broad file scans.

  Trigger on intents like: "review my changes", "what's the impact of this
  change", "who calls this function", "is this safe to refactor", "show me
  the architecture of this project", "find dead code", "what tests cover
  this". Also trigger when about to do a multi-file Grep/Glob sweep purely to
  understand structure (not to edit) — check whether a graph tool answers it
  first.

  Do NOT use for: simple single-file lookups, editing/writing code, or when
  no code-review-graph MCP tools appear in the available tool list (server
  not connected in this session — fall back to Grep/Glob/Read silently,
  don't tell the user the tool is missing).
---

# code-review-graph MCP tools

This project's Claude Code global config (`dot_apm/apm.yml`) registers
`code-review-graph` as an MCP server (`uvx code-review-graph serve`). It
parses a repository with Tree-sitter into a structural graph (functions,
classes, imports, calls, test coverage) stored under `.code-review-graph/`
in that repo's root, then answers structural questions from the graph
instead of requiring Grep/Glob/Read across the whole codebase.

Registration is global (every session, every project), but the graph itself
is per-repo and **not built automatically**. Nothing forces you to use these
tools — this skill only applies when they help and are actually connected.

## Before using graph tools

1. Confirm the `code-review-graph` MCP tools actually appear in your
   available tools for this session. If they don't (server not connected,
   or an older apm.yml deployed), skip this skill entirely and use
   Grep/Glob/Read as normal — don't block on it or mention it to the user.
2. Check whether a graph already exists for the current repo — `.code-review-graph/`
   in the repo root, or call `list_graph_stats_tool`. If absent (or clearly
   stale — e.g. it predates recent commits and no watch/hook keeps it
   updated), call `build_or_update_graph_tool` first. It's incremental: safe
   to call again on an existing graph to pick up changes since the last
   build.

## When to prefer graph tools over Grep/Glob/Read

| Task | Tool | Instead of |
|---|---|---|
| Reviewing a diff / "review my changes" | `detect_changes_tool` | Reading every changed file in full |
| Getting review-ready source context | `get_review_context_tool` | Read on each changed file |
| Blast radius / "what breaks if I change X" | `get_impact_radius_tool` | Manually tracing imports |
| Tracing callers/callees/imports/tests | `query_graph_tool` (`callers_of`/`callees_of`/`imports_of`/`tests_for`) | Grep for a symbol name |
| Finding functions/classes by name/concept | `semantic_search_nodes_tool` | Grep/Glob over source files |
| Architecture / high-level structure | `get_architecture_overview_tool`, `list_communities_tool`, `get_community_tool` | Reading many files to infer structure |
| Execution-flow impact | `get_affected_flows_tool`, `list_flows_tool`, `get_flow_tool` | Manually tracing call chains |
| Planning a rename / finding dead code | `refactor_tool` (apply with `apply_refactor_tool`) | Grep + manual edits across files |
| Hotspots / coupling / gaps in a codebase | `get_hub_nodes_tool`, `get_bridge_nodes_tool`, `get_knowledge_gaps_tool`, `get_surprising_connections_tool` | No direct Grep/Read equivalent |
| Cross-repository search (after `register`) | `cross_repo_search_tool`, `list_repos_tool` | N/A |
| Generating architecture docs | `generate_wiki_tool`, `get_wiki_page_tool` | Hand-written docs |

Fall back to Grep/Glob/Read whenever the graph doesn't cover what's needed
(e.g. reading the exact implementation body to edit it, or a language the
parser doesn't support yet — see upstream README for current coverage).

## Notes

- This is a global MCP registration (every session gets these tools, even
  outside a git repo) — the tools themselves detect the current repo root,
  so calling them in a directory with no graph just returns "no graph
  found"; that's expected, not an error to fix.
- Upstream's own `code-review-graph install --platform claude-code` would
  additionally inject a similar instructions block directly into a
  **project's own** `CLAUDE.md` and write `.claude/settings.json` /
  `.mcp.json` in that project. This repo deliberately does not run that
  installer (see `dot_apm/apm.yml`'s `code-review-graph` entry and
  `CLAUDE.md`'s APM section) — this skill is the equivalent guidance,
  scoped to Claude Code's skill system instead of writing into every
  project's `CLAUDE.md`.
- Building large repos takes a few seconds to ~tens of seconds; don't
  rebuild on every single call — check `list_graph_stats_tool` /
  `.code-review-graph/` freshness first.
