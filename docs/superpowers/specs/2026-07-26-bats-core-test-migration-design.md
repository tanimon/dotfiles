# Shell Script Test Migration to bats-core — Design

**Date:** 2026-07-26
**Status:** Approved (pending user review of this document)
**Issue:** [tanimon/dotfiles#233](https://github.com/tanimon/dotfiles/issues/233)

## Context

Shell script tests in this repository currently live inline inside `Makefile` recipes, as a
hand-rolled shell test framework (no runner — no bats, no shunit2, no bash_unit). The pattern
used throughout: a single `@shell` recipe per Make target, `if`/`grep -q`/`jq -e` checks
followed by `echo "PASS: ..."` or `{ echo "FAIL: ..."; exit 1; }`, fixtures built with a
guarded `mktemp -d "${TMPDIR:-/tmp}/name-XXXXXX"`, and a local `cleanup()` trap. Numbered
"Test N: ..." echo lines are the only test names.

Five Makefile targets implement this pattern:

| Target | Scripts under test |
|---|---|
| `test-modify` | `modify_dot_claude.json`, `dot_config/karabiner/modify_karabiner.json` |
| `test-scripts` | `dot_claude/scripts/executable_notify.sh` |
| `test-harness-scripts` | `executable_harness-reflect-trigger.sh`, `executable_harness-briefing.sh`, `executable_harness-doctor.sh` |
| `test-sensitive` | `scripts/scan-sensitive-info.sh` |
| `test-nono-profile` | `nono profile validate` on `dot_config/nono/profiles/claude-seal.json` (local-only, not run in CI) |

CI (`.github/workflows/lint.yml`) maps each target 1:1 to its own job, calling `make test-*`
directly — the documented philosophy in `.claude/rules/shell-scripts.md` is "local and CI run
the exact same commands."

This hand-rolled approach has produced real, hard-won lessons documented in
`.claude/rules/shell-scripts.md` and `docs/solutions/`:

- An unguarded `mktemp` inside a Makefile recipe can fail silently and the recipe still reaches
  its `echo "PASS"` line (`docs/solutions/integration-issues/makefile-mktemp-silent-pass-and-macos-tmpdir-sandbox.md`).
- Tests must be hermetic against ambient environment variables — `notify.sh`'s test suite once
  passed in CI and failed on the maintainer's own machine because `ORCA_PANE_KEY` /
  `ORCA_AGENT_HOOK_PORT` / `ORCA_AGENT_HOOK_TOKEN` leaked in from the shell.
- `printf` format strings containing `%s` collide with the outer Make recipe's own
  substitution when building fixtures.
- Emptying `$PATH` to test a fallback path also hides `bash`/`jq`/`git`, breaking the test for
  an unrelated reason.

The goal of this migration is to replace the hand-rolled framework with
[bats-core](https://github.com/bats-core/bats-core), while preserving every one of these
lessons in the new idiom, not just carrying over the test cases.

## Decisions

1. **Full migration, single PR.** All five Makefile test targets move to bats-core at once;
   no hand-rolled shell test code remains in the `Makefile` afterward.
2. **Installation via pnpm devDependency.** `bats-core` is published as an npm package. It is
   added to `package.json` `devDependencies` alongside `secretlint`, `oxlint`, and `oxfmt`,
   invoked as `pnpm exec bats`. This guarantees CI (Ubuntu) and local (macOS) run the exact
   same version, pinned in `pnpm-lock.yaml`, and picked up automatically by Renovate — unlike
   a Homebrew formula (needs manual version sync across `darwin/Brewfile` and a CI install
   step) or a `.chezmoiexternal.toml` archive pin (that mechanism exists to deploy files into
   `~/`, not to provision a repo-local test runner).
3. **bats-support + bats-assert as companion libraries.** Also added as pnpm devDependencies.
   Assertions use `assert_success` / `assert_failure` / `assert_output` / `refute_output`
   instead of raw `[ "$status" -eq 0 ]` checks, improving failure messages and readability.
4. **One `.bats` file per script under test**, not per Makefile target. `test-harness-scripts`
   currently tests three unrelated scripts in one recipe; splitting gives each script its own
   file at bats' natural granularity, and new scripts added later get their own file rather
   than growing an existing one.
5. **Makefile targets become thin wrappers** that invoke `pnpm exec bats` against the
   relevant `.bats` file(s), preserving the "local and CI run the exact same commands"
   convention — no changes needed to `.github/workflows/lint.yml`.

## Directory Structure

```
test/
  helpers/
    setup.bash          # loads bats-support/bats-assert; shared fixture helpers
  modify-dot-claude.bats
  modify-karabiner.bats
  notify.bats
  harness-reflect-trigger.bats
  harness-briefing.bats
  harness-doctor.bats
  scan-sensitive-info.bats
  nono-profile.bats
```

`test/` is a repo-only directory (like `docs/`, `package.json`) and must be added to
`.chezmoiignore` — omitting this would deploy it to `~/test/` on `chezmoi apply`, per the
documented pitfall in the root `CLAUDE.md`.

`test/helpers/setup.bash`:

```bash
load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
```

## Makefile / CI Mapping

| Makefile target | `.bats` files invoked |
|---|---|
| `test-modify` | `modify-dot-claude.bats`, `modify-karabiner.bats` |
| `test-scripts` | `notify.bats` |
| `test-harness-scripts` | `harness-reflect-trigger.bats`, `harness-briefing.bats`, `harness-doctor.bats` |
| `test-sensitive` | `scan-sensitive-info.bats` |
| `test-nono-profile` | `nono-profile.bats` (all cases `skip` when the `nono` binary is absent) |

Example:

```make
test-modify:
	pnpm exec bats test/modify-dot-claude.bats test/modify-karabiner.bats
```

`.github/workflows/lint.yml` job steps are unchanged — each still runs `make test-<name>`. No
job exists for `test-nono-profile` today and none is added, since CI does not install `nono`.

## Hermeticity and Temp Directories

bats provides `$BATS_TEST_TMPDIR`, created fresh and cleaned up automatically per `@test`.
This replaces every manual `mktemp -d ... ; cleanup() { rm -rf ... }; trap cleanup EXIT`
pattern in the current Makefile recipes, and structurally eliminates the silent-mktemp-failure
class of bug documented in
`docs/solutions/integration-issues/makefile-mktemp-silent-pass-and-macos-tmpdir-sandbox.md` —
there is no longer a hand-written `mktemp` call whose failure could go unchecked.

Ambient-environment hermeticity (the `notify.sh` lesson) is preserved via `setup()`:

```bash
setup() {
  load 'helpers/setup'
  unset ORCA_PANE_KEY ORCA_AGENT_HOOK_PORT ORCA_AGENT_HOOK_TOKEN
}
```

Individual `@test` cases that need one of these variables set export it explicitly within the
test body, keeping the leak-vs-clean distinction visible at the call site. The existing
verification recipe — running the suite twice, once clean and once with a simulated leak, and
requiring identical results — carries over unchanged:

```sh
pnpm exec bats test/notify.bats
ORCA_PANE_KEY=leak ORCA_AGENT_HOOK_PORT=1 ORCA_AGENT_HOOK_TOKEN=x pnpm exec bats test/notify.bats
```

The other two Makefile-specific gotchas (`printf %s` fixture collisions, testing fallbacks by
emptying `$PATH`) were artifacts of building fixtures inside a Make recipe's own `printf`/shell
substitution; they do not apply once fixture-building code lives in a `.bats` file, but the
underlying lesson — never disable a whole capability (`$PATH`) to test one fallback branch, use
an explicit override variable instead (e.g. `CLAUDE_NOTIFY_BACKEND=osascript`) — is preserved
as guidance in the updated rule file (see Documentation Updates below).

## Linting Interaction

`shellcheck` and `shfmt` exclude `test/**/*.bats`, the same treatment already given to `.tmpl`
files. bats' `@test { ... }` block syntax is not valid plain bash and neither tool parses it
correctly. This is not a regression: the current inline test code embedded in `Makefile`
recipes is not shellchecked today either. The bats suite itself, run via `make test-*`, is the
correctness check for this code.

## Documentation Updates

- **`.claude/rules/shell-scripts.md`**: replace the "Makefile Test Harness Gotchas" section
  with bats-based guidance (temp dirs via `$BATS_TEST_TMPDIR`, hermeticity via `setup()`,
  explicit override variables instead of emptying `$PATH`). Keep the "Tests Must Be Hermetic
  Against Ambient Environment" section, updated to the `setup()` idiom.
- **Root `CLAUDE.md`**: "Common Commands" and "Verification" sections keep the same `make
  test-*` commands (no change). The mktemp-related "Known Pitfalls" entry gets a note that
  bats' automatic tmpdir handling structurally resolved it.
- **`docs/solutions/integration-issues/makefile-mktemp-silent-pass-and-macos-tmpdir-sandbox.md`**:
  append a note that this failure mode no longer applies post-migration, so the historical
  lesson isn't mistaken for a still-live risk.
- **`.pre-commit-config.yaml`**: no change — `test-*` targets are already `make lint`/CI-only,
  not pre-commit hooks.

## Migration Order

Single PR, but scripts are ported in this order to de-risk the pattern before scaling it:

1. `modify-dot-claude.bats` / `modify-karabiner.bats` — smallest scripts, establishes the
   `setup()` / `$BATS_TEST_TMPDIR` / bats-assert pattern.
2. `notify.bats` — validates the hermeticity pattern against a script with real ambient-env
   sensitivity (the double-run leak check above).
3. `harness-reflect-trigger.bats`, `harness-briefing.bats`, `harness-doctor.bats`.
4. `scan-sensitive-info.bats`.
5. `nono-profile.bats`.

Each step removes the corresponding inline recipe from `Makefile` and replaces it with the thin
`pnpm exec bats` wrapper, so at no point do both the old and new implementation of a given
target coexist.

## Out of Scope

- `check-templates` (renders `.tmpl` files via `chezmoi execute-template`) is a distinct
  validation target, not a hand-rolled test suite, and is not part of this migration.
- Untested scripts with no existing Makefile target (`scripts/update-brewfile.sh`,
  `scripts/update-gh-extensions.sh`, `scripts/update-marketplaces.sh`, `.chezmoiscripts/run_onchange_*`)
  are not brought into scope by this migration; adding coverage for them is a separate effort.
