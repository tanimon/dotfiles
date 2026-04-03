---
title: "refactor: Deduplicate custom commands, skills, and subagents against plugins"
type: refactor
status: completed
date: 2026-04-02
---

# refactor: Deduplicate custom commands, skills, and subagents against plugins

## Overview

自作のスラッシュコマンド（8件）・サブエージェント（10件）・スキル（3件）を棚卸しし、インストール済みプラグイン（compound-engineering, superpowers, pr-review-toolkit, claude-md-management 等）と目的が重複するものを削除する。

## Problem Frame

プラグインエコシステムの成熟により、自作した汎用的なサブエージェントやコマンドの多くがプラグイン提供のスキル・エージェントと機能的に重複している。重複があると：
- どちらを使うべきか判断に迷う
- メンテナンスコストが二重にかかる
- コンテキストウィンドウに不要な定義が積まれる

## Requirements Trace

- R1. プラグインと目的が重複する自作コマンド・エージェント・スキルを特定し削除する
- R2. プラグインに相当物がない自作アイテムは保持する
- R3. 削除後に `chezmoi apply --dry-run` と `make lint` が通ること

## Scope Boundaries

- プラグイン自体の追加・削除・設定変更は対象外
- ルールファイル（`dot_claude/rules/`）は対象外
- MCP サーバー設定は対象外
- スクリプト（`dot_claude/scripts/`）は対象外

## Context & Research

### Overlap Analysis

#### Custom Commands (8 items in `dot_claude/commands/`)

| Custom Command | Plugin Equivalent | Verdict |
|---|---|---|
| `simplify` | `compound-engineering:simplify` (identical purpose) | **DELETE** |
| `scaffold-claude-md` | `claude-md-management:claude-md-improver` (audit/improve) + `compound-engineering:onboarding` | **KEEP** — scaffold generates from scratch; plugins improve existing |
| `scaffold-project-rules` | No equivalent | **KEEP** |
| `apply-harness-proposal` | No equivalent (harness-specific) | **KEEP** |
| `capture-harness-feedback` | No equivalent (harness-specific) | **KEEP** |
| `harness-health` | No equivalent (harness-specific) | **KEEP** |
| `harness-rule-lifecycle` | No equivalent (harness-specific) | **KEEP** |
| `resolve-harness-issues` | No equivalent (harness-specific) | **KEEP** |

**Commands to delete: 1** (`simplify`)

#### Custom Subagents (10 items in `dot_claude/agents/`)

| Custom Agent | Plugin Equivalent(s) | Verdict |
|---|---|---|
| `backend-architect` | `compound-engineering:review:architecture-strategist`, `compound-engineering:review:performance-oracle` | **DELETE** |
| `devops-architect` | `compound-engineering:review:deployment-verification-agent` | **DELETE** |
| `performance-engineer` | `compound-engineering:review:performance-oracle`, `compound-engineering:review:performance-reviewer` | **DELETE** |
| `quality-engineer` | `compound-engineering:review:testing-reviewer`, `pr-review-toolkit:pr-test-analyzer` | **DELETE** |
| `refactoring-expert` | `compound-engineering:review:code-simplicity-reviewer`, `pr-review-toolkit:code-simplifier` | **DELETE** |
| `requirements-analyst` | `compound-engineering:ce-brainstorm`, `compound-engineering:workflow:spec-flow-analyzer` | **DELETE** |
| `root-cause-analyst` | `superpowers:systematic-debugging` | **DELETE** |
| `security-engineer` | `compound-engineering:review:security-sentinel`, `compound-engineering:review:security-reviewer` | **DELETE** |
| `system-architect` | `compound-engineering:review:architecture-strategist`, `compound-engineering:ce-plan` | **DELETE** |
| `technical-writer` | `compound-engineering:onboarding`, `compound-engineering:ce-compound` | **DELETE** |

**Agents to delete: 10** (all)

#### Custom Skills (3 items in `dot_claude/skills/`)

| Custom Skill | Plugin Equivalent | Verdict |
|---|---|---|
| `compound-harness-knowledge` | No equivalent (harness-specific wrapper) | **KEEP** |
| `propose-harness-improvement` | No equivalent (harness-specific) | **KEEP** |
| `validate-harness-proposal` | No equivalent (harness-specific) | **KEEP** |

**Skills to delete: 0**

### Summary

