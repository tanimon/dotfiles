---
title: "chezmoi private_modify_ prefix combination is silently parsed as a regular file"
date: 2026-05-09
category: integration-issues
module: chezmoi dotfiles
problem_type: integration_issue
component: tooling
severity: medium
symptoms:
  - "`private_modify_<filename>` source is deployed as a regular file at the literal target name (e.g., `~/.config/karabiner/modify_karabiner.json`) instead of running as a modify script"
  - "Intended modify-script target (e.g., `~/.config/karabiner/karabiner.json`) is unmanaged after the rename"
  - "`chezmoi managed | grep <basename>` lists the wrong target path with no warning"
root_cause: wrong_api
resolution_type: config_change
tags: [chezmoi, modify-scripts, file-permissions, prefix-system, harness-engineering]
---

# chezmoi `private_modify_` Prefix Combination Is Not a Valid Modify Script

## Problem

chezmoi v2.70.3 does not support combining the `private_` attribute prefix with the `modify_` operation prefix as `private_modify_<filename>`. When a source file is named this way, chezmoi's prefix parser consumes `private_` as the attribute, then treats the remaining `modify_<filename>` string as a literal target filename rather than recognizing it as a modify operation. The intended modify script is silently dropped and a regular file is deployed to the wrong path.

## Symptoms

- After renaming a source file to `private_modify_karabiner.json`, `chezmoi managed | grep karabiner` listed `.config/karabiner/modify_karabiner.json` (a regular file at the wrong target path) — not the intended `.config/karabiner/karabiner.json`.
- `chezmoi managed | grep karabiner` showed no entry for the intended target `.config/karabiner/karabiner.json` at all — it was unmanaged.
- `chezmoi diff ~/.config/karabiner/karabiner.json` after the rename produced no output because chezmoi no longer tracked that path.
- After reverting to `modify_karabiner.json`, `chezmoi managed | grep karabiner` correctly listed `.config/karabiner/karabiner.json` as a modify-script target and `chezmoi diff` showed the expected JSON + mode changes.

## What Didn't Work

The standard chezmoi prefix-stacking convention (attribute prefixes before operation prefixes) suggested that `private_modify_karabiner.json` should produce a modify script whose deployed target has mode `0600`. This naming was attempted:

```
# Attempted — does NOT work
dot_config/karabiner/private_modify_karabiner.json
```

After this rename, `chezmoi managed` output was:

```
.config/karabiner
.config/karabiner/modify_karabiner.json   <- wrong: regular file, wrong target name
```

The parser stripped `private_` as an attribute prefix, then stopped. It did not re-examine `modify_` as an operation prefix — it treated `modify_karabiner.json` as the literal target filename with mode `0600` applied. The intended modify operation was lost entirely.

## Solution

Use the `modify_` prefix alone, without any attribute prefix:

```
# Rejected -- not recognized as a modify script
dot_config/karabiner/private_modify_karabiner.json

# Accepted -- recognized correctly as a modify script
dot_config/karabiner/modify_karabiner.json
```

