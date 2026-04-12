---
title: Adding external Claude Code skill collections to chezmoi dotfiles
date: 2026-04-13
category: integration-issues
module: chezmoi
problem_type: integration_issue
component: tooling
symptoms:
  - "Code review falsely flags shebang inside OS guard as P1 for run_onchange_ templates"
  - "External tool auto-update mechanism conflicts with chezmoi + Renovate declarative management"
  - "No established pattern for external skill repos that require a build step after archive extraction"
root_cause: incomplete_setup
resolution_type: config_change
severity: medium
tags:
  - chezmoi
  - chezmoiexternal
  - run-onchange
  - claude-code-skills
  - gstack
  - renovate
  - harness-engineering
---

# Adding external Claude Code skill collections to chezmoi dotfiles

## Problem

Adding a Claude Code skill collection (gstack) to chezmoi-managed dotfiles required understanding three non-obvious patterns that are not documented together elsewhere. A code review incorrectly flagged the established shebang placement as a P1 critical issue, and the interaction between the tool's own auto-update mechanism and chezmoi's declarative model needed explicit resolution.

## Symptoms

- Code review (ce:review) correctness reviewer flagged shebang inside `{{ if eq .chezmoi.os "darwin" }}` guard as P1 ("script is unexecutable on non-Darwin") for a `run_onchange_after_` template
- gstack's `--team` mode would run `git pull` on SessionStart, potentially diverging from the SHA pinned in `.chezmoiexternal.toml`
- No single reference pattern existed for external skill repos that need a build step (bun compile) after chezmoi archive extraction

## What Didn't Work

- The correctness reviewer's suggested fix (moving the shebang before the OS guard) was unnecessary. The reviewer applied `modify_` script reasoning to a `run_onchange_` script, which has fundamentally different empty-output behavior.

## Solution

### Pattern 1: Shebang inside OS guard is correct for `run_onchange_` templates

When `{{ if eq .chezmoi.os "darwin" }}` wraps the entire script including the shebang, chezmoi renders an empty string on non-matching OS. For `run_onchange_` scripts, chezmoi treats empty output as a no-op and skips execution entirely. This is safe and correct.

**This is NOT the same as `modify_` scripts**, where empty stdout deletes the target file. The CLAUDE.md pitfall "modify_ scripts: empty stdout = target deletion" applies exclusively to `modify_` scripts.

Reference pattern: `.chezmoiscripts/run_onchange_darwin-install-packages.sh.tmpl` uses this exact structure.

```bash
{{ if eq .chezmoi.os "darwin" -}}
#!/usr/bin/env bash
set -euo pipefail

# hash: {{ include "some-file" | sha256sum }}
# ... script body ...
{{ end -}}
```

### Pattern 2: Disable tool auto-update when chezmoi + Renovate manages versions

When an external tool has its own update mechanism (git pull, auto-upgrade hooks), it must be disabled to prevent conflicts with chezmoi's declarative model:

- **chezmoi + Renovate** manages the SHA pin declaratively via `.chezmoiexternal.toml`
- **The tool's auto-update** would bypass chezmoi and modify files chezmoi owns

For gstack specifically, use `./setup --no-team` to suppress the SessionStart auto-upgrade hook. Without this flag, gstack registers a hook that runs `git pull` on every Claude Code session start, potentially diverging from the pinned SHA and causing chezmoi to overwrite the changes on next apply.

### Pattern 3: External skill collection with build step

Complete pattern for adding a Claude Code skill repo that requires compilation:

1. **Brewfile**: Add build dependency (e.g., `brew "bun"`)
2. **`.chezmoiexternal.toml`**: Archive entry with SHA pin and Renovate comment

   ```toml
   [".claude/skills/<tool>"]
     type = "archive"
     url = "https://github.com/owner/repo/archive/<sha>.tar.gz"
     # renovate: branch=main
     stripComponents = 1
     refreshPeriod = "168h"
   ```

3. **`.chezmoiscripts/run_onchange_after_setup-<tool>.sh.tmpl`**: Setup script with guards

   ```bash
   {{ if eq .chezmoi.os "darwin" -}}
   #!/usr/bin/env bash
   set -euo pipefail

   # chezmoiexternal hash: {{ include ".chezmoiexternal.toml" | sha256sum }}

   TOOL_DIR="{{ .chezmoi.homeDir }}/.claude/skills/<tool>"

   if [ ! -d "$TOOL_DIR" ]; then
       echo "WARNING: <tool> not found at $TOOL_DIR, skipping"
       exit 0
   fi

   command -v <build-dep> >/dev/null 2>&1 || { echo "WARNING: <build-dep> not found, skipping"; exit 0; }

   echo "Running <tool> setup..."
   cd "$TOOL_DIR"
   ./setup --flags-to-disable-auto-update
   {{ end -}}
   ```

4. **`.chezmoiignore`**: Exclude runtime state directory (e.g., `.gstack`)

## Why This Works

- `run_onchange_` templates with empty output are no-ops in chezmoi (unlike `modify_` scripts where empty output deletes the target)
- Disabling the tool's auto-update prevents a race between two version management systems
- The hash comment on `.chezmoiexternal.toml` ensures the setup re-runs when Renovate bumps the SHA
- Guards for missing build dependencies handle fresh-machine bootstrap ordering gracefully

## Prevention

- When reviewing `run_onchange_` templates, do not apply `modify_` script rules about empty output. These are fundamentally different chezmoi primitives
- When adding tools with auto-update features, always check for flags that disable self-updating (`--no-team`, `--no-auto-update`, etc.)
- Document the `--no-team` (or equivalent) rationale in the plan or commit message so future maintainers understand why it was chosen

## Related Issues

- PR [#162](https://github.com/tanimon/dotfiles/pull/162) — gstack introduction
- `docs/solutions/integration-issues/chezmoi-v2701-strict-mode-chezmoiexternal-migration-2026-04-12.md` — archive type requirement
- `docs/solutions/integration-issues/chezmoi-external-script-repo-with-renovate-sha-pinning.md` — Renovate adjacency contract
- `.chezmoiscripts/run_onchange_darwin-install-packages.sh.tmpl` — reference pattern for OS-guarded scripts
- `.chezmoiscripts/run_onchange_after_link-cco.sh.tmpl` — reference pattern for post-extraction scripts
