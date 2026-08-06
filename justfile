# File discovery — mirrors .github/workflows/lint.yml and .pre-commit-config.yaml
# `| tr '\n' ' '` is required: unlike GNU Make's $(shell ...), just's backtick
# variables do NOT collapse embedded newlines to spaces, so without this a
# multi-match `find` would put each path on its own line inside the recipe
# body text instead of space-separating them on one command line.
shell_files := `find . -type f \( -name '*.sh' -o -name '*.bash' -o -name 'executable_*' \) \
    ! -name '*.tmpl' ! -name '*.mts' ! -name '*.ts' ! -name '*.mjs' \
    ! -path './node_modules/*' 2>/dev/null | tr '\n' ' '`

tmpl_files := `find . -name '*.tmpl' \
    ! -path './node_modules/*' \
    ! -name '.chezmoi.toml.tmpl' 2>/dev/null | tr '\n' ' '`

js_ts_files := `find . -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.mts' -o -name '*.ts' \) \
    ! -name '*.tmpl' \
    ! -path './node_modules/*' 2>/dev/null | tr '\n' ' '`

json_files := `find . -type f -name '*.json' \
    ! -path './node_modules/*' \
    ! -name 'pnpm-lock.yaml' \
    ! -name 'modify_*' 2>/dev/null | tr '\n' ' '`

all_md_files := `find . \( -path './node_modules' -o -path './.git' -o -path './.superpowers' \) -prune -o \
    -type f -name '*.md' -print 2>/dev/null | tr '\n' ' '`

# Run all checks (mirrors CI)
lint: secretlint shellcheck shfmt oxlint oxfmt actionlint zizmor test-modify test-scripts check-templates scan-sensitive test-sensitive test-harness-scripts test-nono-profile

# Scan for leaked secrets
@secretlint:
    pnpm exec secretlint '**/*'

# Lint shell scripts
shellcheck:
    #!/usr/bin/env bash
    if command -v shellcheck >/dev/null 2>&1; then
        if [ -n "{{shell_files}}" ]; then
            echo "Running shellcheck..."
            shellcheck {{shell_files}}
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
    LC_ALL=C pnpm exec bats test/notify.bats

# Validate chezmoi templates
check-templates:
    #!/usr/bin/env bash
    if command -v chezmoi >/dev/null 2>&1; then
        echo "Validating chezmoi templates..."
        tmpconfig=$(mktemp "${TMPDIR:-/tmp}/chezmoi-test-XXXXXX.toml") || { echo "FAIL: mktemp failed"; exit 1; }
        printf '[data]\n  profile = "personal"\n  ghOrg = "test-org"\n' > "$tmpconfig"
        fail=0
        for file in {{tmpl_files}}; do
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

# Scan all .md files for sensitive information (PII, credentials, absolute paths)
scan-sensitive:
    #!/usr/bin/env bash
    if [ -n "{{all_md_files}}" ]; then
        echo "Running scan-sensitive-info..."
        bash scripts/scan-sensitive-info.sh {{all_md_files}}
    else
        echo "No .md files found"
    fi

# Smoke test scan-sensitive-info.sh
@test-sensitive:
    pnpm exec bats test/scan-sensitive-info.bats

# Smoke test harness loop scripts (reflect-trigger, briefing, doctor)
@test-harness-scripts:
    pnpm exec bats test/harness-reflect-trigger.bats test/harness-briefing.bats test/harness-doctor.bats

# Validate the nono sandbox profile (local only — CI does not install nono)
@test-nono-profile:
    pnpm exec bats test/nono-profile.bats
