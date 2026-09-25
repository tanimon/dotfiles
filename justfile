# File discovery — mirrors .github/workflows/lint.yml and .pre-commit-config.yaml
# `| tr '\n' ' '` is required: unlike GNU Make's $(shell ...), just's backtick
# variables do NOT collapse embedded newlines to spaces, so without this a
# multi-match `find` would put each path on its own line inside the recipe
# body text instead of space-separating them on one command line.
# It also matters for error handling: GNU Make's $(shell ...) ignores the
# command's exit status, but a failing backtick in just aborts *all* recipes
# (even ones that never reference the variable) with "error: backtick failed
# with exit code 1". `find` can exit non-zero (e.g. an unreadable directory);
# `2>/dev/null` only silences stderr, not the exit code. Piping through `tr`
# (which always exits 0) absorbs that failure. If someone later "simplifies"
# this by dropping the `tr` pipe, or enables `pipefail` via `set shell := [...]`,
# this hard-error mode comes back.
shell_files := `find . -type f \( -name '*.sh' -o -name '*.bash' -o -name 'executable_*' \) \
    ! -name '*.tmpl' ! -name '*.mts' ! -name '*.ts' ! -name '*.mjs' \
    ! -path './node_modules/*' ! -path './.pnpm-store/*' 2>/dev/null | tr '\n' ' '`

tmpl_files := `find . -name '*.tmpl' \
    ! -path './node_modules/*' ! -path './.pnpm-store/*' \
    ! -name '.chezmoi.toml.tmpl' 2>/dev/null | tr '\n' ' '`

js_ts_files := `find . -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.mts' -o -name '*.ts' \) \
    ! -name '*.tmpl' \
    ! -path './node_modules/*' ! -path './.pnpm-store/*' 2>/dev/null | tr '\n' ' '`

json_files := `find . -type f -name '*.json' \
    ! -path './node_modules/*' ! -path './.pnpm-store/*' \
    ! -name 'pnpm-lock.yaml' \
    ! -name 'modify_*' 2>/dev/null | tr '\n' ' '`

# Run all checks (mirrors CI)
lint: secretlint shellcheck shfmt oxlint oxfmt actionlint zizmor test-modify test-scripts check-templates scan-sensitive test-sensitive test-pr-context test-harness-scripts test-harness-sync check-instructions test-harness-instructions test-global-instructions test-apm-mcp test-apm-install test-nono-profile test-nono-packs test-deliver

# Scan for leaked secrets
@secretlint:
    pnpm exec secretlint '**/*'

# Lint shell scripts
shellcheck:
    #!/usr/bin/env bash
    if command -v shellcheck >/dev/null 2>&1; then
        if [ -n "{{shell_files}}" ]; then
            echo "Running shellcheck..."
            shellcheck -x {{shell_files}}
        else
            echo "No shell files found"
        fi
    else
        echo "WARNING: shellcheck not found, skipping"
    fi

# Check shell script formatting
shfmt:
    #!/usr/bin/env bash
    if command -v shfmt >/dev/null 2>&1; then
        if [ -n "{{shell_files}}" ]; then
            echo "Running shfmt..."
            shfmt -d -i 4 {{shell_files}}
        else
            echo "No shell files found"
        fi
    else
        echo "WARNING: shfmt not found, skipping"
    fi

# Lint JS/TS files
oxlint:
    #!/usr/bin/env bash
    if [ -n "{{js_ts_files}}" ]; then
        echo "Running oxlint..."
        pnpm exec oxlint {{js_ts_files}}
    else
        echo "No JS/TS files found"
    fi

# Check JS/TS and JSON formatting
oxfmt:
    #!/usr/bin/env bash
    if [ -n "{{js_ts_files}}{{json_files}}" ]; then
        echo "Running oxfmt..."
        pnpm exec oxfmt --check {{js_ts_files}} {{json_files}}
    else
        echo "No JS/TS or JSON files found"
    fi

# Lint GitHub Actions workflows (syntax + types)
actionlint:
    #!/usr/bin/env bash
    if command -v actionlint >/dev/null 2>&1; then
        echo "Running actionlint..."
        actionlint
    else
        echo "WARNING: actionlint not found, skipping"
    fi

# Security audit GitHub Actions workflows
zizmor:
    #!/usr/bin/env bash
    if command -v zizmor >/dev/null 2>&1; then
        echo "Running zizmor..."
        zizmor .github/workflows/
    else
        echo "WARNING: zizmor not found, skipping"
    fi

# Smoke test modify_ scripts
@test-modify:
    pnpm exec bats test/modify-karabiner.bats

# LC_ALL=C works around a bats-core locale bug: under some locales, @test names
# containing non-ASCII characters (this file's test names are in Japanese)
# register under a different name than they're looked up by, causing spurious
# "unknown test name" failures (23 -> 16 executed). See .claude/rules/shell-scripts.md.
# Smoke test hook scripts
@test-scripts:
    LC_ALL=C pnpm exec bats test/notify.bats test/worktree-include.bats test/git-push-guard.bats test/curl-localhost-guard.bats