| Category | Total | Delete | Keep |
|---|---|---|---|
| Commands | 8 | 1 | 7 |
| Subagents | 10 | 10 | 0 |
| Skills | 3 | 0 | 3 |
| **Total** | **21** | **11** | **10** |

## Key Technical Decisions

- **All 10 subagents are deletable**: Each has one or more plugin-provided agents with overlapping scope. Plugin versions are actively maintained and offer richer functionality (confidence scoring, structured review output, etc.)
- **Harness-specific items are kept**: The 5 harness commands and 3 harness skills are unique to this project's harness engineering pipeline and have no plugin equivalent
- **`scaffold-claude-md` is kept**: It generates CLAUDE.md from scratch for new projects, which is distinct from `claude-md-improver` (audits existing) and `revise-claude-md` (session learnings)
- **`scaffold-project-rules` is kept**: No plugin provides `.claude/rules/` scaffolding

## Open Questions

### Resolved During Planning

- **Should `scaffold-claude-md` be removed in favor of `claude-md-management`?** No — they serve different purposes (create vs improve)

### Deferred to Implementation

- None

## Implementation Units

- [ ] **Unit 1: Delete duplicate command**

  **Goal:** Remove `simplify` command that duplicates `compound-engineering:simplify`

  **Requirements:** R1

  **Dependencies:** None

  **Files:**
  - Delete: `dot_claude/commands/simplify.md`

  **Approach:**
  - Delete the file directly

  **Test expectation:** none — pure file deletion

  **Verification:**
  - `chezmoi managed | grep simplify` returns no results for the command path
  - `make lint` passes

- [ ] **Unit 2: Delete all duplicate subagents**

  **Goal:** Remove all 10 custom subagent definitions that overlap with plugin-provided agents

  **Requirements:** R1

  **Dependencies:** None

  **Files:**
  - Delete: `dot_claude/agents/backend-architect.md`
  - Delete: `dot_claude/agents/devops-architect.md`
  - Delete: `dot_claude/agents/performance-engineer.md`
  - Delete: `dot_claude/agents/quality-engineer.md`
  - Delete: `dot_claude/agents/refactoring-expert.md`
  - Delete: `dot_claude/agents/requirements-analyst.md`
  - Delete: `dot_claude/agents/root-cause-analyst.md`
  - Delete: `dot_claude/agents/security-engineer.md`
  - Delete: `dot_claude/agents/system-architect.md`
  - Delete: `dot_claude/agents/technical-writer.md`

  **Approach:**
  - Delete all 10 files. If the `dot_claude/agents/` directory becomes empty, remove it as well to avoid deploying an empty directory

  **Test expectation:** none — pure file deletion

  **Verification:**
  - `dot_claude/agents/` directory is empty or removed
  - `chezmoi apply --dry-run` shows no errors
  - `make lint` passes

- [ ] **Unit 3: Verify and clean up**

  **Goal:** Ensure no references to deleted items remain, and chezmoi state is clean

  **Requirements:** R3

  **Dependencies:** Unit 1, Unit 2

  **Files:**
  - Check: `.chezmoiignore` (may reference agents directory)
  - Check: `CLAUDE.md` (may reference custom agents)
  - Check: `dot_claude/settings.json.tmpl` (may reference agent names)

  **Approach:**
  - Grep for references to deleted agent/command names across the repo
  - Update or remove any stale references
  - Run `chezmoi apply --dry-run` and `make lint` as final validation

  **Test scenarios:**
  - Happy path: `grep -r 'backend-architect\|simplify' dot_claude/` returns no hits in config files
  - Happy path: `chezmoi apply --dry-run` exits 0
  - Happy path: `make lint` exits 0

  **Verification:**
  - No stale references to deleted items remain
  - Both validation commands pass

## System-Wide Impact

- **chezmoi targets:** Deleting source files means `chezmoi apply` will remove `~/.claude/agents/*` and `~/.claude/commands/simplify.md` from the target. This is the desired behavior
- **Settings/hooks:** `dot_claude/settings.json.tmpl` may reference agent names in `additionalDirectories` or hook configuration — verify no breakage
- **CI:** No CI references to custom agents expected, but verify

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Deployed targets (`~/.claude/agents/`) not cleaned up | `chezmoi apply` handles removal of files whose source is deleted |
| References to deleted agents in settings or hooks | Unit 3 grep check catches these |
