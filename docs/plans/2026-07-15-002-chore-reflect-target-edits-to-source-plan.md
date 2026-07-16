---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
title: "chore: Reflect direct target edits back into chezmoi source"
type: chore
date: 2026-07-15
---

# chore: Reflect direct target edits back into chezmoi source

## Summary

The user edited several deployed dotfiles under `~/` (chezmoi *target* state) directly
and wants those edits persisted into the chezmoi *source* tree so they survive the next
`chezmoi apply` and are version-controlled. Four source files must be updated to match
the current target content. This is the same pattern as prior commits #214
(`chore(gitignore): targetのみに存在したエントリをsourceへ反映`) and #218
(`chore(claude): settings.jsonのプラグインドリフトをsourceへ反映`).

**Product Contract preservation:** N/A — direct planning (`ce-plan-bootstrap`), no upstream requirements doc.

---

## Problem Frame

`chezmoi status` reports `MM` (modified in destination **and** apply would revert) for
four managed files, meaning the live `~/` copies were changed by hand and diverge from
source:

| Target (`~/`) | Source | Target-only content to reflect |
|---|---|---|
| `~/.zshrc` | `dot_zshrc` | `git-wt` shell init line |
| `~/.config/mise/config.toml` | `dot_config/mise/config.toml` | `herdr = "0.7.3"` tool pin |
| `~/.gitconfig` | `dot_gitconfig.tmpl` | `[wt]` (git-wt) config section |
| `~/.gitignore` | `dot_gitignore` | `.gstack/`, `docs/plans/`, `docs/superpowers/` entries |

Direction was verified by grep + `git log -S`: none of `git-wt`, `herdr`, or the `[wt]`
section has **ever** existed in the source files, confirming these are new hand-edits in
the target (not source-ahead pending-apply drift that a reflect would wrongly revert).

**Not in scope (incidental drift, not user edits):**
- `~/.claude.json` — only a file-mode (`100600`→`100644`) + trailing-newline delta on a
  `modify_dot_claude.json`-managed runtime file. Expected drift; resolves on next apply.
- `.chezmoiscripts/sheldon-lock.sh` — the `R` status is the rendered
  `run_onchange_after_sheldon-lock.sh.tmpl` queued to run, not a target file edit.

---

## Requirements

- **R1** — Source `dot_zshrc` reproduces the target's `git-wt` init line at the same
  logical position (with the other `command -v … && eval` activation lines).
- **R2** — Source `dot_config/mise/config.toml` includes `herdr = "0.7.3"` in the
  `[tools]` table, preserving alphabetical ordering.
- **R3** — Source `dot_gitconfig.tmpl` includes the `[wt]` section (with its `# git-wt`
  comment) placed so it renders correctly for both `work` and `personal` profiles.
- **R4** — Source `dot_gitignore` matches the target's ignore entries: adds `.gstack/`
  and `docs/superpowers/`, and normalizes `docs/plans` → `docs/plans/`.
- **R5** — After edits, `chezmoi diff` shows **no** content drift for these four files
  (only the unrelated `.claude.json` mode/newline and `sheldon-lock` script may remain).
- **R6** — `make lint` passes (secretlint, shfmt, template validation, etc.).

---

## Key Technical Decisions

- **KTD1 — Manual source edits, not `chezmoi re-add`.** `dot_gitconfig.tmpl` is a Go
  template; `chezmoi re-add` would overwrite the template with the literal rendered
  target, destroying the `{{ }}` profile conditionals. The other three are simple
  single-line/entry additions. Manual edits give precise, reviewable control and avoid
  re-add's template clobbering — consistent with CLAUDE.md guidance to never let chezmoi
  auto-tooling touch templates and JSON.
- **KTD2 — Reflect faithfully, verify with `chezmoi diff`.** The success signal for a
  reflect is a clean `chezmoi diff` (source now equals target), which is a runtime/smoke
  check rather than a unit test. No application logic changes, so there are no code tests
  to add.
- **KTD3 — `[wt]` placement in the template.** Insert `[wt]` before the
  `### 会社用設定` profile-conditional block so it lands in the unconditional (shared)
  portion of the rendered gitconfig, matching the target where it sits above the work
  overrides.

---

## Scope Boundaries

**In scope:** Reflecting the four target-only edits (R1–R4) into their source files.

### Deferred to Follow-Up Work
- None.

