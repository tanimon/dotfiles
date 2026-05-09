---
title: "feat: Manage Karabiner Elements complex modification rules under chezmoi"
type: feat
status: active
date: 2026-05-09
---

# feat: Manage Karabiner Elements complex modification rules under chezmoi

## Summary

Bring Karabiner Elements complex modification rules under chezmoi management by storing the rules array as a standalone JSON file in the source tree and using a `modify_` script (mirroring the `modify_dot_claude.json` pattern) to merge those rules into `~/.config/karabiner/karabiner.json` while preserving Karabiner's machine-specific runtime state. This makes the rules portable, version-controlled, and reproducible across machines without conflicting with Karabiner Elements' GUI-driven file rewrites.

---

## Problem Frame

Karabiner Elements stores the user's active complex modification rules inline at `~/.config/karabiner/karabiner.json` under `profiles[*].complex_modifications.rules`. The same file also contains machine-specific runtime state — `machine_specific.krbn-<UUID>` (per-machine UUID, external editor path), profile metadata (`name`, `selected`), and `virtual_hid_keyboard` — that Karabiner rewrites on every GUI interaction and on every save. Today only one rule exists ("日本語入力モードにおける全角スペースと半角スペースの入力を入れ替える"), but it is not version-controlled, not portable, and there is no path for adding more rules declaratively as the dotfiles inventory grows.

This is exactly the runtime-mutable-file shape that the repo already solves for `~/.claude.json` via `modify_dot_claude.json` — chezmoi owns a subset of keys and `jq` merges them while preserving everything else.

---

## Requirements

- R1. Place all complex modification rules under chezmoi source control as a single, diff-friendly JSON file
- R2. On `chezmoi apply`, the rules in the source file are reflected in `~/.config/karabiner/karabiner.json`
- R3. Karabiner-managed runtime state (`machine_specific`, profile metadata, `virtual_hid_keyboard`) is preserved untouched across applies
- R4. New-machine bootstrap (where `~/.config/karabiner/karabiner.json` does not yet exist) produces a valid Karabiner-readable file populated with the rules
- R5. The pattern is exercised by `make test-modify` so regressions are caught in CI
- R6. Repository documentation explains the new pattern alongside the existing `modify_dot_claude.json` reference
- R7. Existing rule "日本語入力モードにおける全角スペースと半角スペースの入力を入れ替える" is migrated into the new source file with no behavior change

---

## Scope Boundaries

- Not adopting `assets/complex_modifications/` (importable rule library, requires manual GUI import — does not satisfy R2)
- Not managing `karabiner.json` as a fully-owned `.tmpl` (would clobber `machine_specific` UUID and Karabiner-managed device settings — violates R3)
- Not managing `~/.config/karabiner/automatic_backups/` (Karabiner runtime artifacts — explicitly ignored)
- Not handling per-profile divergent rule sets — V1 applies the same rules array to every profile in `karabiner.json` (currently only one profile exists)
- Not adding new complex modification rules beyond migrating the one existing rule
- Not implementing reverse sync (GUI changes back into the source tree) — users edit the source file, then `chezmoi apply`

### Deferred to Follow-Up Work

- Per-profile rule divergence (e.g., laptop-only vs external-keyboard profile rule sets): defer until a second profile is actually needed
- Splitting rules into one-file-per-rule under `dot_config/karabiner/complex_modifications/`: defer until rule count or diff churn justifies it (YAGNI)

---

## Context & Research

### Relevant Code and Patterns

