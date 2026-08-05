# Makefile to justfile Migration — Design

**Date:** 2026-08-06
**Status:** Approved (pending user review of this document)
**Issue:** [tanimon/dotfiles#232](https://github.com/tanimon/dotfiles/issues/232)

## Context

This repository's task runner is a GNU `Makefile` at the repo root with 15 targets
(`lint`, `secretlint`, `shellcheck`, `shfmt`, `oxlint`, `oxfmt`, `actionlint`, `zizmor`,
`test-modify`, `test-scripts`, `check-templates`, `scan-sensitive`, `test-sensitive`,
`test-harness-scripts`, `test-nono-profile`). `lint` is a meta-target depending on the other
14. Five `SHELL`/`shell`-computed variables (`SHELL_FILES`, `TMPL_FILES`, `JS_TS_FILES`,
`JSON_FILES`, `ALL_MD_FILES`) drive file discovery via `find`, evaluated once via GNU Make's
`:=` (immediate expansion).

`make <target>` is called from many places:

- `.github/workflows/lint.yml` — every job invokes exactly one `make <target>` as its final
  step.
- `.github/workflows/security-alerts.yml` — references `make lint` in an instructional prompt
  and lists `Bash(make *)` in `claude_args.allowedTools`.
- `package.json` — `"lint": "make lint"` script.
- `dot_claude/settings.json.tmpl` — `"Bash(make:*)"` in the permissions `allow` list, plus a
  template comment documenting an accepted permission hole specific to `make lint` invoking
  `pnpm` as a subprocess without a prompt.
- `CLAUDE.md`, `.claude/rules/shell-scripts.md`, `dot_config/nono/CLAUDE.md`,
  `dot_claude/skills/harness-review/SKILL.md` — documentation referencing `make lint` and
  individual targets as the way to run checks.

The goal of this migration is to replace `make` with [just](https://github.com/casey/just) as
the task runner, end to end — no dual-running period, no leftover `Bash(make:*)` permission.

## Decisions

1. **Full migration, `Makefile` deleted.** A new `justfile` at the repo root replaces
   `Makefile` entirely. Every call site listed above is updated from `make X` to `just X` in
   the same change; none are left pointing at `make`.
2. **Recipe names and behavior are preserved 1:1.** All 15 target names carry over unchanged
   as just recipe names, with identical logic, so external references that already say
   `<name>` (not `make <name>`) — e.g. `.claude/rules/shell-scripts.md` prose like "individual
   targets: `shellcheck`, `shfmt`" — need only the invocation prefix changed.
3. **just is installed via its official install script**, matching the existing pattern
   `shfmt` and `actionlint` already use in `.github/workflows/lint.yml` (pinned-version curl
   install), rather than a third-party GitHub Action or a new mise dependency. Locally,
   `darwin/Brewfile` gets a `brew "just"` line.
4. **Every CI job that needs `just` repeats its own install step**, consistent with how
   `shfmt`/`actionlint`/`zizmor` installation is already duplicated per job in
   `lint.yml` today. No new composite action under `.github/actions/` is introduced for this.
5. **Complex multi-line recipes are rewritten as shebang scripts**, not ported verbatim with
   Make-style backslash line continuations. Affected recipes: `shellcheck`, `shfmt`, `oxlint`,
   `oxfmt`, `check-templates`, `scan-sensitive`. Each gets a `#!/usr/bin/env bash` as the first
   line of its recipe body, executing as a single script — just's native idiom for multi-line
   logic, and it naturally runs quietly (no per-line echo), matching the current `@`-prefixed
   Make behavior without needing an explicit quiet marker. `$$` becomes `$` throughout (just
   does not require doubling `$` for literal use — only `{{ }}` is special), and `$(VAR)`
   becomes `{{ variable }}`.
6. **Historical documents are not touched.** `docs/plans/**` and `docs/solutions/**` describe
   the state of the repo at a point in time and are left referencing `make` as a historical
   record, except where a doc's stated purpose is forward-looking guidance still in effect
   (none qualify here — the one closely related doc,
   `docs/solutions/integration-issues/makefile-mktemp-silent-pass-and-macos-tmpdir-sandbox.md`,
   already has a 2026-07-26 addendum noting its failure mode no longer applies post-bats
   migration; no further edit needed).

## justfile Structure

### Variables

The five Make variables port to just's backtick command-substitution variables, evaluated once
at parse time (matching Make's `:=` semantics). Names move to just's conventional
`lower_snake_case` — purely an internal rename, since these variables are never referenced
outside the justfile:

```just
shell_files := `find . -type f \( -name '*.sh' -o -name '*.bash' -o -name 'executable_*' \) \
    ! -name '*.tmpl' ! -name '*.mts' ! -name '*.ts' ! -name '*.mjs' \
    ! -path './node_modules/*' 2>/dev/null`

tmpl_files := `find . -name '*.tmpl' \
    ! -path './node_modules/*' \
    ! -name '.chezmoi.toml.tmpl' 2>/dev/null`

js_ts_files := `find . -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.mts' -o -name '*.ts' \) \
    ! -name '*.tmpl' \
    ! -path './node_modules/*' 2>/dev/null`

json_files := `find . -type f -name '*.json' \
    ! -path './node_modules/*' \
    ! -name 'pnpm-lock.yaml' \
    ! -name 'modify_*' 2>/dev/null`

all_md_files := `find . \( -path './node_modules' -o -path './.git' -o -path './.superpowers' \) -prune -o \
    -type f -name '*.md' -print 2>/dev/null`
```

### Meta recipe and dependencies

`lint` keeps the same dependency-list shape Make used, which just supports natively:

```just
## Run all checks (mirrors CI)
lint: secretlint shellcheck shfmt oxlint oxfmt actionlint zizmor test-modify test-scripts check-templates scan-sensitive test-sensitive test-harness-scripts test-nono-profile
```

No `.PHONY` equivalent is needed — just recipes never collide with same-named files, so the
concept doesn't exist in just.

### Simple recipes

One-line recipes stay one line, e.g.:

```just
## Scan for leaked secrets
secretlint:
    pnpm exec secretlint '**/*'

## Smoke test modify_ scripts
test-modify:
    pnpm exec bats test/modify-karabiner.bats
```

(The leading `@` Make used for quiet output is dropped — just doesn't echo simple recipe lines
containing only one command in the same way Make does; verified during implementation that
output stays equivalent. If it doesn't, `@` is just's own quiet-line prefix and can be restored
per line.)

### Shebang recipes

Recipes with conditional/multi-line logic become shebang scripts. Example (`shellcheck`):

```just
## Lint shell scripts
shellcheck:
    #!/usr/bin/env bash
    if command -v shellcheck >/dev/null 2>&1; then
        if [ -n "{{ shell_files }}" ]; then
            echo "Running shellcheck..."
            shellcheck {{ shell_files }}
        else
            echo "No shell files found"
        fi
    else
        echo "WARNING: shellcheck not found, skipping"
    fi
```

`check-templates` keeps its guarded `mktemp` call verbatim in logic (only `$$` → `$`), since
that guard exists specifically to prevent the silent-PASS bug documented in
`docs/solutions/integration-issues/makefile-mktemp-silent-pass-and-macos-tmpdir-sandbox.md`:

```just
## Validate chezmoi templates
check-templates:
    #!/usr/bin/env bash
    if command -v chezmoi >/dev/null 2>&1; then
        echo "Validating chezmoi templates..."
        tmpconfig=$(mktemp "${TMPDIR:-/tmp}/chezmoi-test-XXXXXX.toml") || { echo "FAIL: mktemp failed"; exit 1; }
        printf '[data]\n  profile = "personal"\n  ghOrg = "test-org"\n' > "$tmpconfig"
        fail=0
        for file in {{ tmpl_files }}; do
            chezmoi execute-template \
                --config "$tmpconfig" \
                --source "$(pwd)" \
                < "$file" > /dev/null || { echo "FAIL: $file"; fail=1; }
        done
        rm -f "$tmpconfig"
        if [ "$fail" -eq 1 ]; then exit 1; fi
        echo "PASS: all templates valid"
    else
        echo "WARNING: chezmoi not found, skipping template validation"
    fi
```

### Doc comments

The existing `## <description>` comment convention above each Make target is kept verbatim
(`##` reads as a plain comment to just, so no functional change), but since just natively
parses a single `#` comment immediately above a recipe as its description for `just --list`,
this migration switches to single `#` so `just --list` shows descriptions for free. This is an
incidental improvement riding along with the required syntax change, not new scope.

## just Installation

### Local (macOS)

`darwin/Brewfile` gains one line:

```ruby
brew "just"
```

in alphabetical position alongside the other CLI tools (`shellcheck`, `actionlint`, `shfmt`,
`zizmor`).

### CI

Every `lint.yml` job that runs a `just <target>` step gains an install step immediately before
it, following the exact pattern `shfmt` uses today:

```yaml
- name: Install just
  run: |
    JUST_VERSION=1.x.y
    curl -fsSL "https://github.com/casey/just/releases/download/${JUST_VERSION}/just-${JUST_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
      | tar xz -C /usr/local/bin just
- run: just <target>
```

(Exact version pinned at implementation time to the latest just release; asset name verified
against the actual release artifact list before use.) This step is duplicated per job, matching
how `shfmt`/`actionlint`/`zizmor` installation is already duplicated rather than factored into
a shared composite action — see Decision 4.

## Call Site Updates

| File | Change |
|---|---|
| `.github/workflows/lint.yml` | Every job's final `run: make <target>` → `run: just <target>`, each preceded by the just-install step above. |
| `.github/workflows/security-alerts.yml` | `Run \`make lint\` before any commits` → `Run \`just lint\` before any commits`; `Bash(make *)` → `Bash(just *)` in `claude_args.allowedTools`. |
| `package.json` | `"lint": "make lint"` → `"lint": "just lint"`. |
| `dot_claude/settings.json.tmpl` | `"Bash(make:*)"` → `"Bash(just:*)"` in the `allow` list; the template comment documenting the `make lint` → `pnpm` subprocess permission hole is reworded to say `just lint`. |
| `CLAUDE.md` | "Common Commands" and "Verification" sections: all `make <target>` examples → `just <target>`. |
| `.claude/rules/shell-scripts.md` | `make lint` / `make shellcheck` / etc. prose and example commands → `just` equivalents. |
| `dot_config/nono/CLAUDE.md` | References to `make oxfmt`, `make test-nono-profile`, `make lint` (used as illustrative examples of what secretlint/oxfmt cover) → `just` equivalents. |
| `dot_claude/skills/harness-review/SKILL.md` | `Run \`make lint\` and fix findings.` → `Run \`just lint\` and fix findings.` |

`docs/plans/**` and `docs/solutions/**` are excluded from this table per Decision 6.

## Makefile Removal

`Makefile` is deleted once `justfile` is confirmed equivalent (see Verification).

## Verification

1. Run `just lint` locally end to end; confirm every sub-recipe reports the same PASS/WARNING
   output shape as the current `make lint` (diff the two runs' output where feasible before
   deleting `Makefile`).
2. Run each individual recipe (`just shellcheck`, `just shfmt`, `just oxlint`, `just oxfmt`,
   `just actionlint`, `just zizmor`, `just test-modify`, `just test-scripts`,
   `just check-templates`, `just scan-sensitive`, `just test-sensitive`,
   `just test-harness-scripts`, `just test-nono-profile`, `just secretlint`) standalone and
   confirm exit codes and output match the Make targets they replace.
3. For `check-templates` specifically, re-run the sandboxed-vs-unsandboxed contrast check
   described in the mktemp solutions doc (run under a sandbox that denies `/tmp` writes, and
   run unsandboxed) to confirm the guard still fires correctly after the `$$` → `$` rewrite.
4. Confirm `git grep -n 'make '` (word-boundary check) across all non-`docs/plans`,
   non-`docs/solutions` tracked files returns no remaining live call sites once the Call Site
   Updates table is applied.
5. `pnpm run lint` (which now shells out to `just lint` via `package.json`) passes.

## Out of Scope

- Reorganizing recipe names, splitting `lint` into finer-grained groups, or adopting just
  features not needed for a 1:1 port (e.g. `[group('name')]` attributes, recipe parameters,
  `mod` imports) — YAGNI for this migration.
- `.pre-commit-config.yaml` — it does not invoke `make`/`just` targets directly today and is
  unaffected.
- Any change to what each check actually validates (secretlint rules, shellcheck flags, etc.)
  — this is a task-runner substitution only, not a lint-policy change.
