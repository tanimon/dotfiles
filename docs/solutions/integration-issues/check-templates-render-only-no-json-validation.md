---
title: "make check-templates validates render only, not JSON validity or content"
date: 2026-07-18
category: integration-issues
module: makefile
problem_type: integration_issue
component: tooling
symptoms:
  - "make check-templates prints 'PASS: all templates valid' for a settings.json.tmpl edit that renders but emits invalid JSON"
  - "a dropped or doubled comma after a JSON array renders fine and passes check-templates, shipping broken JSON green"
  - "check-templates never parses rendered output as JSON and never asserts expected content — it only checks the chezmoi execute-template exit code"
root_cause: missing_tooling
resolution_type: workflow_improvement
severity: medium
tags: [harness-engineering, chezmoi, check-templates, silent-failure, json, template, verification, makefile]
---

# make check-templates validates render only, not JSON validity or content

## Problem

`make check-templates` gives false confidence when editing JSON-shaped chezmoi templates (e.g. `dot_claude/settings.json.tmpl`). It confirms the template *renders*, not that the rendered output is valid JSON or contains what you intended — so a malformed edit that still renders can pass the only automated gate and ship green.

## Symptoms

- `make check-templates` prints `PASS: all templates valid` even when an edit to `dot_claude/settings.json.tmpl` produces invalid JSON.
- A dropped or doubled comma after an array (or a truncated string) renders without error and passes the check.
- The failure is silent: no error, no diff, just a green gate over broken output.

## What Didn't Work

- **Trusting `make check-templates` as a JSON/content gate.** Reading the target shows why it can't be one — it renders each `.tmpl` to `/dev/null` and inspects only the exit code:

  ```make
  chezmoi execute-template \
      --config "$$tmpconfig" \
      --source "$$(pwd)" \
      < "$$file" > /dev/null || { echo "FAIL: $$file"; fail=1; }; \
  ```

  `chezmoi execute-template` exits 0 whenever the Go template renders. Invalid JSON in the rendered *output* never affects that exit code, so `check-templates` cannot catch it. A plan that claimed check-templates would "assert the rendered `allowWrite` array contains `/tmp`" and "validate JSON via chezmoi" was factually wrong on both counts (caught in a ce-doc-review feasibility pass, PR #227).
- **Relying on JSON linters.** `dot_claude/settings.json.tmpl` is excluded from JSON linters because of Go template syntax, and `modify_*` JSON files are bash scripts — so no linter covers this file either. `check-templates` is the *only* automated gate on it.

## Solution

Treat `make check-templates` as **necessary but not sufficient**: it proves the template renders, nothing more. For any JSON-shaped `.tmpl` edit, add an explicit render-then-`jq` verification that both proves valid JSON and asserts the expected content:

```sh
tmpconfig=$(mktemp "${TMPDIR:-/tmp}/cc-test-XXXXXX.toml")
printf '[data]\n  profile = "personal"\n  ghOrg = "test-org"\n' > "$tmpconfig"

chezmoi execute-template --config "$tmpconfig" --source "$(pwd)" \
  < dot_claude/settings.json.tmpl \
  | jq -e '.sandbox.filesystem.allowWrite | index("/tmp")' >/dev/null \
  && echo "PASS: valid JSON + entry present"
rm -f "$tmpconfig"
```

`jq` fails (non-zero) on malformed JSON, so the pipeline catches a broken comma; `jq -e` with a content predicate additionally asserts the edit landed. Use the same `[data]` test config `check-templates` uses (`profile`, `ghOrg`) and `--source "$(pwd)"` so it renders *your* working tree, not chezmoi's default source dir.

## Why This Works

The root cause is **render-only validation**: `chezmoi execute-template` succeeds on any renderable template regardless of whether the output is well-formed for its target format. Piping the rendered output through a format-aware parser (`jq` for JSON) moves the check from "did it render" to "is the output valid and correct." This is the same "error-message-then-PASS is a silent-failure smell" family as the mktemp/TMPDIR Makefile issue, but the root cause is different — there it was an unguarded `mktemp` on a sandbox-denied path; here it is a validation that structurally cannot see output validity.

## Prevention

- **After editing any JSON-shaped `.tmpl`, run the render-then-`jq -e` check above** — do not treat a green `make check-templates` as proof the JSON is valid.
- **Always pass `--source "$(pwd)"`** when rendering for verification. Without it, `chezmoi` uses its configured source dir (`~/.local/share/chezmoi`), so edits made in a separate worktree/checkout won't appear — the render (and any `chezmoi diff`) silently reflects the wrong copy.
- **When writing a plan or test scenario, don't claim `check-templates` validates JSON or content.** State it verifies render-without-error only, and specify the `jq` assertion as the real validity/content guard.
- **Consider hardening `check-templates` itself** (out of scope for this session): pipe known JSON-shaped templates through `jq empty` after rendering so the CI gate catches invalid JSON without a manual step.

## Related Issues

- `docs/solutions/integration-issues/makefile-mktemp-silent-pass-and-macos-tmpdir-sandbox.md` — the sibling silent-failure in the same Makefile test targets (mktemp on sandbox-denied `/tmp`/`/var/folders`), and the "error-then-PASS is a silent-failure smell" heuristic.
- `docs/solutions/integration-issues/chezmoi-tmpl-shellcheck-shfmt-incompatibility.md` — why `.tmpl` files are excluded from other linters, leaving `check-templates` as the only automated gate.
- PR #227 (`feat(claude): sandbox allowWrite に低リスク temp ディレクトリを追加`) — where the false-confidence claim was caught and corrected.