- `modify_dot_claude.json` — canonical reference for the `modify_` + `jq` partial-management pattern. Reads stdin (current target), reads source from `${CHEZMOI_SOURCE_DIR}/dot_claude/mcp-servers.json`, replaces only the `mcpServers` key. Has well-defined fallback paths: missing `jq` → passthrough stdin with warning; missing/invalid source file → passthrough stdin with warning; empty stdin → bootstrap from `{}`.
- `Makefile` `test-modify` target — exercises three scenarios for `modify_dot_claude.json`: (1) populated stdin preserves existing keys, (2) empty stdin produces valid JSON with the managed key present, (3) missing source file passes stdin through unchanged.
- `Makefile` glob discipline — `JSON_FILES := $(shell find . -type f -name '*.json' ! -name 'modify_*' ...)` already excludes `modify_*` files from JSON formatters/linters that would mangle the bash content.
- `CLAUDE.md` Key Patterns section — already documents the `modify_dot_claude.json` pattern with the "Do not judge `modify_*` files by extension" rule.
- `dot_config/<app>/` layout — existing managed apps (`cmux`, `helix`, `zellij`, etc.) follow a per-app subdirectory convention.

### Institutional Learnings

- `~/.claude/rules/` (project) `chezmoi-patterns.md` — `modify_` files are the right pattern for runtime-mutable files where chezmoi owns a subset of keys (vs `create_` for provision-once or fully-owned `.tmpl`).
- CLAUDE.md "Known Pitfalls": `modify_` scripts must include `set -e`, must NOT use OS guards that wrap the entire script (empty stdout deletes the target on non-matching OS), and must use `printf '%s\n'` rather than `printf '%s'` to preserve trailing newlines stripped by `$(cat)`.
- CLAUDE.md "Known Pitfalls": file-type-based linter globs need `! -name 'modify_*'` exclusions so JSON-named bash scripts are not linted as JSON.

### External References

- Karabiner Elements file format: `karabiner.json` top-level keys are `machine_specific` (object keyed by per-machine UUID) and `profiles` (array). Each profile has `complex_modifications.rules`, `name`, `selected`, `virtual_hid_keyboard`, plus optional `devices`, `simple_modifications`, `parameters`, etc. Karabiner regenerates `automatic_backups/` on every save.

---

## Key Technical Decisions

- **`modify_` script over fully-owned `.tmpl`**: Karabiner Elements rewrites `karabiner.json` in response to GUI events and persists the per-machine `machine_specific` UUID. A fully-owned template would either drift on every Karabiner save or require committing machine-identifying state. The `modify_` pattern owns only the rules subtree, exactly matching `modify_dot_claude.json`'s rationale for `~/.claude.json`.
- **Single source file vs one-file-per-rule**: V1 uses a single `complex_modifications.json` array. One-file-per-rule trades a flatter diff for more files; with one rule today it is premature splitting (YAGNI).
- **Apply rules to every profile, not only the selected one**: Simplest semantics, matches the user's current single-profile setup, and avoids "rules silently dropped when switching profile" surprises. If multi-profile divergence is ever needed, the script can switch to `.selected == true` in a follow-up.
- **Source data file lives at `dot_config/karabiner/complex_modifications.json`, not as importable assets**: The importable `assets/complex_modifications/` directory requires manual GUI import per machine and does not activate rules — it cannot satisfy R2.
- **No `private_` prefix**: Karabiner's default file mode is `0644` and the rules contain no secrets — `private_` would needlessly diverge from observed permissions.
- **`automatic_backups/` is left unmanaged and added to `.chezmoiignore` defensively**: Prevents accidental `chezmoi add ~/.config/karabiner/` from sucking in Karabiner runtime artifacts.

---

## Open Questions

### Resolved During Planning

- **Pattern choice (`modify_` vs `.tmpl` vs `assets/`)?** → `modify_` script, per the runtime-mutable-file decision in Key Technical Decisions.
- **Scope of merge (one profile vs all)?** → All profiles, V1.
- **Source file granularity?** → Single JSON array, V1.
- **Where to store source?** → `dot_config/karabiner/complex_modifications.json` for the data, `dot_config/karabiner/modify_karabiner.json` for the script, mirroring the existing `dot_config/<app>/` convention.

### Deferred to Implementation

