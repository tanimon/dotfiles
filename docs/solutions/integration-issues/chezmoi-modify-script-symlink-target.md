---
title: "chezmoi modify_ scripts silently replace a symlinked target with a regular file"
date: 2026-08-01
category: integration-issues
module: chezmoi-dotfiles-management
problem_type: integration_issue
component: tooling
symptoms:
  - "`chezmoi status` reported drift on `~/.claude.json` after a Claude Code native-install update"
  - "`~/.claude.json` had become a symlink (mode 120755) pointing to `~/.claude/claude.json` instead of a regular file"
  - "an isolated `chezmoi apply -S <tmp-source> -D <tmp-home>` test showed the modify_ script's write replaced the symlink with a plain regular file (mode 120755 -> 100644), destroying it"
  - "the modify_ script read through the symlink via stdin but would write back a stale, diverging duplicate at the symlink's path, leaving the real `~/.claude/claude.json` untouched and out of sync"
root_cause: config_error
resolution_type: config_change
severity: medium
related_components:
  - development_workflow
tags:
  - chezmoi
  - modify-script
  - symlink
  - claude-code
  - dotfiles
  - partial-json-ownership
---

# chezmoi modify_ scripts silently replace a symlinked target with a regular file

## Problem

Claude Code's native install migrated `~/.claude.json` from a regular file to a symlink pointing at `~/.claude/claude.json` (since 2026-07-26), but this repo's `modify_` script (`modify_dot_claude.json`, mapping via chezmoi's naming convention to target `~/.claude.json`) still targeted the old path. Running `chezmoi apply` against that path would have silently deleted the symlink and replaced it with a stale, diverging regular file.

## Symptoms

- Running `/chezmoi-adopt-drift`, `chezmoi status` reported drift on `~/.claude.json` among other files.
- Direct inspection showed the target was no longer a plain file:

  ```
  $ ls -la ~/.claude.json
  lrwxr-xr-x@ - <user> 26 7月 16:29 ~/.claude.json -> .claude/claude.json
  $ file ~/.claude.json
  ~/.claude.json: JSON data   (file(1) follows the symlink)
  ```

  `ls -la` confirmed mode `120755` (symlink), while `file` — which follows symlinks — reported ordinary JSON data, masking the fact that the target itself was no longer a regular file.
- The existing `modify_dot_claude.json` (top-level source file, mapping to `~/.claude.json` under chezmoi's `modify_` + no-prefix convention) still assumed a plain, directly-writable target:

  ```bash
  #!/bin/bash
  set -euo pipefail
  MCP_SOURCE="${CHEZMOI_SOURCE_DIR}/dot_claude/mcp-servers.json"
  CURRENT="$(cat)"
  ...
  printf '%s' "${CURRENT:-"{}"}" | jq --slurpfile servers "${MCP_SOURCE}" '.mcpServers = $servers[0]'
  ```

## What Didn't Work

- **Treating this as ordinary drift adoption.** The default `/chezmoi-adopt-drift` flow assumes a `modify_` script's only failure mode is "reflect changes within keys the script owns." That guardrail doesn't cover the target's file *type* changing from regular file to symlink; a naive hunk-by-hunk adoption would have missed the structural risk entirely and just re-added the (already-corrupted) content.
- **Running `chezmoi apply` on the real `~/.claude.json` to observe behavior.** Ruled out as unacceptably destructive and hard to reverse against the user's real Claude Code state file. Confirming the failure mode against production data was not an option.
- **Adding `~/.claude.json` to `.chezmoiignore` alone, without retargeting the script.** This would have stopped the symlink-deletion problem but silently regressed the `.mcpServers` merge entirely, since nothing would then target `~/.claude/claude.json` either. Both changes were required together.

## Solution

1. **Isolated reproduction first.** Before touching anything real, built a throwaway source + home directory mimicking the symlink layout, and drove chezmoi at it via its `-S`/`-D` flags (source/destination overrides) instead of the real `~`:

   ```bash
   BASE="<scratch dir>"
   mkdir -p "$BASE/source" "$BASE/home" "$BASE/home/.claude"
   cat > "$BASE/source/modify_dot_claude.json" <<'EOF'
   #!/bin/bash
   set -euo pipefail
   CURRENT="$(cat)"
   printf '%s' "${CURRENT}" | sed 's/bar/MODIFIED/'
   EOF
   chmod +x "$BASE/source/modify_dot_claude.json"
   echo '{"foo": "bar"}' > "$BASE/home/.claude/claude.json"
   ln -s .claude/claude.json "$BASE/home/.claude.json"
   ```

   `chezmoi apply -S "$BASE/source" -D "$BASE/home" -v` confirmed the failure mode safely: the `120755` symlink was replaced by a `100644` regular file containing the *transformed* content (proving the read had followed the symlink), while the real linked-to file (`~/.claude/claude.json`) was left untouched and now stale/diverging. `chezmoi diff` on the same scratch setup showed it explicitly:

   ```
   diff --git a/.claude.json b/.claude.json
   deleted file mode 120755
   ...
   diff --git a/.claude.json b/.claude.json
   old mode 120755
   new mode 100644
   ```

2. **Retargeted the script.** Moved (`git mv`, no logic changes) `modify_dot_claude.json` → `dot_claude/modify_claude.json`. Via chezmoi's `dot_` directory-prefix + `modify_` filename convention, this retargets the script from `~/.claude.json` to `~/.claude/claude.json` directly — the real data file. The `${CHEZMOI_SOURCE_DIR}/dot_claude/mcp-servers.json` reference inside the script is already absolute-from-source-root, so no internal edits were needed.

3. **Excluded the symlink from chezmoi entirely.** Added to `.chezmoiignore`:

   ```
   # ~/.claude.json is a symlink to ~/.claude/claude.json managed by Claude Code
   # itself (since 2026-07-26); dot_claude/modify_claude.json targets the real
   # file directly, so chezmoi must never touch this symlink.
   .claude.json
   ```

4. **Updated all active references** to the old filename/path: `CLAUDE.md` (the `dot_claude/modify_claude.json` architecture note plus a new Known Pitfalls entry), `.claude/rules/chezmoi-patterns.md` (the file-type-selection table entry plus a new bullet under "modify_ Script Safety" warning never to target an app-managed symlink), and `test/modify-dot-claude.bats` (`SCRIPT=` path). Historical docs (`docs/plans/`, `docs/solutions/`) mentioning the old filename were deliberately left as-is — they are historical records, not living references (except the two cross-references noted under Related Issues below, which get a small pointer added).

5. **Verified against the real machine using read-only `chezmoi diff`** (never `apply`):
   - `chezmoi source-path "$HOME/.claude/claude.json"` → resolved correctly to `dot_claude/modify_claude.json`
   - `chezmoi source-path "$HOME/.claude.json"` → `chezmoi: ~/.claude.json: not managed` (confirms the ignore entry took effect)
   - `chezmoi diff --no-pager "$HOME/.claude/claude.json"` → only remaining diff was a missing trailing newline, confirming the `.mcpServers` merge now operates correctly on the real data file with no destructive symlink interaction.

6. **Full local verification suite green:** `make test-modify` (10 bats tests across `modify_claude.json` and `modify_karabiner.json`), `make check-templates`, `make shellcheck`, `make shfmt`, `pnpm exec secretlint` on changed files.

7. Committed on branch `fix/claude-json-symlink-modify-target` and opened **PR #258** ("fix: .claude.json のシンボリックリンク化に対応しmodify_スクリプトの対象を修正").

## Why This Works

The root cause is a read/write asymmetry in how `chezmoi apply` handles `modify_`-managed targets: it **reads** the current file content for stdin by following symlinks (transparently picking up the linked-to file's bytes), but it **writes** the script's transformed output back as a plain regular file at the symlink's own path — replacing, not updating through, the symlink. This was proven directly in the isolated test: the `sed` transform correctly turned `"bar"` (read through the symlink from the real backing file) into `"MODIFIED"`, yet the write landed as a new `100644` file at the symlink's path, deleting the `120755` symlink and leaving the original backing file (`.claude/claude.json`) unchanged and now diverged from what `.claude.json` showed.

Retargeting `dot_claude/modify_claude.json` to operate on `~/.claude/claude.json` directly removes the symlink from the write path entirely — chezmoi now reads and writes the same real file, no indirection involved. Adding `~/.claude.json` to `.chezmoiignore` closes the loophole from the other side: even if chezmoi were ever pointed at that path again, it would refuse to manage it, since Claude Code's own migration logic expects that path to remain an untouched symlink for backward compatibility.

## Prevention

- Treat any `modify_`-managed path as suspect the moment the owning external application could restructure its own storage layout (moves, symlinks, renames) — this is exactly what Claude Code did on 2026-07-26.
- When in doubt about how a `modify_` script behaves against a symlinked target, verify with an **isolated** `chezmoi apply -S <tmp-source> -D <tmp-home>` test (mimicking the real symlink layout) before ever running `chezmoi apply` against the real machine. `chezmoi diff` (read-only) is the safe verification tool once the real fix is in place — never `chezmoi apply` for a first check.
- This pattern generalizes to any other `modify_`-managed file in this repo, notably `dot_config/karabiner/modify_karabiner.json` — if Karabiner Elements or any similar app ever migrates its config to a symlinked-indirection layout, apply the same fix shape: retarget the `modify_` script to the real backing file, and `.chezmoiignore` the app-managed symlink.
- `.claude/rules/chezmoi-patterns.md` now documents this explicitly under "modify_ Script Safety": never target a path that may be a symlink managed by the app itself; target the real file directly and ignore the symlink.

## Related Issues

- [`chezmoi-apply-overwrites-runtime-plugin-changes.md`](chezmoi-apply-overwrites-runtime-plugin-changes.md) — the canonical Gotchas-table doc for `modify_` script failure modes against this same file/script family. Its table does not yet cover this write-side symlink-loss case (only read-side stdin corruption/races); a future refresh should add a row for it. That doc's own "Related" section links to `/modify_dot_claude.json`, which is now a stale path — the script lives at `dot_claude/modify_claude.json` as of this fix.
- [`chezmoi-apply-non-interactive-sandbox-claude-json-data-loss.md`](chezmoi-apply-non-interactive-sandbox-claude-json-data-loss.md) — a distinct prior incident against the same file, caused by a different mechanism: an external-process/TTY race feeding the `modify_` script empty stdin during a non-interactive `chezmoi apply --dry-run`, versus this fix's mechanism (the write-back silently converting a symlink into a regular file regardless of stdin correctness). *(session history)* That incident's own session explicitly distinguished the two failure classes as separate root causes on the same file, which lines up with this doc treating them as related-but-distinct rather than merging them.
- [`claude-code-mcp-server-config-location.md`](claude-code-mcp-server-config-location.md) — the origin doc that introduced `modify_dot_claude.json` for the unrelated original problem (MCP servers not loading from `settings.json`). Its file-structure section and code samples still name the script `modify_dot_claude.json` at the repo root; that path is now stale and should be updated with a pointer to this doc in a future refresh pass.
- [`chezmoi-private-modify-prefix-incompatibility-2026-05-09.md`](chezmoi-private-modify-prefix-incompatibility-2026-05-09.md) — documents `modify_karabiner.json`, the sibling `modify_` script named above as a similar-risk analog. Not currently affected (Karabiner has not split its config behind a symlink), but worth a watch-item cross-reference.
- [PR #258](https://github.com/tanimon/dotfiles/pull/258) — implementation PR.
- [CLAUDE.md Known Pitfalls](/CLAUDE.md) — project-level documentation of this pitfall.
