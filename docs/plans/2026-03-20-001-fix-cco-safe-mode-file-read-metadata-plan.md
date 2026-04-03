---
title: "fix: allow file-read-metadata in cco --safe mode on macOS"
type: fix
status: completed
date: 2026-03-20
---

# fix: allow file-read-metadata in cco --safe mode on macOS

## Overview

Submit a PR to [nikvdp/cco](https://github.com/nikvdp/cco) to fix `--safe` mode on macOS. The Seatbelt sandbox's `(deny file-read* (subpath "$HOME"))` blocks `file-read-metadata` (stat/lstat), breaking Node.js and other tools that call `realpathSync` or `lstat` on paths under `$HOME`.

The upstream already added `(allow file-read-metadata (literal "$ancestor"))` for CWD ancestor directories, but this is insufficient -- tools need to stat arbitrary paths under `$HOME`, not just CWD ancestors.

## Problem Statement

In `--safe` mode, the `sandbox` script generates:

```scheme
(deny file-read* (subpath "$HOME"))
;; ancestor allows (literal only -- too narrow)
(allow file-read-metadata (literal "$ancestor_N"))
...
(allow file-read-metadata (literal "$HOME"))
```

`file-read*` is a wildcard matching `file-read-data`, `file-read-metadata`, and `file-read-xattr`. The `literal` ancestor allows only permit stat on specific CWD ancestor paths. Any path under `$HOME` that is NOT a CWD ancestor cannot be stat-ed, causing:

- Node.js `realpathSync` EPERM on module loading
- Any tool calling `lstat()` on non-ancestor `$HOME` subpaths fails

## Proposed Solution

Replace the CWD-ancestor `literal` loop with a single `subpath` allow:

```scheme
(deny file-read* (subpath "$HOME"))
(allow file-read-metadata (subpath "$HOME"))
```

This permits stat/lstat on ALL paths under `$HOME` while still denying file content reads (`file-read-data`) and extended attribute reads (`file-read-xattr`).

### Why remove the literal ancestor loop?

The `subpath` rule is a strict superset of all `literal` ancestor rules. Keeping both would be dead code that confuses future readers. The version control history documents the change.

## Technical Considerations

### Security tradeoff

With `subpath`, a sandboxed process can stat (existence check, size, mtime, permissions) any path under `$HOME`. This is acceptable because:

- `--safe` mode already uses `(allow default)`, full network access, env var inheritance, and Mach port access -- it is not a hostile-adversary containment sandbox
- Linux `--safe` mode (tmpfs overlay) allows stat on the tmpfs mount -- macOS should be consistent
- The existing `literal` ancestor approach already leaks metadata for CWD ancestors

The PR description should explicitly acknowledge this tradeoff.

### Seatbelt last-match-wins semantics

The `(allow file-read-metadata ...)` placed after `(deny file-read* ...)` correctly overrides the deny for metadata only. If a user also uses `--deny $HOME/some/path`, that deny rule comes later and would re-block metadata for that subpath -- this is correct behavior (explicit deny should win).

### Linux parity

This change is macOS-only (Seatbelt). Linux `--safe` mode uses `--tmpfs $HOME` which is unaffected.

### readlink on symlinks

Node.js `realpathSync` calls both `lstat` and `readlink`. Empirical testing with our local chezmoi patch confirms `readlink` works under `file-read-metadata`. Tests should verify this explicitly.

## Implementation Plan

### Phase 1: Setup

1. Fork `nikvdp/cco` on GitHub via `gh repo fork`
2. Clone with `ghq get -p <fork-url>`
3. Create a feature branch

### Phase 2: Code Change

Modify `sandbox` script's `run_macos()` function, safe mode block:

- **Remove** the `while` loop generating `literal` ancestor allows and the trailing `(allow file-read-metadata (literal "$HOME"))`
- **Add** a single `printf '(allow file-read-metadata (subpath "%s"))\n' "$(policy_quote "$HOME")"` after the deny rule

This is approximately a net -10/+2 line change.

### Phase 3: Tests

Add test cases to `tests/test_sandbox.sh` in the macOS safe mode section:

1. **stat on non-CWD-ancestor path under $HOME** -- should succeed
2. **readlink on symlink under $HOME** -- should succeed
3. **directory listing ($HOME) still denied** -- regression guard
4. **file content read still denied** -- regression guard
5. **Node.js realpathSync on non-ancestor path** -- if node available

Test conventions: use the existing custom bash test harness (`pass()`/`fail()`/`skip()` helpers, counter-based summary).

### Phase 4: Submit PR

- Create issue describing the problem
- Create PR referencing the issue with `Fixes #XX`
- PR body: summarize the fix, security tradeoff acknowledgment, test plan

## Acceptance Criteria

- [ ] `sandbox` script modified: `subpath` metadata allow replaces `literal` ancestor loop
- [ ] Tests added: stat/readlink succeed, content read/dir listing still denied
- [ ] `make test` passes on macOS (existing + new tests)
- [ ] `make lint` (shellcheck) passes
- [ ] `make format` (shfmt) produces no diff
- [ ] Issue created on nikvdp/cco
- [ ] PR created referencing the issue

## Post-Merge Follow-up (local chezmoi repo)

Once upstream merges and Renovate bumps the ref in `.chezmoiexternal.toml`:

- `run_onchange_after_patch-cco-sandbox.sh.tmpl` will detect `file-read-metadata (subpath` and skip patching (idempotency check already handles this)
- Eventually remove the patch script entirely

## Sources & References

- Existing local patch: `.chezmoiscripts/run_onchange_after_patch-cco-sandbox.sh.tmpl`
- Solution doc: `docs/solutions/runtime-errors/cco-sandbox-hook-and-git-eperm.md`
- Memory: `cco_seatbelt_file_read_metadata.md`
- cco upstream: `nikvdp/cco` @ `9e514ba` (master branch)
- Seatbelt test: `tests/test_seatbelt_precedence.sh` confirms last-match-wins semantics
