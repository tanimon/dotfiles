# File discovery — keep in step with the files:/exclude: filters in .pre-commit-config.yaml (CI calls these recipes through lint.yml)
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
lint: secretlint shellcheck shfmt oxlint oxfmt actionlint zizmor check-composite-actions test-composite-actions test-modify test-scripts check-templates scan-sensitive test-sensitive check-comment-noise test-comment-noise test-pr-context test-harness-scripts check-evaluator-guard test-evaluator-guard check-instruction-size test-instruction-size test-harness-sync check-instructions test-harness-instructions test-global-instructions test-settings-hooks test-gitconfig test-apm-mcp test-apm-install test-nono-profile test-nono-packs test-deliver test-ci-parity

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

# actionlint does not shellcheck composite actions' run: scripts — see the script header
@check-composite-actions:
    bash scripts/check-composite-actions.sh

# Smoke test check-composite-actions.sh. LC_ALL=C for the same bats-core locale
# bug as test-scripts: this suite's @test names are in Japanese.
@test-composite-actions:
    LC_ALL=C pnpm exec bats test/check-composite-actions.bats

# Security audit GitHub Actions workflows and local actions
zizmor:
    #!/usr/bin/env bash
    if command -v zizmor >/dev/null 2>&1; then
        echo "Running zizmor..."
        zizmor .github/
    else
        echo "WARNING: zizmor not found, skipping"
    fi

# Smoke test modify_ scripts
@test-modify:
    pnpm exec bats test/modify-karabiner.bats

# LC_ALL=C works around a bats-core locale bug: under some locales, @test names
# containing non-ASCII characters (notify.bats and
# secretlint-guard.bats have Japanese test names)
# register under a different name than they're looked up by, causing spurious
# "unknown test name" failures (notify.bats: 23 -> 16 executed). See .claude/rules/shell-scripts.md.
# Smoke test hook scripts(ネイティブサンドボックス smoke test の driver / probe も偽の claude で検査する)
@test-scripts:
    LC_ALL=C pnpm exec bats test/notify.bats test/worktree-include.bats test/git-push-guard.bats test/curl-localhost-guard.bats test/secretlint-guard.bats test/shell-reader.bats test/native-sandbox-smoke.bats test/ticket-scope.bats

# Validate chezmoi templates
check-templates:
    #!/usr/bin/env bash
    if command -v chezmoi >/dev/null 2>&1; then
        echo "Validating chezmoi templates..."
        # .profile で分岐するテンプレートは、描画した側の分岐しか実行時に評価されない。
        # 構文エラーは分岐に関係なく parse で落ちるが、未描画の分岐内の実行時エラー
        # (存在しないキーの参照など)は落ちないので、全 profile の fixture で描画する。
        # profile の一覧は test/fixtures/chezmoi-<profile>.toml の実ファイルが正本
        profiles=""
        fail=0
        for config in test/fixtures/chezmoi-*.toml; do
            [ -f "$config" ] || { echo "FAIL: no fixture matches test/fixtures/chezmoi-*.toml"; exit 1; }
            profile=$(basename "$config" .toml)
            profile=${profile#chezmoi-}
            profiles="${profiles:+$profiles }$profile"
            for file in {{tmpl_files}}; do
                rendered=$(chezmoi execute-template \
                    --config "$config" \
                    --source "$(pwd)" \
                    < "$file") || { echo "FAIL: [$profile] $file (render)"; fail=1; continue; }
                case "$file" in
                    *.json.tmpl)
                        printf '%s\n' "$rendered" | jq -e . >/dev/null || { echo "FAIL: [$profile] $file (invalid JSON)"; fail=1; }
                        ;;
                esac
            done
        done
        if [ "$fail" -eq 1 ]; then exit 1; fi
        echo "PASS: all templates valid (profiles: $profiles)"
    else
        # 描画を伴う検査は chezmoi が無ければ素通りせず失敗させる(test/helpers/render.bash と同じ方針)
        echo "FAIL: chezmoi not found (check-templates は skip しない)"
        exit 1
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