The trade-off is that the deployed file mode is `0644` (chezmoi's default for modify-script targets) rather than `0600`. For Karabiner Elements this is self-healing — Karabiner rewrites `karabiner.json` with mode `0600` on every GUI save, so the mode-only diff appears once after the first `chezmoi apply` and resolves automatically on the next Karabiner interaction.

For cases where the target mode must remain `0600` persistently and the file also requires runtime-mutable partial JSON management, a `run_onchange_after_` script can enforce the mode as a post-apply step:

```bash
#!/usr/bin/env bash
# .chezmoiscripts/run_onchange_after_fix-karabiner-mode.sh.tmpl
# karabiner hash: {{ "{{ include \"dot_config/karabiner/modify_karabiner.json\" | sha256sum }}" }}
set -euo pipefail

TARGET="${HOME}/.config/karabiner/karabiner.json"
[[ -f "$TARGET" ]] && chmod 0600 "$TARGET"
```

This workaround is not shipped in this repository (Karabiner restores `0600` on its own), but it is the correct path forward when target mode actually matters and the file is also under `modify_` management.

## Why This Works

chezmoi's source-state parser reads a filename left-to-right and stops at the first recognized prefix class. The attribute prefixes (`private_`, `readonly_`, `executable_`, `encrypted_`, `empty_`, `symlink_`) are matched first. Once `private_` is consumed, the parser emits the attribute and advances past it. The remainder of the filename — `modify_karabiner.json` — is then handed to the target-name stage. At that stage, chezmoi does not re-examine the remainder for operation prefixes (`create_`, `modify_`, `run_*`). Those operation prefixes are only recognized when they appear at the start of the un-prefixed filename, before any attribute prefix has already been consumed.

The result is that `private_modify_karabiner.json` is parsed as: attribute=`private`, target=`modify_karabiner.json` — a regular file with mode `0600` deployed to the literal name `modify_karabiner.json`. This behavior is consistent with chezmoi v2.70.1+ strict source-state parsing. The same limitation applies by the same logic to any `<attribute>_modify_`, `<attribute>_create_`, or similar combination, though only `private_modify_` was empirically tested here.

The reference script `modify_dot_claude.json` does not expose this problem because `~/.claude.json` is mode `0644` — no `private_` is needed, so the combination is never attempted.

## Prevention

- **Treat operation prefixes and attribute prefixes as mutually exclusive for the same source filename.** `modify_`, `create_`, and `run_*` are operation prefixes; `private_`, `readonly_`, `executable_`, etc. are attribute prefixes. chezmoi does not support stacking them on a single filename. If you need both a modify operation and a specific target mode, use a separate `run_onchange_after_` chmod script alongside the modify script.

- **Plan the chmod step at the same time as the modify script** for any runtime-mutable file that requires both partial JSON management and a non-default target mode (`0600`, `0700`, etc.). Do not add the modify script first and defer the mode concern — the natural instinct to reach for `private_modify_` will waste a debugging cycle.

- **Verify intent with `chezmoi managed | grep <basename>` after every source-naming change.** If the listed target path does not match your expectation, the prefix combination is being parsed differently than intended. This check takes seconds and catches the problem before `chezmoi apply` writes files to the wrong path.

- **Update `.claude/rules/chezmoi-patterns.md`** (or equivalent project rules) whenever a contributor would naturally reach for an unsupported prefix combination. The File Type Selection table in that file currently lists `modify_` as a valid pattern but does not warn that attribute prefixes cannot precede it. A one-line note in that table — *"attribute prefixes (`private_`, etc.) cannot be combined with `modify_`; use a separate `chmod` script if mode enforcement is needed"* — would prevent this mistake for future contributors.

## Related Issues

- `docs/solutions/integration-issues/chezmoi-apply-overwrites-runtime-plugin-changes.md` — established the `modify_` pattern with a worked example using the `modify_private_installed_plugins.json.tmpl` naming that this doc now corrects (moderate overlap; refresh candidate).
- `docs/solutions/integration-issues/chezmoi-full-template-drift.md` — motivates choosing `modify_` over full `.tmpl` for runtime-mutable files (no prefix discussion).
- `docs/solutions/integration-issues/chezmoi-declarative-marketplace-sync-over-bidirectional.md` — historical context on files that previously used `modify_private_*` naming before being deleted.
- `docs/solutions/developer-experience/chezmoi-oxlint-oxfmt-lint-pipeline-gotchas-2026-03-29.md` — separately documents that `modify_` scripts can have misleading file extensions; complementary to this doc.
- PR https://github.com/tanimon/dotfiles/pull/195 — the Karabiner feature where this limitation surfaced; residual-review findings doc lives at `docs/residual-review-findings/feat-chezmoi-manage-karabiner-complex-mods.md`.