# Validate chezmoi templates
check-templates:
    #!/usr/bin/env bash
    if command -v chezmoi >/dev/null 2>&1; then
        echo "Validating chezmoi templates..."
        # chezmoi は --config の拡張子から形式を判別するので .toml が要るが、BSD mktemp
        # (macOS) はテンプレートの X が末尾にないと置換せず literal なファイル名を作る。
        # そのため直接 '...-XXXXXX.toml' を渡すと毎回同じ名前になり、クラッシュ後の残骸や
        # 並行実行で "mkstemp failed: File exists" で落ちる。ディレクトリ側をランダム化する。
        tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/chezmoi-test-XXXXXX") || { echo "FAIL: mktemp failed"; exit 1; }
        trap 'rm -rf "$tmpdir"' EXIT
        tmpconfig="$tmpdir/chezmoi-test.toml"
        printf '[data]\n  profile = "personal"\n  ghOrg = "test-org"\n' > "$tmpconfig"
        fail=0
        for file in {{tmpl_files}}; do
            rendered=$(chezmoi execute-template \
                --config "$tmpconfig" \
                --source "$(pwd)" \
                < "$file") || { echo "FAIL: $file (render)"; fail=1; continue; }
            case "$file" in
                *.json.tmpl)
                    printf '%s\n' "$rendered" | jq -e . >/dev/null || { echo "FAIL: $file (invalid JSON)"; fail=1; }
                    ;;
            esac
        done
        if [ "$fail" -eq 1 ]; then exit 1; fi
        echo "PASS: all templates valid"
    else
        echo "WARNING: chezmoi not found, skipping template validation"
    fi

# No file list is passed: the script does its own repo-wide walk, which also
# keeps the prune list in one place.
# `just --list` shows only the LAST comment line, so keep the one-line
# description last — a trailing rationale line becomes the listed description.
# Scan every file for PII, credentials, absolute paths, and literal work-org names
@scan-sensitive:
    bash scripts/scan-sensitive-info.sh

# Smoke test scan-sensitive-info.sh
@test-sensitive:
    pnpm exec bats test/scan-sensitive-info.bats

# Smoke test pr-context.sh. LC_ALL=C for the same bats-core locale bug as
# test-scripts: this suite's @test names are in Japanese.
@test-pr-context:
    LC_ALL=C pnpm exec bats test/pr-context.bats

# deliver ワークフローの判定ロジックを、agent を stub にして検証する
@test-deliver:
    node --test test/deliver-workflow.test.mjs

# Smoke test harness loop scripts (reflect-trigger, briefing, doctor)
@test-harness-scripts:
    pnpm exec bats test/harness-reflect-trigger.bats test/harness-briefing.bats test/harness-doctor.bats

# Smoke test the harness sync/check seam (harness/bin/harness.sh)
@test-harness-sync:
    LC_ALL=C pnpm exec bats test/harness-sync.bats

# Not part of `lint` — `lint` only checks for drift, it never rewrites tracked files.
# Regenerate CLAUDE.md / AGENTS.md / .cursor/rules from harness/modules/ + project.json
@harness-sync:
    bash harness/bin/harness.sh sync --manifest harness/project.json \
        --root {{ justfile_directory() }} --source-dir {{ justfile_directory() }}

# --no-probe skips the Capability Probe because CI has no claude/codex/cursor
# installed; the skip is printed, so a green run never claims the products loaded.
# Fail if a generated agent instruction Target was hand-edited
@check-instructions:
    bash harness/bin/harness.sh check --manifest harness/project.json \
        --root {{ justfile_directory() }} --source-dir {{ justfile_directory() }} --no-probe

# Smoke test the project instruction sync (compose adapter, --no-probe, generated Targets)
@test-harness-instructions:
    LC_ALL=C pnpm exec bats test/harness-instructions.bats

# Needs chezmoi — the suite fails (not skips) without it, so a green run never
# claims the templates rendered when they were never executed.
# Smoke test the global instruction composition (~/.claude/CLAUDE.md + ~/.codex/AGENTS.md)
@test-global-instructions:
    LC_ALL=C pnpm exec bats test/global-instructions.bats

# The static Source checks always run; the behaviour checks need the apm CLI and
# skip without it — bats prints the skip reason, so a green run never claims the
# distribution was measured when apm was absent.
# Smoke test the MCP distribution to claude + codex (dot_apm/apm.yml + install script)
@test-apm-mcp:
    LC_ALL=C pnpm exec bats test/apm-mcp-distribution.bats

# The de-link / install / re-link logic around ~/.claude.json. Drives a fake apm
# against a fake home, so no real apm or nono is involved.
@test-apm-install:
    LC_ALL=C pnpm exec bats test/apm-install-global.bats

# Validate the nono sandbox profile (local only — CI does not install nono)
@test-nono-profile:
    pnpm exec bats test/nono-profile.bats

# The nono pack sync script drives a fake nono. Local only: the template is
# darwin-only, so it renders empty on the ubuntu CI runner (the suite skips there).
# Smoke test the nono pack sync script (version hash + pull/update)
@test-nono-packs:
    LC_ALL=C pnpm exec bats test/nono-packs-script.bats