- **Exact bootstrap defaults for empty stdin** (e.g., `keyboard_type_v2` value): the smoke test should pin a sensible neutral default (`"ansi"` is Karabiner's documented fallback); the user can adjust on first GUI launch. Final value to be locked in during U2.
- **Whether `make test-modify` needs to grow new helper plumbing or can inline three scenarios**: follow the existing inline shell pattern for `modify_dot_claude.json` unless duplication becomes painful.

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

Data flow on `chezmoi apply`:

```
~/.config/karabiner/karabiner.json (current target)
        │
        ▼  stdin
┌──────────────────────────────────────────────────┐
│ dot_config/karabiner/modify_karabiner.json       │
│   (bash script, despite .json extension)         │
│                                                  │
│  1. Read stdin (CURRENT)                         │
│  2. Guard: jq missing → passthrough              │
│  3. Guard: source missing/invalid → passthrough  │
│  4. If CURRENT empty → bootstrap minimal shape   │
│  5. jq: for each profile, set                    │
│      .complex_modifications.rules = $rules       │
│  6. Print merged JSON to stdout                  │
└──────────────────────────────────────────────────┘
        │
        ▼  stdout
~/.config/karabiner/karabiner.json (next target)

Source data: dot_config/karabiner/complex_modifications.json
  → JSON array of rule objects
  → Each rule has { description, manipulators: [...] }
```

Preservation semantics:
- Top-level `machine_specific` → preserved verbatim
- `profiles[i].name`, `.selected`, `.virtual_hid_keyboard`, `.simple_modifications`, `.devices`, `.parameters` → preserved verbatim
- `profiles[i].complex_modifications.rules` → replaced from source
- Other keys under `profiles[i].complex_modifications` (e.g., `parameters`) → preserved if present

---

## Implementation Units

### U1. Add complex modification rules source file

**Goal:** Create the chezmoi-managed source-of-truth JSON array containing all complex modification rules.

**Requirements:** R1, R7

**Dependencies:** None

**Files:**
- Create: `dot_config/karabiner/complex_modifications.json`

**Approach:**
- Extract the existing rule from `~/.config/karabiner/karabiner.json` at `.profiles[0].complex_modifications.rules`
- Store as a top-level JSON array (one element today: the JP space-swap rule), preserving exact `description`, `manipulators`, `conditions`, `from`, `to`, and `type` fields
- Use 2-space indentation to match the visual style used in repo JSON snippets and to keep diffs readable when more rules are added later
- Trailing newline at end of file

**Patterns to follow:**
- `dot_claude/mcp-servers.json` — the analogous data file consumed by `modify_dot_claude.json`. JSON, no template, no comments, formatted for diff legibility.

**Test scenarios:**
- Test expectation: none — pure data file with no behavioral logic. Behavior is verified end-to-end via U3's smoke tests, which assert that the file's rules round-trip into the merged target.

**Verification:**
- `jq empty dot_config/karabiner/complex_modifications.json` exits 0 (valid JSON)
- `jq 'type' dot_config/karabiner/complex_modifications.json` returns `"array"`
- `jq '.[0].description' dot_config/karabiner/complex_modifications.json` matches the existing rule's description verbatim

---

### U2. Add `modify_` script that merges rules into `karabiner.json`

**Goal:** Implement the `modify_` script that owns `profiles[*].complex_modifications.rules` while preserving everything else in `karabiner.json`, including bootstrap behavior on empty stdin.

**Requirements:** R2, R3, R4

**Dependencies:** U1

**Files:**
- Create: `dot_config/karabiner/modify_karabiner.json`

**Approach:**
- Bash script with `#!/bin/bash` shebang and `set -euo pipefail`
- Read source path from `${CHEZMOI_SOURCE_DIR}/dot_config/karabiner/complex_modifications.json`
- Read stdin into `CURRENT` via `$(cat)`
- Three guard clauses, each falling back by emitting `CURRENT` (or `{}` if empty) and exiting 0:
  1. `jq` not on PATH → warn to stderr, passthrough
  2. Source file missing or `jq empty` fails on it → warn to stderr, passthrough
  3. Stdin empty → seed `CURRENT` with a bootstrap minimal Karabiner shape (no `machine_specific`; one profile named "Default profile" with `selected: true`, empty `complex_modifications.rules` placeholder, `virtual_hid_keyboard.keyboard_type_v2: "ansi"`)
- Merge step: pipe the (possibly bootstrapped) `CURRENT` through `jq --slurpfile rules <source>` with a filter that sets `.profiles |= map(.complex_modifications.rules = $rules[0])`
- Final output via `printf '%s\n'` (NOT `printf '%s'`) to preserve the trailing newline that `$(cat)` strips
- Do NOT wrap the script body in any OS guard (`{{ if eq .chezmoi.os "darwin" }}`) — empty stdout would zero out the target on non-matching OS per CLAUDE.md known pitfalls
- Even though Karabiner is macOS-only, this script is safe to run on any OS because the target file simply will not exist there and the bootstrap path produces valid output. No OS-specific logic needed.

**Execution note:** Implement the script alongside U3's smoke tests so each scenario (populated stdin, empty stdin, missing source) is exercised before any real `chezmoi apply` runs against the host.

**Technical design:** *(directional — not implementation spec)*

```bash
# Pseudo-shape, not literal code
SOURCE="${CHEZMOI_SOURCE_DIR}/dot_config/karabiner/complex_modifications.json"
CURRENT="$(cat)"

# Guard: jq, source presence/validity → passthrough on failure
# (mirror modify_dot_claude.json shape exactly)

# Bootstrap empty stdin
if [[ -z "$CURRENT" ]]; then
  CURRENT='{ "profiles": [ { "name": "Default profile", "selected": true,
      "complex_modifications": { "rules": [] },
      "virtual_hid_keyboard": { "keyboard_type_v2": "ansi" } } ] }'
fi

# Merge rules into every profile
printf '%s' "$CURRENT" \
  | jq --slurpfile rules "$SOURCE" \
       '.profiles |= map(.complex_modifications.rules = $rules[0])'
```

**Patterns to follow:**
- `modify_dot_claude.json` — match its guard ordering, error messaging style, and `${CHEZMOI_SOURCE_DIR}` usage exactly.

**Test scenarios:**
- Happy path: stdin contains a populated `karabiner.json` with `machine_specific` set and one profile with one outdated rule → output is valid JSON, `machine_specific` preserved verbatim, profile `name` / `selected` / `virtual_hid_keyboard` preserved, `.profiles[0].complex_modifications.rules` equals the source array. (Covers R2, R3.)
- Happy path: stdin contains a `karabiner.json` with two profiles → output replaces `complex_modifications.rules` in BOTH profiles with the source array, both profiles' other fields preserved. (Covers V1 multi-profile semantics from Key Technical Decisions.)
- Edge case: empty stdin (new-machine bootstrap, no Karabiner state yet) → output is valid JSON with `.profiles | length == 1`, the bootstrap profile's `complex_modifications.rules` equals the source array, no `machine_specific` key present. (Covers R4.)
- Edge case: stdin contains a `karabiner.json` whose profile has additional `complex_modifications.parameters` (e.g., `"basic.simultaneous_threshold_milliseconds": 100`) → output preserves that sibling key and only replaces `rules`. (Covers R3 generalization.)
- Error path: source file missing (`CHEZMOI_SOURCE_DIR` points somewhere with no `dot_config/karabiner/complex_modifications.json`) → output equals stdin verbatim, exit 0, warning printed to stderr. (Mirrors `modify_dot_claude.json` behavior; prevents apply from destroying the user's file when the repo is partial.)
- Error path: source file present but invalid JSON → output equals stdin verbatim, exit 0, warning printed to stderr.
- Error path: `jq` not on PATH → output equals stdin verbatim, exit 0, warning printed to stderr.

**Verification:**
- `chezmoi apply --dry-run` reports the target as a `modify_` candidate with no errors
- `chezmoi cat ~/.config/karabiner/karabiner.json` produces valid JSON with `machine_specific` preserved and `.profiles[0].complex_modifications.rules` matching the source

---

### U3. Add `make test-modify` coverage and document the pattern

**Goal:** Lock in the smoke tests for the new modify script and surface the pattern in repository documentation so future contributors discover it.

**Requirements:** R5, R6

**Dependencies:** U1, U2

**Files:**
- Modify: `Makefile` (extend `test-modify` target)
- Modify: `CLAUDE.md` (add a one-paragraph entry under Key Patterns next to the `modify_dot_claude.json` description)
- Modify: `.chezmoiignore` (add `.config/karabiner/automatic_backups` entry to defensively exclude Karabiner runtime backups from any future `chezmoi add ~/.config/karabiner/`)

**Approach:**
- Extend `test-modify` to invoke `bash dot_config/karabiner/modify_karabiner.json` with three scenarios mirroring the existing `modify_dot_claude.json` block: populated stdin, empty stdin, missing source. Use `jq -e` assertions on the merged output to verify rule replacement and runtime-state preservation.
- Set `CHEZMOI_SOURCE_DIR="$$(pwd)"` (matches the existing pattern) so the script reads from the repo's source layout.
- Each assertion failure must print `FAIL: <reason>` and `exit 1`; success prints `PASS: <what>`. Mirror the verbosity of the `modify_dot_claude.json` block.
- CLAUDE.md update: add 2-3 sentences under the existing `modify_dot_claude.json` paragraph describing the Karabiner counterpart, including the "all profiles" semantics and the link to `complex_modifications.json` as the data source. Do NOT duplicate boilerplate explanation of the `modify_` pattern itself.
- `.chezmoiignore` entry: a single line `.config/karabiner/automatic_backups` (target-path style — see CLAUDE.md "Known Pitfalls" on `.chezmoiignore` matching target paths, not source filenames).

**Patterns to follow:**
- The existing three-scenario block in `Makefile` `test-modify` for `modify_dot_claude.json` is the literal template — copy its structure, swap the script path and source file path.
- CLAUDE.md "Key Patterns" section already enumerates `modify_dot_claude.json`, `Declarative marketplace sync`, `Declarative gh extension sync` — append a short "Partial Karabiner management" entry in the same voice.
- `.chezmoiignore` already excludes `~/.claude/` runtime subdirectories like `.claude/projects` — follow the same target-path convention for `.config/karabiner/automatic_backups`.

**Test scenarios:**
- Happy path: `make test-modify` runs to completion with the existing `modify_dot_claude.json` cases AND three new Karabiner cases all passing. (Covers R5.)
- Happy path: the populated-stdin Karabiner case asserts `machine_specific` round-trips, `.profiles[0].name == "Default profile"`, `.profiles[0].complex_modifications.rules | length == 1`, and `.profiles[0].complex_modifications.rules[0].description` matches the source file's first rule description.
- Edge case: empty-stdin Karabiner case asserts the bootstrap output is valid JSON, has at least one profile, and `.profiles[0].complex_modifications.rules` equals the source array.
- Error path: missing-source Karabiner case asserts stdin is passed through unchanged (target byte-for-byte equal to a known input fixture).
- Edge case: documentation regression — `grep -F 'modify_karabiner.json' CLAUDE.md` finds the new entry (informal check during review, not a CI assertion).

**Verification:**
- `make test-modify` exits 0 with PASS lines for both `modify_dot_claude.json` and `modify_karabiner.json` scenarios
- `make lint` passes (test-modify is part of the `lint` target chain — confirms no shellcheck/shfmt regressions in the Makefile changes either)
- `chezmoi managed | grep karabiner` shows both the source data file and the modify script
- A casual reader scanning CLAUDE.md's Key Patterns can identify how Karabiner is managed without opening the script

---

## System-Wide Impact

- **Interaction graph:** Touches the `modify_` execution path on `chezmoi apply` (every apply, not only on hash change). Touches `make test-modify` which runs as part of `make lint` and CI's lint workflow (`.github/workflows/lint.yml`).
- **Error propagation:** All three guard clauses passthrough stdin and exit 0 — chezmoi never sees a non-zero exit, so `chezmoi apply` does not fail when `jq` is missing or the source file is broken. This is intentional and matches `modify_dot_claude.json`'s contract: degrade rather than corrupt the user's file.
- **State lifecycle risks:** Karabiner Elements writes to `karabiner.json` asynchronously (e.g., when the GUI is open). If a write races with `chezmoi apply`, the `modify_` script reads stale stdin from chezmoi and emits a possibly-stale merge. Mitigation: GUI users who see a divergence simply re-apply; the merge is idempotent. There is no destructive failure mode because all preserved fields round-trip exactly.
- **API surface parity:** None — single-tool surface.
- **Integration coverage:** The `make test-modify` smoke tests assert end-to-end merge correctness without requiring a running Karabiner Elements; they cover the contract that integration would otherwise.
- **Unchanged invariants:** `modify_dot_claude.json` and its `~/.claude.json` merge are not touched. The repo's other `dot_config/<app>/` static configs are not touched. The existing rule's behavior in Karabiner is not changed (R7) — only its storage location.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| `jq`-based `.profiles |= map(...)` filter accidentally drops profile-level keys not explicitly preserved | The `|=` update form mutates only the named subkey and leaves siblings untouched; the explicit two-profile + extra-`parameters` smoke test in U3 catches any regression |
| Karabiner Elements writes a new top-level key in a future version that we silently strip | The `modify_` script touches only `profiles[*].complex_modifications.rules`; unknown top-level keys are preserved by definition. Re-validate annually if Karabiner ships a major schema change |
| `modify_*` files appear under `dot_config/karabiner/` and a new linter glob added later does not exclude them | CLAUDE.md "Known Pitfalls" already documents this — code reviewers should flag any new file-type-based glob without a `! -name 'modify_*'` exclusion. The Karabiner script will be exercised by `make test-modify`, so any silent corruption would surface there |
| User edits rules via Karabiner GUI and expects the source file to update automatically | Out of scope for V1 (no reverse sync). Document in CLAUDE.md that the source file is the source of truth and GUI rule edits must be re-synced manually |
| Empty-stdin bootstrap chooses a `keyboard_type_v2` value that conflicts with the user's hardware | "ansi" is the documented Karabiner default; the user-visible impact on a JIS keyboard is one settings tweak after first launch. Acceptable for a bootstrap-only path that almost never fires |

---

## Documentation / Operational Notes

- CLAUDE.md "Key Patterns" gains a Karabiner entry (U3)
- No new external dependencies — `jq` is already required by `modify_dot_claude.json`
- No CI workflow changes — the new smoke tests ride inside the existing `test-modify` target which is already part of `make lint`
- Renovate / `.chezmoiexternal.toml`: untouched — this plan adds no external archives

---

## Sources & References

- Reference script: `modify_dot_claude.json`
- Reference test target: `Makefile` (`test-modify`)
- Documentation home: `CLAUDE.md` Key Patterns section
- Karabiner config probed at planning time: `~/.config/karabiner/karabiner.json` (single profile, one rule)
- Related precedent plans:
  - `docs/plans/2026-04-05-005-feat-chezmoi-manage-cmux-settings-plan.md` (chezmoi config-management precedent for a sibling app)
  - The `modify_dot_claude.json` history captures the original runtime-mutable-file pattern