# ファイル名は渡さない。スクリプトが `git ls-files` を自分で走査する。
# コードコメントのノイズ(計画の内部番号・経緯の番号・存在しないパス)を検出する
@check-comment-noise:
    bash scripts/check-comment-noise.sh

# LC_ALL=C は bats-core のロケールのバグを避けるため(@test 名が日本語)。
# check-comment-noise.sh のスモークテスト
@test-comment-noise:
    LC_ALL=C pnpm exec bats test/check-comment-noise.bats

# Smoke test pr-context.sh. LC_ALL=C for the same bats-core locale bug as
# test-scripts: this suite's @test names are in Japanese.
@test-pr-context:
    LC_ALL=C pnpm exec bats test/pr-context.bats

# deliver ワークフローの判定ロジックを、agent を stub にして検証する
@test-deliver:
    node --test test/deliver-workflow.test.mjs

# Needs mikefarah yq v4 — fails (not skips) without it, so CI cannot pass vacuously.
# Check that lint.yml runs exactly the lint: recipes minus the local-only group
@test-ci-parity:
    LC_ALL=C pnpm exec bats test/ci-parity.bats

# LC_ALL=C for the same bats-core locale bug as test-scripts: the weekly-job
# tests in briefing / doctor / weekly have Japanese @test names.
# Smoke test harness loop scripts (reflect-trigger, briefing, doctor, weekly job)
@test-harness-scripts:
    LC_ALL=C pnpm exec bats test/harness-reflect-trigger.bats test/harness-briefing.bats test/harness-doctor.bats test/harness-weekly.bats

# 人の PR とローカルの通常のブランチでは何も判定せずに通る。CI の base は merge commit の第 1 親。
# 自己改善ループの PR(ブランチ名 harness/review-*)が Evaluator のパスに触れていたら落とす
@check-evaluator-guard:
    bash scripts/check-evaluator-guard.sh

# LC_ALL=C は bats-core のロケールのバグを避けるため(@test 名が日本語)。
# check-evaluator-guard.sh のテスト
@test-evaluator-guard:
    LC_ALL=C pnpm exec bats test/check-evaluator-guard.bats

# ルールと指示のファイルごとのサイズ上限(上限と根拠は scripts/instruction-size-limits.txt)
@check-instruction-size:
    bash scripts/check-instruction-size.sh

# check-instruction-size.sh のテスト。LC_ALL=C は test-scripts と同じ bats-core のロケールの不具合の回避
@test-instruction-size:
    LC_ALL=C pnpm exec bats test/check-instruction-size.bats

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

# Needs chezmoi — fails (not skips) without it, for the same reason as above.
# Contract test for the hook wiring in the rendered ~/.claude/settings.json (guards, script paths, deny fallback, orca)
@test-settings-hooks:
    LC_ALL=C pnpm exec bats test/settings-hooks.bats

# Needs chezmoi — fails (not skips) without it, for the same reason as above.
# Push without writing upstream to .git/config, through the rendered ~/.gitconfig + claude-code.inc
@test-gitconfig:
    LC_ALL=C pnpm exec bats test/gitconfig.bats

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
[group('local-only')]
@test-nono-profile:
    pnpm exec bats test/nono-profile.bats

# The nono pack sync script drives a fake nono. Local only: the template is
# darwin-only, so it renders empty on the ubuntu CI runner (the suite skips there).
# Smoke test the nono pack sync script (version hash + pull/update)
[group('local-only')]
@test-nono-packs:
    LC_ALL=C pnpm exec bats test/nono-packs-script.bats

# ネイティブ Bash サンドボックス(command claude 経路)の振る舞いを claude -p のプローブで確かめる。
# 素のターミナル(サンドボックスの外)で人間が実行する。API 費用がかかり、サンドボックスの内側では
# 意味を持たないので lint と CI には入れない。検証対象はブランチの source ではなくデプロイ済みの ~/.claude/settings.json
# Smoke test the native Bash sandbox via claude -p (paid; run from a plain terminal)
[group('local-only')]
@smoke-native-sandbox:
    bash scripts/native-sandbox-smoke.sh