### Non-goals
- Touching `~/.claude.json` mode/newline drift (expected `modify_` runtime behavior).
- Running or re-authoring the `sheldon-lock` onchange script.
- Evaluating whether `git-wt` overlaps with the existing `gtr`/`git gtr` worktree tooling
  already in `dot_zshrc` — reflect the user's choice as-is; do not editorialize.

---

## Implementation Units

### U1. Add git-wt init line to `dot_zshrc`

- **Goal:** Persist the `git-wt` shell activation into source (R1).
- **Dependencies:** none.
- **Files:** `dot_zshrc`
- **Approach:** Add the line
  `command -v git-wt &>/dev/null && eval "$(git wt --init zsh)"`
  in the block of `command -v … && eval …` activation lines, immediately before the
  `command -v mise …` line (mirroring the target's ordering after the gtr init block).
- **Execution note:** No unit test; verify via `chezmoi diff -- ~/.zshrc` being clean.
- **Test scenarios:** `Test expectation: none -- shell config line, verified by clean chezmoi diff.`
- **Verification:** `chezmoi diff -- "$HOME/.zshrc"` shows no output.

### U2. Add `herdr` tool pin to `dot_config/mise/config.toml`

- **Goal:** Persist `herdr = "0.7.3"` into the mise `[tools]` table (R2).
- **Dependencies:** none.
- **Files:** `dot_config/mise/config.toml`
- **Approach:** Insert `herdr = "0.7.3"` between `bun = "latest"` and `node = "24"`,
  preserving the existing alphabetical ordering of the table.
- **Execution note:** No unit test; verify via clean `chezmoi diff`.
- **Test scenarios:** `Test expectation: none -- tool version pin, verified by clean chezmoi diff.`
- **Verification:** `chezmoi diff -- "$HOME/.config/mise/config.toml"` shows no output.

### U3. Add `[wt]` section to `dot_gitconfig.tmpl`

- **Goal:** Persist the git-wt config section into the templated gitconfig (R3).
- **Dependencies:** none.
- **Files:** `dot_gitconfig.tmpl`
- **Approach:** Insert, after the `[gpg "ssh"]` `program = …` line and before the
  `### 会社用設定` block:
  ```
  # git-wt
  [wt]
    basedir = ".claude/worktrees"
    copy = "docs/"
  ```
  This lands in the unconditional portion of the template so it renders for every
  profile (KTD3). Do not wrap it in a `{{ if }}` guard.
- **Execution note:** Template change — verify the rendered output first with
  `chezmoi execute-template` / `chezmoi cat`, then a clean `chezmoi diff`.
- **Test scenarios:**
  - Rendered `~/.gitconfig` (via `chezmoi cat "$HOME/.gitconfig"`) contains the `[wt]`
    section with `basedir` and `copy` keys.
  - `Covers R3.` Template still renders valid gitconfig with no Go-template errors.
- **Verification:** `chezmoi diff -- "$HOME/.gitconfig"` shows no output; `make check-templates` passes.

### U4. Reconcile ignore entries in `dot_gitignore`

- **Goal:** Match source ignore entries to target (R4).
- **Dependencies:** none.
- **Files:** `dot_gitignore`
- **Approach:** In the block currently containing `docs/plans`, replace/extend so the
  source matches the target's three entries in order: `.gstack/`, `docs/plans/`,
  `docs/superpowers/` (i.e., add `.gstack/` and `docs/superpowers/`, and normalize
  `docs/plans` → `docs/plans/`). Preserve surrounding lines (`.serena/`, `claudedocs/`,
  `.takt/` above; blank line + `**/.claude/.cc-writes/` below).
- **Execution note:** No unit test; verify via clean `chezmoi diff`.
- **Test scenarios:** `Test expectation: none -- gitignore entries, verified by clean chezmoi diff.`
- **Verification:** `chezmoi diff -- "$HOME/.gitignore"` shows no output.

---

## Verification

Global checks after all units (R5, R6):

1. `chezmoi diff` — the four target files show **no** content drift. Only the unrelated
   `.claude.json` mode/newline delta and the `sheldon-lock` script run may remain.
2. `make lint` passes (secretlint, shellcheck/shfmt where applicable, template
   validation via `make check-templates`, sensitive-info scan).
3. Spot-check rendered templated gitconfig with `chezmoi cat "$HOME/.gitconfig"` to
   confirm the `[wt]` section renders under both profiles.

## Definition of Done

- All four source files updated (U1–U4).
- `chezmoi diff` clean for the reflected files (R5).
- `make lint` green (R6).
