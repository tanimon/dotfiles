---
name: ecc-observer-diagnosis
description: |
  Diagnose and fix ECC continuous learning observer failures preventing instinct 
  creation. Use when: (1) pipeline-health.sh reports "Observer Analysis: BROKEN",
  (2) observations.jsonl grows but instinct count remains 0, (3) observer.log shows
  "cat: .observer-tmp/ecc-observer-prompt.XXX: No such file or directory" or
  "Error: Input must be provided either through stdin or as a prompt argument when
  using --print". Covers temp file race condition fix, --dangerously-skip-permissions
  fix, manual instinct generation, and session-guardian active hours constraint.
author: Claude Code
version: 1.0.0
date: 2026-04-05
---

# ECC Observer Diagnosis and Repair

## Problem

The ECC continuous learning observer (`observer-loop.sh`) fails to create instincts from
observations. The pipeline silently degrades: observations accumulate but the Haiku
analysis step fails, producing zero instincts indefinitely.

## Context / Trigger Conditions

- `pipeline-health.sh` reports `Observer Analysis: BROKEN` and `Instinct Creation: BROKEN (0 instincts)`
- `observer.log` shows repeated errors:
  ```
  cat: .observer-tmp/ecc-observer-prompt.XXXXXX: No such file or directory
  Error: Input must be provided either through stdin or as a prompt argument when using --print
  Claude analysis failed (exit 1)
  ```
- Observations count keeps growing (observations.jsonl) but no instinct files appear
- OR: Haiku analysis runs but never creates instinct files (reaches max turns without writing)

## Solution

### Bug 1: Temp File Race Condition

**File:** `~/.claude/plugins/marketplaces/everything-claude-code/skills/continuous-learning-v2/agents/observer-loop.sh`

The script creates a temp file with `mktemp`, writes the prompt via heredoc, then reads it
back with `$(cat "$prompt_file")`. This intermittently fails (file not found despite mktemp
succeeding). Root cause is unclear but reproducible.

**Fix:** Replace temp file with shell variable assignment.

```bash
# BEFORE (broken):
prompt_file="$(mktemp "${observer_tmp_dir}/ecc-observer-prompt.XXXXXX")"
cat > "$prompt_file" <<PROMPT
...prompt content...
PROMPT
claude ... -p "$(cat "$prompt_file")" >> "$LOG_FILE" 2>&1 &
rm -f "$prompt_file"

# AFTER (fixed):
prompt_content="...prompt content..."
claude ... -p "$prompt_content" < /dev/null >> "$LOG_FILE" 2>&1 &
```

### Bug 2: Missing --dangerously-skip-permissions

The `claude --model haiku --print` invocation lacks `--dangerously-skip-permissions`. 
Without it, the Write tool is blocked by Claude Code's internal permission system even
in `--print` mode. Haiku detects patterns but cannot create instinct files.

**Fix:** Add `--dangerously-skip-permissions` and `< /dev/null` to the claude command.

```bash
ECC_SKIP_OBSERVE=1 ECC_HOOK_PROFILE=minimal claude --model haiku --max-turns "$max_turns" --print \
  --dangerously-skip-permissions \
  --allowedTools "Read,Write" \
  -p "$prompt_content" < /dev/null >> "$LOG_FILE" 2>&1 &
```

### Manual Instinct Generation (for testing)

When the observer is broken, generate instincts manually:

```bash
cd ~/.claude/homunculus/projects/<hash>
mkdir -p .observer-tmp instincts/personal

analysis_file=".observer-tmp/manual-analysis.jsonl"
tail -n 30 observations.jsonl > "$analysis_file"

ECC_SKIP_OBSERVE=1 ECC_HOOK_PROFILE=minimal command claude --model haiku --max-turns 15 --print \
  --dangerously-skip-permissions \
  --allowedTools "Read,Write" \
  -p "Read .observer-tmp/manual-analysis.jsonl and identify patterns. Write instinct files to $(pwd)/instincts/personal/<id>.md." \
  < /dev/null 2>&1
```

### Session-Guardian Active Hours

The observer only analyzes during active hours (default: 8:00-23:00). Outside this window,
`observer.log` shows `session-guardian: outside active hours`. This is expected behavior,
not a bug.

## Verification

```bash
# Check pipeline health
~/.claude/scripts/pipeline-health.sh

# Check observer log for recent success
tail -20 ~/.claude/homunculus/projects/<hash>/observer.log

# Check instinct files were created
ls ~/.claude/homunculus/projects/<hash>/instincts/personal/
```

## Notes

- **Plugin updates overwrite patches.** The observer-loop.sh is part of the 
  `everything-claude-code` plugin. Updates via `claude plugin marketplace` will 
  restore the original broken code. Re-apply patches after updates.
- **Check `pipeline-health.sh` after updates** to detect if patches were lost.
- **The `< /dev/null` prevents** a "no stdin data received" warning in --print mode.
- **Project hash discovery**: Use `git remote get-url origin | shasum -a 256 | cut -c1-12`
  to find your project's instinct directory.
- See also: `docs/solutions/integration-issues/chezmoi-scripts-deployment-gap-repo-only-vs-deployed-2026-04-04.md`
  for related deployment pattern issues.
