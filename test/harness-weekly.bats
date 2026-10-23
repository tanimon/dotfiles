# 週次ジョブの入口(harness-weekly.sh)の振る舞い検査。
#
# スクリプトは launchd が nono の内側で起動する前提なので、既定では
# INSIDE_NONO_SANDBOX=1 で実行する。nono のスタブは呼ばれたら失敗する
# (スクリプトが nono を自分で掛けないことの検査)。
# claude / uuidgen は PATH 上のスタブに差し替える。claude のスタブは
# --session-id で渡された id を pending.jsonl に積み(SessionEnd hook が
# ジョブ自身のセッションを積む状況の再現)、結果の JSON を出す。
# 成否は STUB_CLAUDE_MODE(success / is_error / exit1)で切り替える。
#
# 選別の工程(プロンプトが harness-review を指すもの)では、claude のスタブが
# cwd(ジョブが用意した worktree)で STUB_REVIEW_MODE に応じた変更と commit を行い、
# queue の項目の Verdict を本物の Verdict の CLI(settle)で記録する。採用の印は、ジョブが
# 環境変数 HARNESS_REVIEW_RUN で渡したものを CLI が付ける(スタブは prompt から読まない)。
# git は実物を使い、origin は使い捨ての bare リポジトリにする。GIT_CONFIG_GLOBAL /
# GIT_CONFIG_SYSTEM を潰すのは、このマシンの署名や push の設定を持ち込まないため。
# gh と pnpm はスタブで、gh は呼ばれた引数と --body-file の中身を記録する。
setup() {
    load 'helpers/setup'
    load 'helpers/exec-cache'
    # スクリプトが読む環境変数を、このマシンのシェルから漏らさない
    unset HARNESS_DISABLE HARNESS_WEEKLY_BUDGET_USD HARNESS_WEEKLY_MAX_SESSIONS \
        HARNESS_WEEKLY_REVIEW_BUDGET_USD HARNESS_WEEKLY_REPO \
        HARNESS_CLASSIFY_BUDGET_USD HARNESS_CLASSIFY_MAX_ITEMS HARNESS_WEEKLY_EVAL_BUDGET_USD \
        HARNESS_EVAL_RUNS HARNESS_EVAL_BUDGET_USD HARNESS_EVAL_MAX_CASES HARNESS_EVAL_MAX_HISTORY_BYTES HARNESS_EVAL_PLUGIN_TEMPLATE \
        HARNESS_REVIEW_RUN
    export INSIDE_NONO_SANDBOX=1
    SCRIPT="$BATS_TEST_DIRNAME/../dot_claude/scripts/executable_harness-weekly.sh"
    export HOME="$BATS_TEST_TMPDIR/home"
    HDIR="$HOME/.claude/harness"
    mkdir -p "$HDIR"
    STUBS="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STUBS"
    export ARGV_LOG="$BATS_TEST_TMPDIR/argv.log"
    export ENV_LOG="$BATS_TEST_TMPDIR/env.log"
    export CWD_LOG="$BATS_TEST_TMPDIR/cwd.log"
    export STAGE_LOG="$BATS_TEST_TMPDIR/stage.log"
    export GH_LOG="$BATS_TEST_TMPDIR/gh.log"
    export GH_BODY="$BATS_TEST_TMPDIR/gh-body.md"
    export ALERT_LOG="$BATS_TEST_TMPDIR/alert.log"
    export ALERT_BODIES="$BATS_TEST_TMPDIR/alert-bodies.md"
    export PNPM_LOG="$BATS_TEST_TMPDIR/pnpm.log"
    export REVIEW_RUN_LOG="$BATS_TEST_TMPDIR/review-run.log"

    export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
    export GIT_CONFIG_SYSTEM=/dev/null
    printf '[user]\n\tname = test\n\temail = test@example.com\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n' \
        >"$GIT_CONFIG_GLOBAL"
    ORIGIN="$BATS_TEST_TMPDIR/origin.git"
    export HARNESS_WEEKLY_REPO="$BATS_TEST_TMPDIR/repo"
    git init -q --bare "$ORIGIN"
    git clone -q "$ORIGIN" "$HARNESS_WEEKLY_REPO" 2>/dev/null
    printf 'line1\nline2\n' >"$HARNESS_WEEKLY_REPO/README.md"
    # Rule Ledger の書き出しが記録を検査する identity leak guard。識別子はこのマシンから引かず、テストの値にする
    mkdir -p "$HARNESS_WEEKLY_REPO/scripts"
    cp "$BATS_TEST_DIRNAME/../scripts/scan-sensitive-info.sh" "$BATS_TEST_DIRNAME/../scripts/sensitive-patterns.txt" \
        "$HARNESS_WEEKLY_REPO/scripts/"
    : >"$HARNESS_WEEKLY_REPO/scripts/sensitive-allowlist.txt"
    export SENSITIVE_WORK_ORG=acmework SENSITIVE_LOCAL_USER='' SENSITIVE_PATTERNS_LOCAL="$BATS_TEST_TMPDIR/no-local-patterns"
    mkdir -p "$HOME/ghq/github.com/$SENSITIVE_WORK_ORG/shop_admin"
    git -C "$HARNESS_WEEKLY_REPO" add README.md scripts
    git -C "$HARNESS_WEEKLY_REPO" commit -qm init
    git -C "$HARNESS_WEEKLY_REPO" push -q origin main
    BRANCH="harness/review-$(date +%Y-%m-%d)"
    WT="$HDIR/review-worktree"

    install_exec "$STUBS/nono" <<'EOF'
#!/usr/bin/env bash
printf 'nono' >>"$ARGV_LOG"
printf ' %s' "$@" >>"$ARGV_LOG"
printf '\n' >>"$ARGV_LOG"
exit 99
EOF
    install_exec "$STUBS/claude" <<'EOF'
#!/usr/bin/env bash
printf 'claude' >>"$ARGV_LOG"
printf ' %s' "$@" >>"$ARGV_LOG"
printf '\n' >>"$ARGV_LOG"
printf 'HARNESS_DISABLE=%s\n' "${HARNESS_DISABLE:-}" >>"$ENV_LOG"
pwd >>"$CWD_LOG"
all_args="$*"
case "$all_args" in
'plugin eval '*) stage=eval ;;
*'--no-session-persistence'*) stage=classify ;;
*'harness-review skill'*) stage=review ;;
*) stage=reflect ;;
esac
printf '%s HARNESS_REVIEW_RUN=%s\n' "$stage" "${HARNESS_REVIEW_RUN-<unset>}" >>"$REVIEW_RUN_LOG"
sid=""
while [[ $# -gt 0 ]]; do
    [[ "$1" == "--session-id" ]] && sid="$2"
    shift
done
if [[ "$all_args" == 'plugin eval '* ]]; then
    # 2 アーム評価。--json の先に STUB_EVAL_FIXTURE(既定 effective)の結果を書く
    printf 'eval\n' >>"$STAGE_LOG"
    json=$(grep -oE -- '--json [^ ]+' <<<"$all_args" | cut -d' ' -f2)
    cp "$EVAL_FIXTURES/${STUB_EVAL_FIXTURE:-effective}.json" "$json"
    exit 0
elif [[ "$all_args" == *'--no-session-persistence'* ]]; then
    # 失敗の分類器。標準入力のプロンプトの項目をすべて STUB_PATTERN に分類する
    printf 'classify\n' >>"$STAGE_LOG"
    answer=$(grep -oE '^\{"id":[0-9]+' | grep -oE '[0-9]+$' |
        jq -R -s -c --arg p "${STUB_PATTERN:-shell-pitfall}" 'split("\n") | map(select(length > 0) | {id: tonumber, pattern: $p})')
    [[ -n "${STUB_CLASSIFY_FAIL:-}" ]] && answer='"not an array"'
    jq -n -c --argjson a "$answer" '{type: "result", is_error: false, result: ($a | tojson), structured_output: {classifications: $a}}'
    exit 0
elif [[ "$all_args" == *'harness-review skill'* ]]; then
    printf 'review\n' >>"$STAGE_LOG"
    body="$HOME/.claude/harness/review-pr-body-$(date +%Y-%m-%d).md"
    # 結果ファイル(落とした変更と deploy-only の修正)。既定は空配列で書く。
    # STUB_RESULT=missing なら書かず、それ以外の値はそのまま書く(壊れた内容の再現)
    result="$HOME/.claude/harness/review-result-$(date +%Y-%m-%d).json"
    case "${STUB_RESULT-default}" in
    default) printf '{"dropped":[],"deploy_only":[]}\n' >"$result" ;;
    missing) ;;
    *) printf '%s\n' "$STUB_RESULT" >"$result" ;;
    esac
    adopt() {
        mkdir -p rules && printf 'a\nb\nc\n' >rules/new.md && printf 'keep\n' >README.md
        git add -A && git commit -qm 'harness: add rule'
    }
    # queue の項目すべての Verdict を Verdict の CLI で記録する(harness-review の Bookkeeping)
    settle_all() { # <kind> [引数]
        local titles title
        titles=$(grep '^## ' "$HOME/.claude/harness/queue.md" | cut -c4-) || return 0
        while IFS= read -r title; do
            bash "$HOME/.claude/scripts/harness-verdict.sh" settle --title "$title" "$@" || exit 1
        done <<<"$titles"
    }
    case "${STUB_REVIEW_MODE:-adopt}" in
    adopt)
        adopt
        printf '## 採用した変更\n\n- 理由: 同じ失敗の再発を防ぐため\n' >"$body"
        settle_all adopted
        # 評価される側が評価の仕組みを書き換える run の再現
        [[ -z "${STUB_TAMPER_EVAL:-}" ]] || printf 'exit 0\n' >>"$HOME/.claude/scripts/harness-eval-cases.sh"
        # Eval Case の依頼(プロンプトが指定したパス)。STUB_EVAL_REQUEST があればそのまま書く
        if [[ -n "${STUB_EVAL_REQUEST:-}" ]]; then
            printf '%s\n' "$STUB_EVAL_REQUEST" >"$(grep -oE '[^ ]*/eval-requests-[0-9-]+\.json' <<<"$all_args" | head -n 1)"
        fi
        ;;
    no_verdict)
        # 陳腐化の修正だけの run(採用の印が無い)の再現
        adopt
        printf 'reason\n' >"$body"
        settle_all rejected 'stub'
        ;;
    adopt_uncommitted)
        # 採用を判定の記録に書いたのに commit しなかった run の再現
        settle_all adopted
        ;;
    body_only)
        printf 'reason\n' >"$body"
        settle_all rejected 'stub'
        ;;
    dirty)
        printf 'x\n' >stray.md
        settle_all rejected 'stub'
        ;;
    none) settle_all rejected 'stub' ;;
    esac
else
    printf 'reflect\n' >>"$STAGE_LOG"
    # 実行中の入口スクリプトを抽出の claude が書き換える run の再現
    [[ -z "${STUB_TAMPER_SELF:-}" ]] || "$STUB_TAMPER_SELF"
fi
[[ -n "${STUB_SKIP_PENDING:-}" ]] ||
    printf '{"session_id":"%s","transcript_path":"/tmp/t","cwd":"/tmp","recorded_epoch":1}\n' "$sid" \
        >>"$HOME/.claude/harness/pending.jsonl"
case "${STUB_CLAUDE_MODE:-success}" in
success) printf '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.1}\n' ;;
is_error) printf '{"type":"result","subtype":"error_max_budget_usd","is_error":true}\n' ;;
denied) printf '{"type":"result","subtype":"success","is_error":false,"permission_denials":[{"tool_name":"Bash"}]}\n' ;;
exit1) exit 1 ;;
error_exit1)
    printf '{"type":"result","subtype":"error_max_budget_usd","is_error":true,"total_cost_usd":4.9}\n'
    exit 1
    ;;
killed)
    # trap も動かない強制終了(SIGKILL)の再現。入口スクリプトの PID はテストが
    # $KILL_PID_FILE に書く(書かれる前に呼ばれうるので少し待つ)
    for _ in $(seq 50); do [[ -s "$KILL_PID_FILE" ]] && break; sleep 0.1; done
    kill -9 "$(cat "$KILL_PID_FILE")"
    exit 137
    ;;
esac
EOF
    install_exec "$STUBS/uuidgen" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${STUB_UUID:-AAAAAAAA-0000-0000-0000-000000000001}"
EOF
    # 停止を知らせる呼び出し(Issue の操作と、放置の判定のための PR の照会)は GH_LOG ではなく
    # ALERT_LOG に記録する(GH_LOG は PR を作る工程の検査に使う)。Issue の本文は ALERT_BODIES に足す。
    # 開いている Issue の一覧は STUB_GH_ISSUES、開いている PR の一覧は STUB_GH_OPEN_PRS、
    # ブランチごとの PR の件数は STUB_GH_BRANCH_PRS で与える
    install_exec "$STUBS/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == issue || "$*" == *createdAt* || "$*" == *'--json number '* ]]; then
    printf '%s\n' "$*" >>"$ALERT_LOG"
    [[ ! -d "$HOME/.claude/harness/weekly.lock" ]] || printf 'lock held during: %s\n' "$*" >>"$ALERT_LOG"
    [[ -z "${STUB_GH_ALERT_FAIL:-}" ]] || exit 1
    case "$1 $2" in
    'issue list') printf '%s\n' "${STUB_GH_ISSUES-[]}" ;;
    'issue create' | 'issue comment')
        while [[ $# -gt 0 ]]; do
            [[ "$1" == "--body" ]] && printf '%s\n---\n' "$2" >>"$ALERT_BODIES"
            shift
        done
        ;;
    'pr list')
        if [[ "$*" == *createdAt* ]]; then
            printf '%s\n' "${STUB_GH_OPEN_PRS-[]}"
        else
            printf '%s\n' "${STUB_GH_BRANCH_PRS-0}"
        fi
        ;;
    esac
    exit 0
fi
printf '%s\n' "$*" >>"$GH_LOG"
if [[ "$1 $2" == "pr list" && "$*" == *'--state open'* ]]; then
    # 開いているループの PR の一覧(Metrics-only PR を作るかの判定)。いつも無し。開いている PR があるときの判定は
    # test/harness-loop-pr.bats が Loop PR の module の interface で検査する
    exit 0
fi
if [[ "$1 $2" == "pr list" ]]; then
    printf '%s\n' "${STUB_GH_PR_LIST-https://github.com/example/dotfiles/pull/41}"
    exit 0
fi
if [[ "$1 $2" == "pr view" && "$*" == *'--json state'* ]]; then
    # Rule Ledger の書き出しが引く PR の状態。STUB_GH_STATE_<番号>(既定 MERGED)
    var="STUB_GH_STATE_$3"
    printf '%s\n' "${!var:-MERGED}"
    exit 0
fi
while [[ $# -gt 0 ]]; do
    [[ "$1" == "--body-file" ]] && cp "$2" "$GH_BODY"
    shift
done
[[ -z "${STUB_GH_FAIL:-}" ]] || exit 1
printf 'https://github.com/example/dotfiles/pull/42\n'
EOF
    install_exec "$STUBS/pnpm" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "$(pwd)" "$*" >>"$PNPM_LOG"
[[ -z "${STUB_PNPM_FAIL:-}" ]]
EOF
    export PATH="$STUBS:$PATH"
    # 失敗の検出器と選別のスクリプトは本物を本来の配置先に置く(週次ジョブが ~/.claude/scripts から呼ぶ)
    mkdir -p "$HOME/.claude/scripts"
    cp "$BATS_TEST_DIRNAME/../dot_claude/scripts/executable_harness-detect-failures.sh" \
        "$HOME/.claude/scripts/harness-detect-failures.sh"
    cp "$BATS_TEST_DIRNAME/../dot_claude/scripts/executable_harness-select-pending.sh" \
        "$HOME/.claude/scripts/harness-select-pending.sh"
    # 分類器・再発率のスクリプトと Failure Pattern の一覧も本物を置く
    cp "$BATS_TEST_DIRNAME/../dot_claude/scripts/executable_harness-classify-failures.sh" \
        "$HOME/.claude/scripts/harness-classify-failures.sh"
    cp "$BATS_TEST_DIRNAME/../dot_claude/scripts/executable_harness-failure-rates.sh" \
        "$HOME/.claude/scripts/harness-failure-rates.sh"
    cp "$BATS_TEST_DIRNAME/../dot_claude/scripts/harness-failure-patterns.json" \
        "$HOME/.claude/scripts/harness-failure-patterns.json"
    # Eval Case の評価のスクリプトと eval 専用 plugin の雛形も本物を置く(claude plugin eval はスタブ)
    cp "$BATS_TEST_DIRNAME/../dot_claude/scripts/executable_harness-eval-cases.sh" \
        "$HOME/.claude/scripts/harness-eval-cases.sh"
    mkdir -p "$HOME/.claude/scripts/harness-eval-plugin/.claude-plugin" "$HOME/.claude/scripts/harness-eval-plugin/hooks"
    cp "$BATS_TEST_DIRNAME/../dot_claude/scripts/harness-eval-plugin/dot_claude-plugin/plugin.json" \
        "$HOME/.claude/scripts/harness-eval-plugin/.claude-plugin/plugin.json"
    cp "$BATS_TEST_DIRNAME/../dot_claude/scripts/harness-eval-plugin/hooks/hooks.json" \
        "$HOME/.claude/scripts/harness-eval-plugin/hooks/hooks.json"
    # Rule Ledger のスクリプトと、それが判定の記録を読む Verdict の CLI も本物を置く
    cp "$BATS_TEST_DIRNAME/../dot_claude/scripts/executable_harness-rule-ledger.sh" \
        "$HOME/.claude/scripts/harness-rule-ledger.sh"
    cp "$BATS_TEST_DIRNAME/../dot_claude/scripts/executable_harness-verdict.sh" \
        "$HOME/.claude/scripts/harness-verdict.sh"
    LEDGER="$HDIR/rule-ledger"
    LEDGER_REPO_DIR=docs/harness/rule-ledger
    export EVAL_FIXTURES="$BATS_TEST_DIRNAME/fixtures/harness-eval-cases"
    export HARNESS_EVAL_WORK_DIR="$BATS_TEST_TMPDIR/eval-work"
    RATES="$HDIR/failure-pattern-rates"
    RATES_REPO_DIR=docs/harness/failure-pattern-rates
    TODAY=$(date +%Y-%m-%d)
    # pending が空の週は claude を起動しないので、既定では処理対象を 1 件置く。transcript が無いので
    # 選別は検出器にかけずに残す
    printf '{"session_id":"seed","transcript_path":"/tmp/s","cwd":"/tmp","recorded_epoch":1}\n' >"$HDIR/pending.jsonl"
    # heartbeat を確かめるのに使う(assert_heartbeat_written・refute_heartbeat_written と、test の本体での lib の読み取り)
    TEST_START=$(date +%s)
    # shellcheck source=../dot_claude/scripts/lib/harness-health.bash
    source "$BATS_TEST_DIRNAME/../dot_claude/scripts/lib/harness-health.bash"
}

teardown() {
    [[ -z "${LOCKED_DIR:-}" ]] || chmod 755 "$LOCKED_DIR"
}

weekly() {
    bash "$SCRIPT"
}

seed_queue() {
    printf '# Harness improvement queue\n\n## [2026-10-03] entry\n\n- **Scope:** global\n' >"$HDIR/queue.md"
}

# heartbeat の中身は健全性の lib が持つので、書いたかどうかは lib の読み取りで確かめる。
# 「書いた」は test の開始以後の時刻であること。seed_heartbeat で置く前の run の値は、開始より前の時刻にする
# (開始と同じ秒の値は、書いたものと見分けられない)
assert_heartbeat_written() {
    local epoch
    epoch=$(harness_health_heartbeat_epoch) || fail 'heartbeat is missing or not a number'
    assert [ "$epoch" -ge "$TEST_START" ]
}

# 「書いていない」は、heartbeat が無いか、開始より前の時刻のままであること。lib が読めない heartbeat は
# 書き損じとして落とす
refute_heartbeat_written() {
    local epoch
    [[ -e "$(harness_health_heartbeat_file)" ]] || return 0
    epoch=$(harness_health_heartbeat_epoch) || fail 'heartbeat exists but is not a number'
    assert [ "$epoch" -lt "$TEST_START" ]
}

# 前の run が残した heartbeat を置く。lib の書き込みは今の時刻しか書けないので、過去の値は
# ここで直接書く
seed_heartbeat() { # <中身>
    printf '%s\n' "$1" >"$(harness_health_heartbeat_file)"
}

@test "claude -p を予算と sandbox 無効の設定付きで直接起動し、nono は自分で掛けない" {
    run weekly
    assert_success
    run cat "$ARGV_LOG"
    assert_line --index 0 --regexp '^claude -p '
    refute_output --partial 'nono'
    assert_output --partial 'claude -p '
    assert_output --partial '--max-budget-usd '
    assert_output --partial '--settings {"sandbox":{"enabled":false}}'
    assert_output --partial '--dangerously-skip-permissions'
    assert_output --partial '--output-format json'
}

@test "成功すると heartbeat に現在時刻を書く" {
    run weekly
    assert_success
    assert_heartbeat_written
}

@test "claude が非 0 で終わると失敗し、heartbeat を書き換えない" {
    seed_heartbeat 100
    STUB_CLAUDE_MODE=exit1 run weekly
    assert_failure
    assert_equal "$(harness_health_heartbeat_epoch)" 100
}

@test "結果が is_error なら exit 0 でも失敗とし、heartbeat を書かない" {
    STUB_CLAUDE_MODE=is_error run weekly
    assert_failure
    refute_output --partial 'could not be trusted'
    refute_heartbeat_written
}

@test "ジョブ自身のセッションは pending に残らず、他のセッションは残る" {
    printf '{"session_id":"other","transcript_path":"/tmp/o","cwd":"/tmp","recorded_epoch":1}\n' >"$HDIR/pending.jsonl"
    run weekly
    assert_success
    run cat "$HDIR/pending.jsonl"
    assert_output --partial '"session_id":"other"'
    refute_output --partial 'aaaaaaaa-0000-0000-0000-000000000001'
}

@test "SessionEnd hook が自分のセッションを積まないよう HARNESS_DISABLE を渡す" {
    run weekly
    assert_success
    run cat "$ENV_LOG"
    assert_output 'HARNESS_DISABLE=1'
}

@test "前回の実行が積み残した自分のセッションも、次の実行で claude に渡る前に外す" {
    # 前回: SessionEnd が pending に積んだ後、後片付けの前に強制終了された
    export KILL_PID_FILE="$BATS_TEST_TMPDIR/weekly.pid"
    STUB_CLAUDE_MODE=killed bash "$SCRIPT" >/dev/null 2>&1 &
    printf '%s\n' "$!" >"$KILL_PID_FILE"
    wait "$!" || true
    run grep -c 'aaaaaaaa-0000-0000-0000-000000000001' "$HDIR/pending.jsonl"
    assert_output '1'
    # 今回: 別の id で動く。claude のスタブが呼ばれた時点の pending を見る
    cat >"$STUBS/claude-pre" <<'PRE'
cp "$HOME/.claude/harness/pending.jsonl" "$BATS_TEST_TMPDIR/pending-at-launch"
PRE
    sed -i.bak '2r '"$STUBS/claude-pre" "$STUBS/claude"
    STUB_UUID=BBBBBBBB-0000-0000-0000-000000000002 run weekly
    assert_success
    run cat "$BATS_TEST_TMPDIR/pending-at-launch"
    refute_output --partial 'aaaaaaaa-0000-0000-0000-000000000001'
}

@test "nono の外で実行されたら claude を起動せずに失敗する" {
    unset INSIDE_NONO_SANDBOX
    run weekly
    assert_failure
    assert_output --partial 'not inside nono'
    assert_output --partial 'launchctl kickstart'
    assert [ ! -f "$ARGV_LOG" ]
    refute_heartbeat_written
    assert [ ! -d "$HDIR/weekly.lock" ]
}

@test "launchd は nono の内側で入口スクリプトを起動する" {
    # 境界の外で無人実行されるものを、内側から書けない nono の実体と plist に限る契約
    plist="$BATS_TEST_DIRNAME/../private_Library/LaunchAgents/local.dotfiles.harness-weekly.plist.tmpl"
    run tr -d ' \n' <"$plist"
    refute_output --partial '<string>--allow-cwd</string>'
    assert_output --partial '<key>ProgramArguments</key><array><string>{{lookPath"nono"|default"/opt/homebrew/bin/nono"}}</string><string>run</string><string>--profile</string><string>claude-seal</string><string>--</string><string>/bin/bash</string><string>{{.chezmoi.homeDir}}/.claude/scripts/harness-weekly.sh</string></array>'
}

@test "別の実行が生きている間は claude を起動せずに終わる" {
    sleep 30 &
    live=$!
    mkdir -p "$HDIR/weekly.lock"
    printf '%s\n' "$live" >"$HDIR/weekly.lock/pid"
    run weekly
    kill "$live"
    assert_success
    assert_output --partial 'already running'
    assert [ ! -f "$ARGV_LOG" ]
    refute_heartbeat_written
}

@test "止まった実行が残した lock は取り戻して実行する" {
    bash -c 'exit 0' &
    dead=$!
    wait "$dead"
    mkdir -p "$HDIR/weekly.lock"
    printf '%s\n' "$dead" >"$HDIR/weekly.lock/pid"
    run weekly
    assert_success
    assert_heartbeat_written
    assert [ ! -d "$HDIR/weekly.lock" ]
}

@test "持ち主の生死を確かめられない(kill -0 が EPERM)lock は生きているとみなす" {
    # nono の内側からは別インスタンスへの kill -0 が EPERM になる。PID 1 への
    # kill -0 は root でなければ EPERM になるので、それで再現する
    [[ "$(id -u)" -ne 0 ]] || skip 'kill -0 1 succeeds as root'
    mkdir -p "$HDIR/weekly.lock"
    printf '1\n' >"$HDIR/weekly.lock/pid"
    run weekly
    assert_success
    assert_output --partial 'already running'
    assert [ ! -f "$ARGV_LOG" ]
}

@test "PID がまだ書かれていない新しい lock は生きているとみなす" {
    mkdir -p "$HDIR/weekly.lock"
    run weekly
    assert_success
    assert_output --partial 'already running'
    assert [ ! -f "$ARGV_LOG" ]
}

@test "1 日より古い lock は持ち主が生きて見えても取り戻して実行する" {
    # PID が無関係のプロセスに再利用されて生存に見え続ける場合
    sleep 30 &
    unrelated=$!
    mkdir -p "$HDIR/weekly.lock"
    printf '%s\n' "$unrelated" >"$HDIR/weekly.lock/pid"
    touch -t 202001010000 "$HDIR/weekly.lock"
    run weekly
    kill "$unrelated"
    assert_success
    refute_output --partial 'already running'
    assert_heartbeat_written
}

@test "外す行が無ければ pending を置き換えない" {
    # HARNESS_DISABLE が効いて SessionEnd がジョブのセッションを積まなかった通常の run。
    # 置き換え(mv)は SessionEnd の追記と競合しうるので、前後 2 回の除去のどちらも
    # 書き換えないことを見る。inode の番号は解放後に再利用されうるので、hard link を
    # 張っておき同じファイルのままかを -ef で比べる
    printf 'old-session\n' >"$HDIR/weekly-sessions.txt"
    ln "$HDIR/pending.jsonl" "$BATS_TEST_TMPDIR/pending-before"
    STUB_SKIP_PENDING=1 run weekly
    assert_success
    assert [ "$HDIR/pending.jsonl" -ef "$BATS_TEST_TMPDIR/pending-before" ]
}

@test "pending が空なら claude を起動せずに heartbeat を書く" {
    : >"$HDIR/pending.jsonl"
    run weekly
    assert_success
    assert_output --partial 'pending is empty'
    assert [ ! -f "$ARGV_LOG" ]
    assert_heartbeat_written
    assert [ ! -d "$HDIR/weekly.lock" ]
}

@test "pending を読めなければ書き換えずに失敗し、claude を起動しない" {
    printf 'old-session\n' >"$HDIR/weekly-sessions.txt"
    chmod 000 "$HDIR/pending.jsonl"
    run weekly
    chmod 644 "$HDIR/pending.jsonl"
    assert_failure
    assert_output --partial 'left it unchanged'
    run cat "$HDIR/pending.jsonl"
    assert_output --partial '"session_id":"seed"'
    assert [ ! -f "$ARGV_LOG" ]
    assert [ ! -d "$HDIR/weekly.lock" ]
}

# 抽出の claude の実行中に、入口スクリプト自身を同じ inode のまま書き換える run(#515)。bash は
# スクリプトを実行しながら読むので、包まない形では書き換えた内容がその run の残りに効く。
# リポジトリのファイルを書き換えないよう、入口スクリプトは隣の lib/ と一緒に複製して起動する。
# append は末尾への追記、overwrite は最後の行の直前に、overwrite_middle は抽出の直後の文(QUEUE_ENTRIES の
# 代入)の直前に 1 行入れた全体での上書き(読み取り位置より後ろに命令が来るように。短い内容での上書きは
# EOF になるだけで検査にならない)。
# 呼ぶ側は queue に項目を置いて選別の経路を通す。queue が空の経路は finish_run の後に exit 0 があり、
# 末尾まで読みに行かないので、包まない形でも書き足した命令が実行されず検査にならない
prepare_self_tamper() { # <append | overwrite | overwrite_middle>
    local dir="$BATS_TEST_TMPDIR/selfmod"
    mkdir -p "$dir/lib"
    cp "$SCRIPT" "$dir/harness-weekly.sh"
    cp "$SCRIPT" "$dir/original.sh"
    cp "$BATS_TEST_DIRNAME"/../dot_claude/scripts/lib/*.bash "$dir/lib/"
    export TAMPER_TARGET="$dir/harness-weekly.sh" TAMPER_ORIGINAL="$dir/original.sh" \
        TAMPER_MARKER="$BATS_TEST_TMPDIR/tampered" TAMPER_MODE="$1"
    export STUB_TAMPER_SELF="$BATS_TEST_TMPDIR/tamper"
    install_exec "$STUB_TAMPER_SELF" <<'EOF'
#!/usr/bin/env bash
line="printf 'tampered\n' >>'$TAMPER_MARKER'"
case "$TAMPER_MODE" in
append) printf '%s\n' "$line" >>"$TAMPER_TARGET" ;;
overwrite) { sed '$d' "$TAMPER_ORIGINAL"; printf '%s\n' "$line"; tail -n 1 "$TAMPER_ORIGINAL"; } >"$TAMPER_TARGET" ;;
overwrite_middle)
    TAMPER_LINE="$line" awk 'index($0, "QUEUE_ENTRIES=$(count_queue)") { print ENVIRON["TAMPER_LINE"] } { print }' \
        "$TAMPER_ORIGINAL" >"$TAMPER_TARGET"
    ;;
esac
EOF
    INODE_BEFORE=$(ls -i "$TAMPER_TARGET" | awk '{print $1}')
}

assert_tamper_not_run() {
    # 書き換えは同じ inode で起き、書き足した命令はファイルに入っている(検査が空振りしていない)
    assert_equal "$(ls -i "$TAMPER_TARGET" | awk '{print $1}')" "$INODE_BEFORE"
    run grep -c tampered "$TAMPER_TARGET"
    assert_output 1
    assert [ ! -e "$TAMPER_MARKER" ]
    # run は元の内容で最後まで動いた
    assert_heartbeat_written
}

@test "抽出の実行中に入口スクリプトの末尾へ追記されても、その run は追記した命令を実行しない" {
    seed_queue
    prepare_self_tamper append
    STUB_REVIEW_MODE=none run bash "$TAMPER_TARGET"
    assert_success
    assert_output --partial 'review committed no changes; no PR created'
    assert_line --regexp '^harness-weekly: end .* exit=0 '
    assert_tamper_not_run
}

@test "抽出の実行中に入口スクリプトが同じ inode で上書きされても、その run は元の内容で最後まで動く" {
    seed_queue
    prepare_self_tamper overwrite
    STUB_REVIEW_MODE=none run bash "$TAMPER_TARGET"
    assert_success
    assert_output --partial 'review committed no changes; no PR created'
    assert_line --regexp '^harness-weekly: end .* exit=0 '
    assert_tamper_not_run
}

@test "抽出の実行中に入口スクリプトの途中へ命令を入れて上書きされても、その run は元の内容で最後まで動く" {
    seed_queue
    prepare_self_tamper overwrite_middle
    STUB_REVIEW_MODE=none run bash "$TAMPER_TARGET"
    assert_success
    assert_output --partial 'review committed no changes; no PR created'
    assert_line --regexp '^harness-weekly: end .* exit=0 '
    assert_tamper_not_run
}

@test "実行が終われば lock を残さない" {
    STUB_CLAUDE_MODE=exit1 run weekly
    assert_failure
    assert [ ! -d "$HDIR/weekly.lock" ]
}

@test "1 回で扱うセッション数の上限をプロンプトに渡し、環境変数で変えられる" {
    HARNESS_WEEKLY_MAX_SESSIONS=7 run weekly
    assert_success
    run cat "$ARGV_LOG"
    assert_output --partial 'at most 7 entries'
}

@test "claude が非 0 で終わっても結果をログに残し、原因を stderr に出す" {
    STUB_CLAUDE_MODE=error_exit1 run weekly
    assert_failure
    assert_output --partial '"total_cost_usd":4.9'
    assert_output --partial 'heartbeat not updated'
}

@test "実行ログに run の開始・終了の時刻と session id、pending の処理前後の件数を出す" {
    printf '{"session_id":"o1","recorded_epoch":1}\n{"session_id":"o2","recorded_epoch":2}\n{"session_id":"o3","recorded_epoch":3}\n' \
        >"$HDIR/pending.jsonl"
    # claude が 2 件を処理して pending から外した状況を再現する
    cat >"$STUBS/claude-pre" <<'PRE'
sed -i.bak '/"o1"/d;/"o2"/d' "$HOME/.claude/harness/pending.jsonl"
PRE
    sed -i.bak '2r '"$STUBS/claude-pre" "$STUBS/claude"
    run weekly
    assert_success
    assert_line --regexp '^harness-weekly: start [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}[+-][0-9]{4} session=aaaaaaaa-0000-0000-0000-000000000001 pending=3$'
    assert_line --regexp '^harness-weekly: end [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}[+-][0-9]{4} session=aaaaaaaa-0000-0000-0000-000000000001 exit=0 pending=3->1$'
}

@test "失敗の run でも終了の行に終了コードと pending の件数を残す" {
    printf '{"session_id":"o1","recorded_epoch":1}\n' >"$HDIR/pending.jsonl"
    STUB_CLAUDE_MODE=error_exit1 run weekly
    assert_failure
    assert_line --regexp '^harness-weekly: start .* pending=1$'
    assert_line --regexp '^harness-weekly: end .* exit=1 pending=1->1$'
}

@test "採用した変更があると、push してから draft PR をちょうど 1 本作る" {
    seed_queue
    run weekly
    assert_success
    run cat "$GH_LOG"
    assert_equal "${#lines[@]}" 1
    assert_output --regexp "^pr create --draft --base main --head ${BRANCH} "
    # PR を作る前にブランチが origin にある(push はスクリプトが行う)
    run git -C "$ORIGIN" log --format=%s "$BRANCH"
    assert_line 'harness: add rule'
    assert_heartbeat_written
}

# 本文の節の中身(純増の表・検出件数の表・節の順序)は test/harness-pr-body.bats が検査する。ここでは選別の前の
# HEAD を base として本文の lib に渡し、選別が書いた本文の後ろに節が付くことだけを見る
@test "PR の本文に、選別が書いた本文と、選別の commit から数えた純増の節が載る" {
    seed_queue
    run weekly
    assert_success
    run cat "$GH_BODY"
    assert_output --partial '理由: 同じ失敗の再発を防ぐため'
    assert_output --partial '## 純増'
    assert_output --partial '合計: +4 / -2(純増 +2 行)'
}

@test "採用した変更が無ければ PR を作らず、その旨をログに残す" {
    seed_queue
    STUB_REVIEW_MODE=none run weekly
    assert_success
    assert_output --partial 'review committed no changes; no PR created'
    assert [ ! -f "$GH_LOG" ]
    assert_heartbeat_written
    assert [ ! -d "$WT" ]
}

@test "queue が空なら選別を起動せず、その旨をログに残す" {
    run weekly
    assert_success
    assert_output --partial 'queue is empty; skipped review'
    run cat "$STAGE_LOG"
    assert_output 'reflect'
    assert [ ! -f "$GH_LOG" ]
}

@test "pending が空でも queue に項目があれば選別を起動する" {
    : >"$HDIR/pending.jsonl"
    seed_queue
    run weekly
    assert_success
    run cat "$STAGE_LOG"
    assert_output 'review'
}

@test "選別は harness-review を origin/main から切ったループのブランチの worktree で、依存を入れてから走らせる" {
    seed_queue
    git -C "$HARNESS_WEEKLY_REPO" commit -q --allow-empty -m 'local only'
    run weekly
    assert_success
    run tail -n 1 "$CWD_LOG"
    assert_output "$WT"
    run cat "$PNPM_LOG"
    assert_output --partial "$WT install --frozen-lockfile"
    # 手元の未 push の commit は PR に入らない
    run git -C "$ORIGIN" log --format=%s "$BRANCH"
    refute_output --partial 'local only'
}

@test "claude に push と PR の作成をさせず、ファイルの書き込みは Write / Edit で行わせる" {
    seed_queue
    run weekly
    assert_success
    run cat "$ARGV_LOG"
    assert_output --partial 'harness-review skill'
    assert_output --partial 'do not push'
    assert_output --partial "${BRANCH}"
    run grep -c 'only with the Write and Edit tools' "$ARGV_LOG"
    assert_output '2'
}

@test "選別の claude にだけ採用の印を HARNESS_REVIEW_RUN で渡し、prompt には印を書かない" {
    seed_queue
    run weekly
    assert_success
    run grep '^review ' "$REVIEW_RUN_LOG"
    assert_output "review HARNESS_REVIEW_RUN=${BRANCH} run aaaaaaaa-0000-0000-0000-000000000001"
    # 抽出の claude には渡さない(このスクリプトの環境に残さない)
    run grep '^reflect ' "$REVIEW_RUN_LOG"
    assert_output 'reflect HARNESS_REVIEW_RUN=<unset>'
    run grep -cF 'adopted (' "$ARGV_LOG"
    assert_output '0'
}

@test "同じ日の前の run が残した採用は今回の PR の URL に置き換えず、heartbeat を書かずに知らせる" {
    printf -- '## [2026-01-01] old\n\n- **Verdict:** adopted (%s)\n' "$BRANCH" >"$HDIR/queue-archive.md"
    seed_queue
    run weekly
    assert_failure
    assert_output --partial "never became a PR"
    assert_output --partial "bash ~/.claude/scripts/harness-verdict.sh publish --run '${BRANCH}' --pr-url <PR URL>"
    run grep -cF "adopted (${BRANCH})" "$HDIR/queue-archive.md"
    assert_output '1'
    run grep -c 'adopted (PR https://github.com/example/dotfiles/pull/42)' "$HDIR/queue-archive.md"
    assert_output '1'
    refute_heartbeat_written
}

@test "選別の claude が commit の後に失敗したら、残った commit のブランチと手で PR を作る手順を出す" {
    : >"$HDIR/pending.jsonl"
    seed_queue
    STUB_CLAUDE_MODE=is_error run weekly
    assert_failure
    assert_output --partial "review failed after 1 commit(s) on local branch ${BRANCH}"
    assert_output --partial "push origin ${BRANCH}"
    assert_output --partial "gh pr create --draft --base main --head ${BRANCH} --body-file $HDIR/review-pr-body-"
    assert [ ! -f "$GH_LOG" ]
}

@test "push に失敗した run の後に同じ日に再実行しても、手で PR を作るための本文と worktree を消さない" {
    seed_queue
    printf '#!/bin/sh\nexit 1\n' >"$ORIGIN/hooks/pre-receive"
    chmod +x "$ORIGIN/hooks/pre-receive"
    run weekly
    assert_failure
    assert_output --partial "push of ${BRANCH} failed"
    assert_output --partial "--body-file $HDIR/review-pr-body-"
    rm -f "$ORIGIN/hooks/pre-receive"
    seed_queue
    run weekly
    assert_failure
    assert_output --partial 'not on origin/main'
    run cat "$HDIR/review-pr-body-$(date +%Y-%m-%d).md"
    assert_output --partial '## 純増'
    run git -C "$WT" log --format=%s
    assert_line 'harness: add rule'
    assert [ ! -e "$WT.new" ]
}

@test "origin/main に無い commit を持つ当日のローカルブランチは作り直さずに失敗する" {
    seed_queue
    git -C "$HARNESS_WEEKLY_REPO" branch "$BRANCH" main
    git -C "$HARNESS_WEEKLY_REPO" worktree add -q "$BATS_TEST_TMPDIR/other" "$BRANCH"
    git -C "$BATS_TEST_TMPDIR/other" commit -q --allow-empty -m 'unpushed'
    git -C "$HARNESS_WEEKLY_REPO" worktree remove "$BATS_TEST_TMPDIR/other"
    run weekly
    assert_failure
    assert_output --partial "local branch ${BRANCH}"
    assert_output --partial 'not on origin/main'
    run git -C "$HARNESS_WEEKLY_REPO" log --format=%s -1 "$BRANCH"
    assert_output 'unpushed'
    run cat "$STAGE_LOG"
    assert_output 'reflect'
}

@test "当日のブランチが別の worktree で checkout されていると、その旨を添えて失敗する" {
    seed_queue
    git -C "$HARNESS_WEEKLY_REPO" worktree add -q -b "$BRANCH" "$BATS_TEST_TMPDIR/other" main
    run weekly
    assert_failure
    assert_output --partial 'checked out in another worktree'
}

@test "commit されていない変更が残っていたら PR を作らずに失敗する" {
    seed_queue
    STUB_REVIEW_MODE=dirty run weekly
    assert_failure
    assert_output --partial 'uncommitted changes'
    assert [ ! -f "$GH_LOG" ]
    refute_heartbeat_written
}

@test "commit が無く落とした変更も無ければ、本文があっても PR を作らずに成功する" {
    seed_queue
    STUB_REVIEW_MODE=body_only run weekly
    assert_success
    assert_output --partial 'review committed no changes; no PR created'
    assert [ ! -f "$GH_LOG" ]
    assert_heartbeat_written
    # 日付付きのファイルが週ごとに溜まらない
    assert [ ! -f "$HDIR/review-pr-body-$(date +%Y-%m-%d).md" ]
    assert [ ! -f "$HDIR/review-result-$(date +%Y-%m-%d).json" ]
}

@test "commit があり deploy-only の修正もあれば、本文に節が入り deploy-only.md にも残る" {
    seed_queue
    STUB_RESULT='{"dropped":[],"deploy_only":["複数行の\n説明"]}' run weekly
    assert_success
    run cat "$GH_BODY"
    assert_output --partial '## deploy-only の修正'
    assert_output --partial '- 複数行の 説明'
    refute_output --partial '## 落とした変更'
    # 本文は公開リポジトリの PR になるので、ローカルアカウント名を含む絶対パスを書かない
    assert_output --partial '~/.claude/harness/deploy-only.md にも記録した'
    refute_output --partial "$HOME"
    run cat "$HDIR/deploy-only.md"
    assert_output --partial '- 複数行の 説明'
}

@test "同じ日の前の run が残した結果ファイルを今回の結果として読まない" {
    printf '{"dropped":[],"deploy_only":[]}\n' >"$HDIR/review-result-$(date +%Y-%m-%d).json"
    seed_queue
    STUB_REVIEW_MODE=none STUB_RESULT=missing run weekly
    assert_failure
    assert_output --partial 'did not write a valid result file'
    refute_heartbeat_written
}

@test "この run の採用の印があり commit もあれば、従来どおり PR を作って成功する" {
    seed_queue
    STUB_REVIEW_MODE=adopt run weekly
    assert_success
    refute_output --partial 'but the review committed nothing'
    run cat "$GH_LOG"
    assert_output --regexp "^pr create --draft --base main --head ${BRANCH} "
    assert_heartbeat_written
}

@test "前の run が残した別の run の採用の印は、この run の commit が無いことの失敗に数えない" {
    seed_queue
    printf -- '## [2026-01-01] old\n\n- **Verdict:** adopted (%s run old)\n' "$BRANCH" >"$HDIR/queue-archive.md"
    STUB_REVIEW_MODE=none run weekly
    # 前の run の印は finish_run が知らせる(この run の Loop PR の module の選別の後の処理は成功する)
    assert_failure
    assert_output --partial 'review committed no changes; no PR created'
    assert_output --partial "never became a PR"
    assert_output --partial "bash ~/.claude/scripts/harness-verdict.sh publish --run '${BRANCH} run old' --pr-url <PR URL>"
    refute_output --partial 'but the review committed nothing'
}

@test "選別の claude が commit と結果ファイルを書いた後に失敗したら、手で作る PR の本文に結果の節を足す" {
    : >"$HDIR/pending.jsonl"
    seed_queue
    STUB_CLAUDE_MODE=is_error STUB_RESULT='{"dropped":["harness: other(prek で失敗)"],"deploy_only":["v を適用する"]}' run weekly
    assert_failure
    assert_output --partial 'review failed after 1 commit(s)'
    run cat "$HDIR/review-pr-body-$(date +%Y-%m-%d).md"
    assert_output --partial '## 落とした変更'
    assert_output --partial '- harness: other(prek で失敗)'
    assert_output --partial '## deploy-only の修正'
    assert_output --partial '- v を適用する'
    assert_output --partial '~/.claude/harness/deploy-only.md にも記録した'
    refute_output --partial "$HOME"
}

@test "push 後に PR の作成が失敗したら、ブランチ名を添えて失敗する" {
    seed_queue
    STUB_GH_FAIL=1 run weekly
    assert_failure
    assert_output --partial "pushed ${BRANCH} but gh pr create failed"
    refute_heartbeat_written
}

# launchd の plist が渡す PATH を、テストの HOME で展開して返す
plist_path() {
    local plist="$BATS_TEST_DIRNAME/../private_Library/LaunchAgents/local.dotfiles.harness-weekly.plist.tmpl"
    awk '/<key>PATH<\/key>/ { getline; print; exit }' "$plist" |
        sed -e 's|.*<string>||' -e 's|</string>.*||' -e "s|{{ .chezmoi.homeDir }}|$HOME|g"
}

@test "launchd の PATH では pnpm を mise の shims から解決して選別まで進む" {
    # pnpm を mise の shims の場所にだけ置く(このマシンでは pnpm・node・prek はそこにしか無い)
    rm "$STUBS/pnpm"
    mkdir -p "$HOME/.local/share/mise/shims"
    cat >"$HOME/.local/share/mise/shims/pnpm" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "$(pwd)" "$*" >>"$PNPM_LOG"
EOF
    chmod +x "$HOME/.local/share/mise/shims/pnpm"
    seed_queue
    PATH="$STUBS:$(plist_path)" run weekly
    assert_success
    assert [ -f "$PNPM_LOG" ]
    run cat "$STAGE_LOG"
    assert_output $'reflect\nreview'
}

@test "pnpm が PATH に無ければ、原因を名指しして選別の前に失敗する" {
    rm "$STUBS/pnpm"
    launchd_path=$(plist_path)
    if PATH="$launchd_path" command -v pnpm >/dev/null 2>&1; then
        skip "pnpm exists on the launchd PATH outside the mise shims on this machine"
    fi
    seed_queue
    PATH="$STUBS:$launchd_path" run weekly
    assert_failure
    assert_output --partial 'pnpm not found on PATH'
    assert_output --partial 'mise/shims'
    run cat "$STAGE_LOG"
    assert_output 'reflect'
    refute_heartbeat_written
}

@test "前の run の採用が PR にならないまま判定の記録に残っていれば、heartbeat を書かずに失敗する" {
    printf -- '## [2026-01-01] old\n\n- **Verdict:** adopted (harness/review-2026-01-01)\n' >"$HDIR/queue-archive.md"
    run weekly
    assert_failure
    assert_output --partial "never became a PR"
    assert_output --partial "bash ~/.claude/scripts/harness-verdict.sh publish --run 'harness/review-2026-01-01' --pr-url <PR URL>"
    refute_heartbeat_written
    # 案内どおりに publish で URL を記録すれば、次の run は heartbeat を書く
    run bash "$HOME/.claude/scripts/harness-verdict.sh" publish --run 'harness/review-2026-01-01' --pr-url https://github.com/example/dotfiles/pull/7
    assert_output '1'
    run weekly
    assert_success
    assert_heartbeat_written
}

@test "手書きの印が ' を含んでも、復旧の案内の publish のコマンドは貼り付けて動く" {
    printf -- "## [2026-01-01] old\n\n- **Verdict:** adopted (Bob's fix)\n" >"$HDIR/queue-archive.md"
    run weekly
    assert_failure
    assert_output --partial "a mark written by hand has no branch to push"
    local command
    command=$(printf '%s\n' "$output" | grep -o "bash ~/.claude/scripts/harness-verdict.sh publish --run '.*' --pr-url <PR URL>")
    command=${command/<PR URL>/https:\/\/github.com\/example\/dotfiles\/pull\/7}
    run eval "$command"
    assert_success
    assert_output '1'
    run grep -c 'adopted (PR https://github.com/example/dotfiles/pull/7)' "$HDIR/queue-archive.md"
    assert_output '1'
}

@test "判定の記録の採用がすべて PR の URL になっていれば heartbeat を書く" {
    printf -- '## [2026-01-01] old\n\n- **Verdict:** adopted (PR https://github.com/example/dotfiles/pull/1)\n' >"$HDIR/queue-archive.md"
    run weekly
    assert_success
    assert_heartbeat_written
}

@test "前の run の採用の残りは、その週の選別と PR の作成を済ませてから知らせる" {
    printf -- '## [2026-01-01] old\n\n- **Verdict:** adopted (harness/review-2026-01-01)\n' >"$HDIR/queue-archive.md"
    seed_queue
    run weekly
    assert_failure
    assert_output --partial 'never became a PR'
    run cat "$GH_LOG"
    assert_output --regexp "^pr create --draft --base main --head ${BRANCH} "
    run grep -c 'adopted (PR https://github.com/example/dotfiles/pull/42)' "$HDIR/queue-archive.md"
    assert_output '1'
    refute_heartbeat_written
}

@test "依存のインストールが失敗したら選別を起動せずに失敗する" {
    seed_queue
    STUB_PNPM_FAIL=1 run weekly
    assert_failure
    assert_output --partial 'pnpm install failed'
    run cat "$STAGE_LOG"
    assert_output 'reflect'
}

@test "止まった実行が残した worktree があっても、次の実行は作り直して PR まで進む" {
    seed_queue
    git -C "$HARNESS_WEEKLY_REPO" worktree add -q --detach "$WT" HEAD
    printf 'leftover\n' >"$WT/leftover.md"
    run weekly
    assert_success
    assert [ -f "$GH_LOG" ]
    run git -C "$ORIGIN" ls-tree -r --name-only "$BRANCH"
    refute_output --partial 'leftover.md'
}

@test "gitdir を stat できない他の linked worktree の登録を消さない(nono の内側の状況)" {
    [[ "$(id -u)" -ne 0 ]] || skip 'root は権限に関係なく stat できるので状況を作れない'
    seed_queue
    LOCKED_DIR="$BATS_TEST_TMPDIR/workspaces"
    mkdir -p "$LOCKED_DIR"
    git -C "$HARNESS_WEEKLY_REPO" worktree add -q --detach "$LOCKED_DIR/other" HEAD
    chmod 000 "$LOCKED_DIR"
    run test -e "$LOCKED_DIR/other/.git"
    assert_failure
    run weekly
    assert_success
    assert [ -f "$GH_LOG" ]
    assert [ -d "$HARNESS_WEEKLY_REPO/.git/worktrees/other" ]
}

@test "worktree の登録だけが残っていても、次の実行は PR まで進む" {
    seed_queue
    git -C "$HARNESS_WEEKLY_REPO" worktree add -q --detach "$WT" HEAD
    rm -rf "$WT"
    run weekly
    assert_success
    assert [ -f "$GH_LOG" ]
}

@test "permission の拒否(headless では hook の ask も拒否)があれば実行ログに警告を出す" {
    STUB_CLAUDE_MODE=denied run weekly
    assert_success
    assert_output --partial 'WARN reflect: 1 permission denial'
}

@test "当日のループのブランチが origin に既にあれば、選別を起動せずにその旨を残す" {
    seed_queue
    git -C "$HARNESS_WEEKLY_REPO" push -q origin "main:refs/heads/${BRANCH}"
    run weekly
    assert_success
    assert_output --partial "${BRANCH} already exists on origin (PR https://github.com/example/dotfiles/pull/41); skipped review"
    run cat "$STAGE_LOG"
    assert_output 'reflect'
    run cat "$GH_LOG"
    refute_output --partial 'pr create'
    assert_heartbeat_written
}

@test "当日のブランチが origin にあっても PR が無ければ、健全に見せずに失敗する" {
    seed_queue
    git -C "$HARNESS_WEEKLY_REPO" push -q origin "main:refs/heads/${BRANCH}"
    STUB_GH_PR_LIST= run weekly
    assert_failure
    assert_output --partial "${BRANCH} exists on origin but has no PR"
    assert_output --partial "--body-file $HDIR/review-pr-body-"
    run cat "$STAGE_LOG"
    assert_output 'reflect'
    refute_heartbeat_written
}

@test "無人の選別に chezmoi apply をさせない" {
    seed_queue
    run weekly
    assert_success
    run cat "$ARGV_LOG"
    assert_output --partial 'Never run chezmoi apply'
}

@test "陳腐化したルールの修正だけでも commit させる(採用 0 件で PR を諦めさせない)" {
    seed_queue
    run weekly
    assert_success
    run cat "$ARGV_LOG"
    assert_output --partial 'If nothing is adopted and nothing is stale'
}

@test "commit フックや lint で落とした変更は queue に残させ、結果ファイルに書かせる" {
    seed_queue
    run weekly
    assert_success
    run cat "$ARGV_LOG"
    assert_output --partial 'leave its entry in queue.md (do not move it to the archive'
    refute_output --partial 'rejected (dropped:'
    assert_output --partial "Always write the result file $HDIR/review-result-$(date +%Y-%m-%d).json"
    assert_output --partial '{"dropped": [...], "deploy_only": [...]}'
    refute_output --partial 'always write the PR body'
}

@test "コマンドの出力を一時ファイルに書いて mv する Bookkeeping は禁じない" {
    seed_queue
    run weekly
    assert_success
    run grep -c 'moving it into place' "$ARGV_LOG"
    assert_output '2'
}

@test "落とした変更と deploy-only の修正は本文に書かせず、本文を書かないことで区別させない" {
    seed_queue
    run weekly
    assert_success
    run cat "$ARGV_LOG"
    assert_output --partial 'Do not write line counts, failure detection counts, failure pattern rates, rule effects, dropped changes or deploy-only fixes in the PR body'
    assert_output --partial "Never change files under ${RATES_REPO_DIR} or ${LEDGER_REPO_DIR}, or the local Rule Ledger in ${LEDGER}; this job commits them"
    refute_output --partial 'final summary instead'
    refute_output --partial 'Report a deploy-only fix in the PR body'
    refute_output --partial 'reads a PR body without commits'
}

# add_session <session_id> <fixture>: 検出器の fixture を transcript として置き、pending に積む
add_session() {
    mkdir -p "$HOME/.claude/projects/-work-repo"
    cp "$BATS_TEST_DIRNAME/fixtures/harness-detect-failures/$2.jsonl" "$HOME/.claude/projects/-work-repo/$1.jsonl"
    printf '{"session_id":"%s","transcript_path":"%s","cwd":"/work/repo","recorded_epoch":1}\n' \
        "$1" "$HOME/.claude/projects/-work-repo/$1.jsonl" >>"$HDIR/pending.jsonl"
}

@test "抽出の前に検出器で選別し、失敗の無いセッションは claude に渡さない" {
    : >"$HDIR/pending.jsonl"
    add_session clean1 clean
    add_session err1 tool-error
    cat >"$STUBS/claude-pre" <<'PRE'
cp "$HOME/.claude/harness/pending.jsonl" "$BATS_TEST_TMPDIR/pending-at-launch"
PRE
    sed -i.bak '2r '"$STUBS/claude-pre" "$STUBS/claude"
    run weekly
    assert_success
    assert_output --partial 'harness-select-pending: scanned=2 selected=1 dropped=1 not_scanned=0 detector_failed=0'
    run jq -r .session_id "$BATS_TEST_TMPDIR/pending-at-launch"
    assert_output err1
    run jq -c '[.session_id, .run, .counts]' "$HDIR/detections.jsonl"
    assert_output "$(printf '%s\n' \
        '["clean1","aaaaaaaa-0000-0000-0000-000000000001",{}]' \
        '["err1","aaaaaaaa-0000-0000-0000-000000000001",{"tool_error":3}]')"
}

@test "失敗のあるセッションが無ければ抽出の claude を起動しない" {
    : >"$HDIR/pending.jsonl"
    add_session clean1 clean
    run weekly
    assert_success
    assert_output --partial 'pending is empty; skipped reflect'
    assert [ ! -f "$ARGV_LOG" ]
    assert_heartbeat_written
}

@test "選別が失敗したら抽出に進まずに失敗する" {
    rm "$HOME/.claude/scripts/harness-detect-failures.sh"
    run weekly
    assert_failure
    assert_output --partial 'selecting pending sessions with'
    assert [ ! -f "$ARGV_LOG" ]
    refute_heartbeat_written
}

# 期間の切り方・読めない行・表の形は test/harness-pr-body.bats が検査する。ここでは、この run の検出器が記録した件数と、
# 前回の heartbeat から決めた期間の始まりが、本文の lib に届くことを見る
@test "PR の本文に、この run の検出器の件数と前回の heartbeat より後の手動の reflect の記録を載せる" {
    : >"$HDIR/pending.jsonl"
    now=$(date +%s)
    seed_heartbeat "$((now - 3600))"
    {
        # 前回の run より前の記録は数えない
        printf '{"session_id":"old","run":"earlier-run","date":"2026-01-01","epoch":%s,"counts":{"tool_error":9}}\n' "$((now - 7200))"
        # 週の途中で手動の reflect が先に選別したセッションは数える
        printf '{"session_id":"m1","run":"manual","date":"2026-01-01","epoch":%s,"counts":{"user_negation":2}}\n' "$((now - 60))"
    } >"$HDIR/detections.jsonl"
    add_session clean1 clean
    add_session err1 tool-error
    add_session ci1 ci-failure
    seed_queue
    run weekly
    assert_success
    run cat "$GH_BODY"
    assert_output --partial '以降に検出器にかけたセッション: 4 件(失敗あり 3 件)。'
    assert_line '| `tool_error` | 3 |'
    assert_line '| `ci_failure` | 2 |'
    assert_line '| `user_negation` | 2 |'
    assert_line '| 合計 | 7 |'
}

@test "heartbeat が無ければ直近 7 日の記録を数える" {
    : >"$HDIR/pending.jsonl"
    now=$(date +%s)
    {
        printf '{"session_id":"old","run":"manual","date":"2026-01-01","epoch":%s,"counts":{"tool_error":9}}\n' "$((now - 8 * 86400))"
        printf '{"session_id":"m1","run":"manual","date":"2026-01-01","epoch":%s,"counts":{"repeat":1}}\n' "$((now - 86400))"
    } >"$HDIR/detections.jsonl"
    seed_queue
    run weekly
    assert_success
    run cat "$GH_BODY"
    assert_line '| `repeat` | 1 |'
    assert_line '| `tool_error` | 0 |'
    assert_line '| 合計 | 1 |'
}

@test "先頭 0 付きの heartbeat も 10 進数の epoch として期間の始まりに使う" {
    : >"$HDIR/pending.jsonl"
    now=$(date +%s)
    seed_heartbeat "0$((now - 3600))"
    {
        printf '{"session_id":"old","run":"manual","date":"2026-01-01","epoch":%s,"counts":{"tool_error":9}}\n' "$((now - 7200))"
        printf '{"session_id":"m1","run":"manual","date":"2026-01-01","epoch":%s,"counts":{"repeat":1}}\n' "$((now - 60))"
    } >"$HDIR/detections.jsonl"
    seed_queue
    run weekly
    assert_success
    refute_output --partial 'failed to build the detection counts'
    run cat "$GH_BODY"
    assert_line '| `repeat` | 1 |'
    assert_line '| `tool_error` | 0 |'
    assert_line '| 合計 | 1 |'
}

@test "検出件数の記録を読めなければ、照合できないとして claude を起動せずに失敗し、PR を作らない" {
    : >"$HDIR/pending.jsonl"
    seed_queue
    # 検出件数の記録は PR の本文の材料なので Integrity Snapshot のデータに入る。読めなければスナップショットを取れない
    printf '{}\n' >"$HDIR/detections.jsonl"
    chmod 000 "$HDIR/detections.jsonl"
    run weekly
    chmod 644 "$HDIR/detections.jsonl"
    assert_failure
    assert_output --partial "could not hash $HDIR/detections.jsonl"
    assert_output --partial 'failed to take the integrity snapshot'
    assert [ ! -f "$ARGV_LOG" ]
    assert [ ! -f "$GH_LOG" ]
    refute_heartbeat_written
}

@test "選別の claude が commit の後に失敗したら、手で作る PR の本文に検出の節を足す" {
    : >"$HDIR/pending.jsonl"
    add_session err1 tool-error
    seed_queue
    # 抽出は成功させ、選別だけを失敗させる
    cat >"$STUBS/claude-pre" <<'PRE'
[[ "$*" == *'harness-review skill'* ]] && export STUB_CLAUDE_MODE=is_error
PRE
    sed -i.bak '2r '"$STUBS/claude-pre" "$STUBS/claude"
    run weekly
    assert_failure
    assert_output --partial 'review failed after 1 commit(s)'
    run cat "$HDIR/review-pr-body-$(date +%Y-%m-%d).md"
    assert_output --partial '## 失敗の検出'
    assert_line '| `tool_error` | 3 |'
}

# 停止を GitHub Issue で知らせる(#402、ADR 0012 の Consequences)。Issue のタイトルが重複を避ける
# 鍵で、同じタイトルの Issue が開いていればコメントにする

FAILED_TITLE='harness: 週次ジョブが失敗した'

@test "ジョブが失敗したら Issue を作り、本文にログの場所と再実行の手順を載せる" {
    STUB_CLAUDE_MODE=exit1 run weekly
    assert_failure
    run cat "$ALERT_LOG"
    assert_line --partial "issue create --label harness-analysis --title ${FAILED_TITLE} --body "
    refute_line --partial 'issue comment'
    run cat "$ALERT_BODIES"
    assert_output --partial 'session=aaaaaaaa-0000-0000-0000-000000000001'
    assert_output --partial '~/Library/Logs/harness-weekly.log'
    assert_output --partial 'launchctl kickstart gui/$(id -u)/local.dotfiles.harness-weekly'
    refute_output --partial "$HOME"
}

@test "成功した run は失敗の Issue を作らない" {
    run weekly
    assert_success
    run cat "$ALERT_LOG"
    refute_line --partial "${FAILED_TITLE}"
    refute_line --partial 'issue create'
    refute_line --partial 'issue comment'
}

@test "同じ失敗の Issue が開いていれば、新しく作らずにコメントする" {
    export STUB_GH_ISSUES='[{"number":7,"title":"harness: 週次ジョブが失敗した","updatedAt":"2026-01-01T00:00:00Z"},{"number":8,"title":"other","updatedAt":"2026-01-01T00:00:00Z"}]'
    STUB_CLAUDE_MODE=exit1 run weekly
    assert_failure
    run cat "$ALERT_LOG"
    assert_line --partial 'issue list --label harness-analysis --state open '
    assert_line --regexp '^issue comment 7 '
    refute_line --partial 'issue create'
}

@test "停止を知らせる gh の呼び出しは lock を解放してから行う(gh が固まっても lock を握ったままにしない)" {
    STUB_CLAUDE_MODE=exit1 run weekly
    assert_failure
    run cat "$ALERT_LOG"
    assert_line --partial 'issue create'
    refute_line --partial 'lock held during:'
}

@test "Issue へのコメントは再発とは書かず、この run でも検出したと書く" {
    export STUB_GH_ISSUES='[{"number":7,"title":"harness: 週次ジョブが失敗した","updatedAt":"2026-01-01T00:00:00Z"}]'
    STUB_CLAUDE_MODE=exit1 run weekly
    assert_failure
    run cat "$ALERT_BODIES"
    assert_output --partial 'この run でも検出した。'
    refute_output --partial '再発した。'
}

@test "Issue を作れなくても、ジョブの終了コードと後片付けは変わらない" {
    STUB_GH_ALERT_FAIL=1 STUB_CLAUDE_MODE=exit1 run weekly
    assert_failure
    assert_output --partial 'WARN could not report'
    assert_output --regexp 'harness-weekly: end .* exit=1 '
    assert [ ! -d "$HDIR/weekly.lock" ]
    STUB_GH_ALERT_FAIL=1 run weekly
    assert_success
}

iso_days_ago() {
    jq -rn --argjson e "$(($(date +%s) - $1 * 86400))" '$e | todate'
}

@test "ループの PR が 14 日以上放置されていれば、PR ごとの Issue を作り本文に対処を載せる" {
    STUB_GH_OPEN_PRS=$(jq -n --arg old "$(iso_days_ago 15)" --arg fresh "$(iso_days_ago 13)" '[
        {number: 51, url: "https://github.com/example/dotfiles/pull/51", headRefName: "harness/review-2026-09-01", createdAt: $old},
        {number: 52, url: "https://github.com/example/dotfiles/pull/52", headRefName: "harness/review-2026-09-15", createdAt: $fresh},
        {number: 53, url: "https://github.com/example/dotfiles/pull/53", headRefName: "feature/x", createdAt: $old}
    ]')
    export STUB_GH_OPEN_PRS
    run weekly
    assert_success
    run cat "$ALERT_LOG"
    assert_line --partial 'issue create --label harness-analysis --title harness: ループの PR #51 が 14 日以上放置されている'
    refute_line --partial '#52'
    refute_line --partial '#53'
    run cat "$ALERT_BODIES"
    assert_output --partial 'https://github.com/example/dotfiles/pull/51'
    assert_output --partial '15 日'
    assert_output --partial 'gh pr ready 51'
    assert_output --partial 'gh pr close 51'
}

@test "放置の Issue が開いていれば、次の週はコメントにする" {
    STUB_GH_OPEN_PRS=$(jq -n --arg old "$(iso_days_ago 22)" '[
        {number: 51, url: "https://github.com/example/dotfiles/pull/51", headRefName: "harness/review-2026-09-01", createdAt: $old}
    ]')
    export STUB_GH_OPEN_PRS
    export STUB_GH_ISSUES='[{"number":9,"title":"harness: ループの PR #51 が 14 日以上放置されている","updatedAt":"2026-01-01T00:00:00Z"}]'
    run weekly
    assert_success
    run cat "$ALERT_LOG"
    assert_line --regexp '^issue comment 9 '
    refute_line --partial 'issue create'
}

# 前の週の run が PR にならないまま残した、origin/main に無い commit を持つループのブランチ
leftover_branch() { # <ブランチ>
    git -C "$HARNESS_WEEKLY_REPO" switch -q -c "$1"
    printf 'x\n' >"$HARNESS_WEEKLY_REPO/stale.md"
    git -C "$HARNESS_WEEKLY_REPO" add stale.md
    git -C "$HARNESS_WEEKLY_REPO" commit -qm 'harness: fix stale rule'
    git -C "$HARNESS_WEEKLY_REPO" switch -q main
}

@test "PR にならないまま origin/main に無い commit を持つ、7 日以上前のループのブランチがあれば Issue を作る" {
    # 本文のパスを ~ で書くことを確かめるため、リポジトリを HOME の下に置く(既定の置き場所と同じ形)
    mv "$HARNESS_WEEKLY_REPO" "$HOME/repo"
    export HARNESS_WEEKLY_REPO="$HOME/repo"
    leftover_branch harness/review-2026-09-01
    run weekly
    assert_success
    run cat "$ALERT_LOG"
    assert_line --partial 'pr list --head harness/review-2026-09-01 --state all --json number '
    assert_line --partial 'issue create --label harness-analysis --title harness: ループのブランチ harness/review-2026-09-01 が PR になっていない'
    run cat "$ALERT_BODIES"
    assert_output --partial 'origin/main に無い commit: 1 件'
    assert_output --partial 'git -C ~/repo push origin harness/review-2026-09-01'
    assert_output --partial 'push origin harness/review-2026-09-01'
    assert_output --partial 'gh pr create --draft --base main --head harness/review-2026-09-01'
    assert_output --partial 'branch -D harness/review-2026-09-01'
    refute_output --partial "$HOME"
}

@test "ループのブランチに PR があれば(手動の review や squash マージ)、Issue を作らない" {
    leftover_branch harness/review-2026-09-01
    STUB_GH_BRANCH_PRS=1 run weekly
    assert_success
    assert_output --partial 'harness/review-2026-09-01 already has a PR; delete it with git -C '
    run cat "$ALERT_LOG"
    assert_line --partial 'pr list --head harness/review-2026-09-01 '
    refute_line --partial 'issue create'
}

@test "採用の記録が残るループのブランチは、失敗の Issue が知らせるのでブランチの Issue にしない" {
    leftover_branch harness/review-2026-09-01
    printf -- '## [2026-01-01] old\n\n- **Verdict:** adopted (harness/review-2026-09-01 run old)\n' >"$HDIR/queue-archive.md"
    run weekly
    assert_failure
    assert_output --partial 'harness/review-2026-09-01 has an adopted verdict'
    run cat "$ALERT_LOG"
    assert_line --partial "issue create --label harness-analysis --title ${FAILED_TITLE} --body "
    refute_line --partial 'pr list --head harness/review-2026-09-01'
    refute_line --partial 'ループのブランチ'
}

@test "origin/main に無い commit を持たないループのブランチは、PR を照会せず Issue も作らない" {
    git -C "$HARNESS_WEEKLY_REPO" branch harness/review-2026-09-01 main
    git -C "$HARNESS_WEEKLY_REPO" fetch -q origin
    run weekly
    assert_success
    run cat "$ALERT_LOG"
    refute_line --partial 'pr list --head harness/review-2026-09-01'
    refute_line --partial 'issue create'
}

@test "前の成功が 8 日以上前なら、起動した run が成功しても、走らなかった週の Issue を作る" {
    seed_heartbeat "$(($(date +%s) - 9 * 86400))"
    run weekly
    assert_success
    run cat "$ALERT_LOG"
    assert_line --partial 'issue create --label harness-analysis --title harness: 週次ジョブが 8 日以上成功していなかった'
    run cat "$ALERT_BODIES"
    assert_output --partial '9 日前'
    assert_output --partial 'launchctl print gui/$(id -u)/local.dotfiles.harness-weekly'
    refute_output --partial "$HOME"
}

@test "前の成功より後に更新された失敗の Issue が開いていれば、前の成功が古くても別の Issue にしない" {
    seed_heartbeat "$(($(date +%s) - 9 * 86400))"
    STUB_GH_ISSUES=$(jq -nc --arg updated "$(iso_days_ago 2)" '[{number: 7, title: "harness: 週次ジョブが失敗した", updatedAt: $updated}]')
    export STUB_GH_ISSUES
    run weekly
    assert_success
    assert_output --partial 'issue #7 already reports the failures'
    run cat "$ALERT_LOG"
    refute_line --partial 'issue create'
    refute_line --partial 'issue comment'
}

@test "この run が失敗して Issue を作ったら、一覧に出なくても走らなかった週の Issue を作らない" {
    # 作った直後の Issue は一覧に出ないことがある。スタブの一覧は作った Issue を返さない
    seed_heartbeat "$(($(date +%s) - 9 * 86400))"
    STUB_CLAUDE_MODE=exit1 run weekly
    assert_failure
    assert_output --partial 'the failure issue of this run reports it'
    run grep -c 'issue create' "$ALERT_LOG"
    assert_output 1
    run cat "$ALERT_LOG"
    assert_line --partial "issue create --label harness-analysis --title ${FAILED_TITLE} --body "
}

@test "前の成功より前から開いている失敗の Issue は、その後に走らなかった週を抑えない" {
    seed_heartbeat "$(($(date +%s) - 20 * 86400))"
    STUB_GH_ISSUES=$(jq -nc --arg updated "$(iso_days_ago 30)" '[{number: 7, title: "harness: 週次ジョブが失敗した", updatedAt: $updated}]')
    export STUB_GH_ISSUES
    run weekly
    assert_success
    run cat "$ALERT_LOG"
    assert_line --partial 'issue create --label harness-analysis --title harness: 週次ジョブが 8 日以上成功していなかった'
}

@test "走らなかった週の Issue が開いていれば、次に見つけたときはコメントにする" {
    seed_heartbeat "$(($(date +%s) - 9 * 86400))"
    export STUB_GH_ISSUES='[{"number":11,"title":"harness: 週次ジョブが 8 日以上成功していなかった","updatedAt":"2026-01-01T00:00:00Z"}]'
    run weekly
    assert_success
    run cat "$ALERT_LOG"
    assert_line --regexp '^issue comment 11 '
    refute_line --partial 'issue create'
}

@test "この 7 日のうちに切られたループのブランチは、まだ公開前かもしれないので PR を照会しない" {
    leftover_branch "harness/review-$(date +%Y-%m-%d)-x"
    leftover_branch "harness/review-$(jq -rn --argjson e "$(($(date +%s) - 86400))" '$e | localtime | strftime("%Y-%m-%d")')"
    run weekly
    assert_success
    run cat "$ALERT_LOG"
    refute_line --partial 'pr list --head'
    refute_line --partial 'issue create'
}

@test "前の成功が 7 日前なら、走らなかった週の Issue を作らない" {
    seed_heartbeat "$(($(date +%s) - 7 * 86400))"
    run weekly
    assert_success
    run cat "$ALERT_LOG"
    refute_line --partial 'issue create'
}

# 健全性の lib を読めずに止まった run も、失敗の Issue は lib に依らずに作る。
# 入口スクリプトは自分の隣の lib/ を読むので、lib を置かない場所に複製して起動する
weekly_without_lib() { # [<lib に置く中身>]
    local dir="$BATS_TEST_TMPDIR/nolib"
    mkdir -p "$dir"
    cp "$SCRIPT" "$dir/harness-weekly.sh"
    if [[ $# -gt 0 ]]; then
        mkdir -p "$dir/lib"
        printf '%s\n' "$1" >"$dir/lib/harness-health.bash"
    fi
    bash "$dir/harness-weekly.sh"
}

@test "健全性の lib が無くて止まった run も、失敗の Issue を作る" {
    run weekly_without_lib
    assert_failure
    assert_output --partial 'is missing or broken'
    refute_output --partial 'command not found'
    run cat "$ALERT_LOG"
    assert_line --partial "issue create --label harness-analysis --title ${FAILED_TITLE} --body "
}

@test "健全性の lib に heartbeat と停止の判定が無くて止まった run も、失敗の Issue を作る" {
    run weekly_without_lib '# empty'
    assert_failure
    assert_output --partial 'lacks the heartbeat and stop checks'
    refute_output --partial 'command not found'
    run cat "$ALERT_LOG"
    assert_line --partial "issue create --label harness-analysis --title ${FAILED_TITLE} --body "
}

# old_record <date>: 前の週の再発率の記録をローカルに置く
old_record() {
    mkdir -p "$RATES"
    printf '{"date":"%s","since":0,"until":1,"sessions":2,"detections":1,"classified":1,"classification":"ok","patterns":{"shell-pitfall":{"occurrences":1,"sessions":1,"rate":0.5},"unclassified":{"occurrences":0,"sessions":0,"rate":0}}}\n' \
        "$1" >"$RATES/$1.json"
}

# commit_on_main <file>: origin/main に週の記録を commit する(マージ済みの記録の再現)
commit_on_main() {
    mkdir -p "$HARNESS_WEEKLY_REPO/$RATES_REPO_DIR"
    cp "$RATES/$1.json" "$HARNESS_WEEKLY_REPO/$RATES_REPO_DIR/"
    git -C "$HARNESS_WEEKLY_REPO" add -A
    git -C "$HARNESS_WEEKLY_REPO" commit -qm "record $1"
    git -C "$HARNESS_WEEKLY_REPO" push -q origin main
}

@test "検出した失敗を分類し、queue が空の週も再発率を記録する" {
    : >"$HDIR/pending.jsonl"
    add_session err1 tool-error
    STUB_PATTERN=tool-contract run weekly
    assert_success
    run jq -c '{sessions, detections, classified, classification, tc: .patterns["tool-contract"]}' "$RATES/$TODAY.json"
    assert_output '{"sessions":1,"detections":3,"classified":3,"classification":"ok","tc":{"occurrences":3,"sessions":1,"rate":1}}'
    run cat "$STAGE_LOG"
    assert_line --index 0 'classify'
}

@test "分類器のセッションは pending に残さない" {
    : >"$HDIR/pending.jsonl"
    add_session err1 tool-error
    STUB_UUID=CCCCCCCC-0000-0000-0000-000000000003 run weekly
    assert_success
    run cat "$ARGV_LOG"
    assert_output --partial '--session-id cccccccc-0000-0000-0000-000000000003 --max-budget-usd'
    run cat "$HDIR/pending.jsonl"
    refute_output --partial 'cccccccc-0000-0000-0000-000000000003'
}

@test "分類に失敗しても run は成功し、その週を分類の失敗として記録する" {
    : >"$HDIR/pending.jsonl"
    add_session err1 tool-error
    STUB_CLASSIFY_FAIL=1 run weekly
    assert_success
    assert_output --partial 'classifying failures with'
    run jq -r '.classification, .classified' "$RATES/$TODAY.json"
    assert_output "$(printf '%s\n' failed 0)"
    assert_heartbeat_written
}

@test "採用のある PR に、origin/main に無い週の記録をジョブの commit で足し、本文に推移を載せる" {
    seed_queue
    old_record 2026-09-19
    old_record 2026-09-26
    commit_on_main 2026-09-19
    run weekly
    assert_success
    run git -C "$ORIGIN" log --format=%s "main..$BRANCH"
    assert_output "$(printf '%s\n' 'harness: Rule Ledger の記録を足す' 'harness: Failure Pattern の再発率の週の記録を足す' 'harness: add rule')"
    run cat "$GH_BODY"
    assert_line '## Failure Pattern の再発率'
    assert_output --partial "| Failure Pattern | 2026-09-19 | 2026-09-26 | ${TODAY} |"
    # 純増は選別の commit だけで数える
    assert_output --partial '合計: +4 / -2(純増 +2 行)'
    refute_output --partial "$RATES_REPO_DIR"
}

@test "採用 0 件の週に origin/main に無い記録が 4 週分たまったら、Metrics-only PR を作る" {
    old_record 2026-09-12
    old_record 2026-09-19
    old_record 2026-09-26
    run weekly
    assert_success
    assert_output --partial 'opened metrics-only draft PR'
    run grep '^pr create' "$GH_LOG"
    assert_output --regexp "^pr create --draft --base main --head ${BRANCH} --title harness: 週次の指標 "
    run cat "$GH_BODY"
    assert_output --partial '4 週分たまった'
    assert_line '## Failure Pattern の再発率'
    assert_line '## 失敗の検出'
    assert_heartbeat_written
    assert [ ! -d "$WT" ]
}

# 依存を入れるのは週次ジョブで、要否の判定と公開は Loop PR の module(test/harness-loop-pr.bats)。ここでは、要ると決まった
# 後に依存を入れるコマンドを module に渡す配線を見る
@test "採用 0 件の週に Metrics-only PR を作るときは、worktree に依存を入れてから記録を整形する" {
    old_record 2026-09-12
    old_record 2026-09-19
    old_record 2026-09-26
    run weekly
    assert_success
    run cat "$PNPM_LOG"
    assert_output "$(printf '%s\n' "$WT install --frozen-lockfile --prefer-offline" "$WT exec oxfmt $RATES_REPO_DIR")"
}

@test "選別が何も commit しなかった週も、記録がたまっていれば Metrics-only PR を作る" {
    seed_queue
    old_record 2026-09-12
    old_record 2026-09-19
    old_record 2026-09-26
    STUB_REVIEW_MODE=body_only run weekly
    assert_success
    assert_output --partial 'review committed no changes; opening a metrics-only PR'
    run cat "$GH_BODY"
    refute_output --partial 'reason'
    assert_output --partial '4 週分たまった'
}

@test "前の週の記録が読めず期間を決められない週は、週の処理を済ませたうえで失敗し heartbeat を書かない" {
    mkdir -p "$RATES"
    printf 'not json\n' >"$RATES/2026-09-26.json"
    run weekly
    assert_failure
    assert_output --partial 'could not decide the period'
    assert_output --partial 'this week has no failure rate record'
    assert [ ! -f "$RATES/$TODAY.json" ]
    refute_heartbeat_written
    # 抽出の claude は起動している(週の処理は止めない)
    assert [ -f "$ARGV_LOG" ]
}

@test "claude がローカルの週の記録を書き換えたら、記録を commit せず PR も作らずに失敗する" {
    seed_queue
    old_record 2026-09-26
    cat >"$STUBS/claude-pre" <<'PRE'
if [[ "$*" == *'harness-review skill'* ]]; then
    printf '{"date":"2026-09-26","since":0,"until":1,"classification":"ok","patterns":{}}\n' \
        >"$HOME/.claude/harness/failure-pattern-rates/2026-09-26.json"
fi
PRE
    sed -i.bak '2r '"$STUBS/claude-pre" "$STUBS/claude"
    run weekly
    assert_failure
    assert_output --partial 'changed after the claude runs started'
    run cat "$GH_LOG"
    refute_output --partial 'pr create'
    refute_heartbeat_written
}

@test "採用したルールの Eval Case を評価し、with / without と Δ を PR の本文に載せる" {
    seed_queue
    sid=11111111-1111-4111-8111-111111111111
    mkdir -p "$HOME/.claude/projects/-work-repo"
    cp "$BATS_TEST_DIRNAME/fixtures/harness-detect-failures/negation.jsonl" "$HOME/.claude/projects/-work-repo/$sid.jsonl"
    export STUB_EVAL_REQUEST="{\"cases\":[{\"title\":\"[2026-10-03] entry\",\"rule\":\"r\",\"source_session\":\"$sid\",\"prompt\":\"p\",\"graders\":[{\"name\":\"g\",\"type\":\"regex\",\"pattern\":\"x\"}]}]}"
    run weekly
    assert_success
    run grep -c '^eval$' "$STAGE_LOG"
    assert_output 1
    run grep '^claude plugin eval' "$ARGV_LOG"
    assert_output --partial '--no-publish'
    id="$TODAY-$(printf '%s' '[2026-10-03] entry' | shasum -a 256 | cut -c1-8)"
    cmp "$HDIR/evals/$id/source.jsonl" "$HOME/.claude/projects/-work-repo/$sid.jsonl"
    run cat "$GH_BODY"
    assert_line '## ルールの効果'
    assert_line "| [2026-10-03] entry | \`$id\` | 1 | 0 | +1 | 有効 |"
    refute_output --partial '評価も免除の理由も無い採用'
}

@test "選別が Eval Case の依頼を書かなかった採用は、評価も免除の理由も無いとして本文に名前が出る" {
    seed_queue
    run weekly
    assert_success
    refute grep -q '^eval$' "$STAGE_LOG"
    run cat "$GH_BODY"
    assert_line '### 評価も免除の理由も無い採用'
    assert_line '- [2026-10-03] entry'
}

@test "評価の工程が失敗しても PR は作り、本文に効果を測っていないことを書く" {
    seed_queue
    rm "$HOME/.claude/scripts/harness-eval-plugin/hooks/hooks.json"
    export STUB_EVAL_REQUEST='{"cases":[]}'
    run weekly
    assert_success
    assert_output --partial 'WARN evaluating the eval cases'
    run cat "$GH_BODY"
    assert_output --partial '評価の工程が失敗したため、この PR のルールの効果は測っていない'
}

@test "選別の claude が評価のスクリプトを書き換えた run は、評価も PR の作成もせずに失敗する" {
    seed_queue
    export STUB_EVAL_REQUEST='{"cases":[]}'
    export STUB_TAMPER_EVAL=1
    run weekly
    assert_failure
    assert_output --partial 'changed after the claude runs started'
    assert_output --partial "changed: $HOME/.claude/scripts/harness-eval-cases.sh"
    assert [ ! -e "$HDIR/eval-results-$TODAY.json" ]
    refute grep -q 'pr create' "$GH_LOG"
    refute_heartbeat_written
}

# ledger_record <PR 番号> <title>: 前の週か手動の review が残したローカルの Rule Ledger の記録を置き、パスを出す
ledger_record() {
    local id="pr$1-$(printf '%s' "$2" | shasum -a 256 | cut -c1-8)"
    mkdir -p "$LEDGER"
    jq -n --arg id "$id" --arg title "$2" --argjson pr "$1" \
        '{id: $id, adopted: "2026-09-26", title: $title, failure_patterns: [], eval: {status: "missing", reason: "no_request"}, pr: $pr, via: "manual"}' \
        >"$LEDGER/$id.json"
    printf '%s\n' "$LEDGER/$id.json"
}

@test "採用のある PR に、採用ごとの Rule Ledger の記録をジョブの commit で足し、Eval Case の id が実体と対応する" {
    seed_queue
    sid=11111111-1111-4111-8111-111111111111
    mkdir -p "$HOME/.claude/projects/-work-repo"
    cp "$BATS_TEST_DIRNAME/fixtures/harness-detect-failures/negation.jsonl" "$HOME/.claude/projects/-work-repo/$sid.jsonl"
    export STUB_EVAL_REQUEST="{\"cases\":[{\"title\":\"[2026-10-03] entry\",\"rule\":\"r\",\"source_session\":\"$sid\",\"prompt\":\"p\",\"graders\":[{\"name\":\"g\",\"type\":\"regex\",\"pattern\":\"x\"}]}]}"
    carried=$(ledger_record 30 '[2026-09-20] carried over')
    # マージされずに閉じた PR の記録は採用ではないので載せない
    closed=$(ledger_record 31 '[2026-09-20] closed without a merge')
    export STUB_GH_STATE_31=CLOSED
    run weekly
    assert_success
    assert_output --partial 'committed 2 Rule Ledger record(s)'
    assert [ -f "$closed" ]
    run git -C "$ORIGIN" log --format=%s "main..$BRANCH"
    assert_line --index 0 'harness: Rule Ledger の記録を足す'
    id="pr42-$(printf '%s' '[2026-10-03] entry' | shasum -a 256 | cut -c1-8)"
    run git -C "$ORIGIN" diff --name-only "main..$BRANCH" -- "$LEDGER_REPO_DIR"
    assert_output "$(printf '%s\n' "$LEDGER_REPO_DIR/$id.json" "$LEDGER_REPO_DIR/${carried##*/}" | sort)"
    run git -C "$ORIGIN" show "$BRANCH:$LEDGER_REPO_DIR/$id.json"
    case_id=$(jq -r '.eval.case_id' <<<"$output")
    assert_equal "$(jq -c '{adopted, pr, via, eval: .eval.status, delta: .eval.delta}' <<<"$output")" \
        "{\"adopted\":\"$TODAY\",\"pr\":42,\"via\":\"weekly\",\"eval\":\"evaluated\",\"delta\":1}"
    assert [ -f "$HDIR/evals/$case_id/request.json" ]
    run cat "$PNPM_LOG"
    assert_output --partial "$WT exec oxfmt $LEDGER_REPO_DIR"
    # 純増は選別の commit だけで数える
    run cat "$GH_BODY"
    assert_line '## Rule Ledger'
    assert_output --partial '合計: +4 / -2(純増 +2 行)'
    assert_heartbeat_written
}

@test "claude がローカルの Rule Ledger か分類の記録を書き換えたら、PR を作らずに失敗する" {
    seed_queue
    carried=$(ledger_record 30 '[2026-09-20] carried over')
    cat >"$STUBS/claude-pre" <<PRE
if [[ "\$*" == *'harness-review skill'* ]]; then
    jq '.eval = {status: "evaluated", case_id: "2026-09-26-00000000", with: 1, without: 0, delta: 1}' "$carried" >"$carried.tmp"
    mv "$carried.tmp" "$carried"
fi
PRE
    sed -i.bak '2r '"$STUBS/claude-pre" "$STUBS/claude"
    run weekly
    assert_failure
    assert_output --partial "changed: $carried"
    assert [ ! -f "$GH_LOG" ]
    refute_heartbeat_written
}

@test "選別の claude が置いた偽の評価の結果は Rule Ledger に記録せず、測っていないと記録する" {
    seed_queue
    # 形の違う依頼で評価の工程を失敗させ、得点を偽った結果のファイルを置く
    export STUB_EVAL_REQUEST='{}'
    cat >"$STUBS/claude-pre" <<PRE
if [[ "\$*" == *'harness-review skill'* ]]; then
    printf '%s\n' '{"date":"$TODAY","cases":[{"title":"[2026-10-03] entry","id":"$TODAY-00000000","status":"evaluated","with":1,"without":0,"delta":1}],"exempt":[],"over_cap":[],"cost_usd":0}' >"$HDIR/eval-results-$TODAY.json"
fi
PRE
    sed -i.bak '2r '"$STUBS/claude-pre" "$STUBS/claude"
    run weekly
    assert_success
    assert_output --partial 'WARN evaluating the eval cases'
    id="pr42-$(printf '%s' '[2026-10-03] entry' | shasum -a 256 | cut -c1-8)"
    run jq -c .eval "$LEDGER/$id.json"
    assert_output '{"status":"missing","reason":"not_measured"}'
    run git -C "$ORIGIN" show "$BRANCH:$LEDGER_REPO_DIR/$id.json"
    assert_output --partial 'not_measured'
}

@test "選別の claude が Rule Ledger のスクリプトを書き換えたら、PR を作らずに失敗する" {
    seed_queue
    cat >"$STUBS/claude-pre" <<PRE
if [[ "\$*" == *'harness-review skill'* ]]; then
    printf '# tampered\n' >>"$HOME/.claude/scripts/harness-rule-ledger.sh"
fi
PRE
    sed -i.bak '2r '"$STUBS/claude-pre" "$STUBS/claude"
    run weekly
    assert_failure
    assert_output --partial "changed: $HOME/.claude/scripts/harness-rule-ledger.sh"
    refute grep -q 'pr create' "$GH_LOG"
    refute_heartbeat_written
}

@test "選別の claude が Verdict の CLI を書き換えたら、PR を作らずに失敗する" {
    seed_queue
    cat >"$STUBS/claude-pre" <<PRE
if [[ "\$*" == *'harness-review skill'* ]]; then
    printf '# tampered\n' >>"$HOME/.claude/scripts/harness-verdict.sh"
fi
PRE
    sed -i.bak '2r '"$STUBS/claude-pre" "$STUBS/claude"
    run weekly
    assert_failure
    assert_output --partial "changed: $HOME/.claude/scripts/harness-verdict.sh"
    refute grep -q 'pr create' "$GH_LOG"
    refute_heartbeat_written
}

# 推移の節は選別の claude の後に harness-failure-rates.sh trend が Failure Pattern の一覧を読んで作る
review_tampers_with_trend_input() { # <~/.claude/scripts の下のファイル名>
    seed_queue
    cat >"$STUBS/claude-pre" <<PRE
if [[ "\$*" == *'harness-review skill'* ]]; then
    printf '\n' >>"$HOME/.claude/scripts/$1"
fi
PRE
    sed -i.bak '2r '"$STUBS/claude-pre" "$STUBS/claude"
    run weekly
    assert_failure
    assert_output --partial 'changed after the claude runs started'
    # 変わったパスだけを出し、digest の値は出さない
    assert_output --partial "changed: $HOME/.claude/scripts/$1"
    refute_output --partial "$(git hash-object -- "$HOME/.claude/scripts/$1")"
    refute grep -q 'pr create' "$GH_LOG"
    refute_heartbeat_written
}

@test "選別の claude が再発率のスクリプトを書き換えたら、PR を作らずに失敗する" {
    review_tampers_with_trend_input harness-failure-rates.sh
}

@test "選別の claude が Failure Pattern の一覧を書き換えたら、PR を作らずに失敗する" {
    review_tampers_with_trend_input harness-failure-patterns.json
}

@test "commit の無い選別が Verdict の CLI に採用を隠させたら、PR を作らない成功ではなく書き換えとして失敗する" {
    seed_queue
    # 採用したのに commit しなかった run で、採用の列挙(adopted)だけが空を返すようにする。
    # 選別の stub 自身が settle を呼ぶので、settle は元の CLI に渡す
    cli="$HOME/.claude/scripts/harness-verdict.sh"
    cat >"$STUBS/claude-pre" <<PRE
if [[ "\$*" == *'harness-review skill'* ]]; then
    cp "$cli" "$cli.orig"
    printf '#!/usr/bin/env bash\n[[ "\$1" == adopted ]] && exit 0\nexec bash "%s" "\$@"\n' "$cli.orig" >"$cli"
fi
PRE
    sed -i.bak '2r '"$STUBS/claude-pre" "$STUBS/claude"
    STUB_REVIEW_MODE=adopt_uncommitted run weekly
    assert_failure
    assert_output --partial 'changed after the claude runs started'
    # 週次ジョブ自身の言葉でも、PR を作らなかった理由を残す
    assert_output --partial 'harness-weekly: no PR created; the Verdict CLI could not be trusted'
    refute_output --partial 'committed no changes'
    assert [ ! -f "$GH_LOG" ]
    refute_heartbeat_written
}

@test "選別のプロンプトは Rule Ledger を書かせず、ジョブが記録することを伝える" {
    seed_queue
    run weekly
    assert_success
    run cat "$ARGV_LOG"
    assert_output --partial 'Never change files under docs/harness/failure-pattern-rates or docs/harness/rule-ledger'
    assert_output --partial 'Do not run harness-rule-ledger.sh'
}

# Integrity Snapshot(lib/harness-integrity.bash、ADR 0019)が新しく守る経路の contrast pair。
# 書き換えはスナップショットの後(抽出か選別の claude)に限る。分類器の claude はスナップショットの前に走るので、
# そこで書き換えるとスナップショットが書き換えた後の値を取ってしまう

# run_in <reflect|review> <コマンド>: その工程の claude が起動したときにコマンドを実行させる
run_in() {
    local pattern
    case $1 in
    reflect) pattern='harness-reflect skill' ;;
    review) pattern='harness-review skill' ;;
    *) fail "unknown stage: $1" ;;
    esac
    cat >"$STUBS/claude-pre" <<PRE
if [[ "\$*" == *'$pattern'* ]]; then
    $2
fi
PRE
    sed -i.bak '2r '"$STUBS/claude-pre" "$STUBS/claude"
}

# tamper_in <reflect|review> <~/.claude/scripts の下のファイル名>: その工程の claude がファイルに 1 行足す
tamper_in() {
    run_in "$1" "printf '# tampered\n' >>\"$HOME/.claude/scripts/$2\""
}

# rewrite_record_in <reflect|review> <日付>: その工程の claude がローカルの週の記録を書き換える
rewrite_record_in() {
    run_in "$1" "printf '{\"tampered\":true}\n' >\"$RATES/$2.json\""
}

# 選別の claude が commit の後に失敗する run(Loop PR の module の失敗した選別の案内が、手で作る PR の本文を残す)
review_fails_after_commit() {
    cat >"$STUBS/claude-pre" <<'PRE'
[[ "$*" == *'harness-review skill'* ]] && export STUB_CLAUDE_MODE=is_error
PRE
    sed -i.bak '2r '"$STUBS/claude-pre" "$STUBS/claude"
}

@test "選別が commit の後に失敗した run は、手で作る PR の本文に推移の節を足す(書き換えが無い側)" {
    seed_queue
    review_fails_after_commit
    run weekly
    assert_failure
    assert_output --partial 'review failed after 1 commit(s)'
    run cat "$HDIR/review-pr-body-$TODAY.md"
    assert_line '## Failure Pattern の再発率'
}

@test "選別が commit の後に失敗した run で再発率のスクリプトが書き換えられていたら、推移の節を足さない" {
    seed_queue
    review_fails_after_commit
    tamper_in review harness-failure-rates.sh
    run weekly
    assert_failure
    assert_output --partial "changed: $HOME/.claude/scripts/harness-failure-rates.sh"
    assert_output --partial 'the failure rate trend could not be trusted'
    assert_output --partial 'do not publish the branch as it is'
    refute_output --partial 'To publish by hand'
    run cat "$HDIR/review-pr-body-$TODAY.md"
    refute_line '## Failure Pattern の再発率'
}

@test "queue が空の週は、Verdict の CLI が書き換えられていなければ finish_run が heartbeat を書く" {
    run weekly
    assert_success
    assert_heartbeat_written
}

@test "queue が空の週に抽出の claude が Verdict の CLI を書き換えたら、finish_run は CLI を呼ばずに失敗する" {
    tamper_in reflect harness-verdict.sh
    run weekly
    assert_failure
    assert_output --partial "changed: $HOME/.claude/scripts/harness-verdict.sh"
    assert_output --partial 'failed to read the unpublished verdicts'
    refute_heartbeat_written
}

# 採用の印が残るループのブランチ(Verdict の CLI の unpublished --branch が印を返す)
leftover_adopted_branch() {
    leftover_branch harness/review-2026-09-01
    printf -- '## [2026-01-01] old\n\n- **Verdict:** adopted (harness/review-2026-09-01 run old)\n' >"$HDIR/queue-archive.md"
}

# Verdict の CLI を、呼ばれたら印のファイルを残して何も返さない偽物に差し替える(採用を隠す書き換え)
hide_adoptions_in_verdict_cli() { # <差し替える工程 reflect|now>
    cat >"$BATS_TEST_TMPDIR/fake-verdict.sh" <<EOF
#!/usr/bin/env bash
touch "$BATS_TEST_TMPDIR/verdict-called"
exit 0
EOF
    if [[ "$1" == now ]]; then
        cp "$BATS_TEST_TMPDIR/fake-verdict.sh" "$HOME/.claude/scripts/harness-verdict.sh"
        return
    fi
    cat >"$STUBS/claude-pre" <<PRE
if [[ "\$*" == *'harness-reflect skill'* ]]; then
    cp "$BATS_TEST_TMPDIR/fake-verdict.sh" "$HOME/.claude/scripts/harness-verdict.sh"
fi
PRE
    sed -i.bak '2r '"$STUBS/claude-pre" "$STUBS/claude"
}

@test "抽出の claude が Verdict の CLI を書き換えたら、report_stops は CLI を呼ばずに、信頼できなかったと書いたブランチの Issue を作る" {
    leftover_adopted_branch
    hide_adoptions_in_verdict_cli reflect
    run weekly
    assert_failure
    assert [ ! -e "$BATS_TEST_TMPDIR/verdict-called" ]
    refute_output --partial 'has an adopted verdict'
    run cat "$ALERT_LOG"
    assert_line --partial "issue create --label harness-analysis --title ${FAILED_TITLE} --body "
    assert_line --partial 'issue create --label harness-analysis --title harness: ループのブランチ harness/review-2026-09-01 が PR になっていない'
    run cat "$ALERT_BODIES"
    assert_output --partial 'Verdict CLI を信頼できなかった'
}

# 改ざんの検出の lib だけが無い(健全性の lib は在る)入口スクリプトの複製で起動する
weekly_without_integrity_lib() {
    local dir="$BATS_TEST_TMPDIR/nointegrity"
    mkdir -p "$dir/lib"
    cp "$SCRIPT" "$dir/harness-weekly.sh"
    cp "$BATS_TEST_DIRNAME/../dot_claude/scripts/lib/harness-health.bash" "$dir/lib/"
    bash "$dir/harness-weekly.sh"
}

@test "改ざんの検出の lib を読み込む前に止まった run の report_stops は、CLI を呼ばずに、確かめられなかったと書いたブランチの Issue を作る" {
    leftover_adopted_branch
    hide_adoptions_in_verdict_cli now
    run weekly_without_integrity_lib
    assert_failure
    assert_output --partial 'harness-integrity.bash is missing or broken'
    assert [ ! -e "$BATS_TEST_TMPDIR/verdict-called" ]
    run cat "$ALERT_LOG"
    assert_line --partial "issue create --label harness-analysis --title ${FAILED_TITLE} --body "
    assert_line --partial 'issue create --label harness-analysis --title harness: ループのブランチ harness/review-2026-09-01 が PR になっていない'
    run cat "$ALERT_BODIES"
    assert_output --partial 'Verdict CLI を確かめられなかった'
}

# Loop PR の module だけが無いか壊れた(ほかの lib は在る)入口スクリプトの複製で起動する
weekly_without_loop_pr_lib() { # [<lib に置く中身>]
    local dir="$BATS_TEST_TMPDIR/noloop-pr"
    mkdir -p "$dir/lib"
    cp "$SCRIPT" "$dir/harness-weekly.sh"
    cp "$BATS_TEST_DIRNAME/../dot_claude/scripts/lib/harness-health.bash" \
        "$BATS_TEST_DIRNAME/../dot_claude/scripts/lib/harness-integrity.bash" \
        "$BATS_TEST_DIRNAME/../dot_claude/scripts/lib/harness-review-outcome.bash" \
        "$BATS_TEST_DIRNAME/../dot_claude/scripts/lib/harness-pr-body.bash" "$dir/lib/"
    [[ $# -eq 0 ]] || printf '%s\n' "$1" >"$dir/lib/harness-loop-pr.bash"
    bash "$dir/harness-weekly.sh"
}

@test "Loop PR の module が無くて止まった run も、失敗の Issue を作る" {
    run weekly_without_loop_pr_lib
    assert_failure
    assert_output --partial 'harness-loop-pr.bash is missing or broken'
    refute_output --partial 'command not found'
    run cat "$ALERT_LOG"
    assert_line --partial "issue create --label harness-analysis --title ${FAILED_TITLE} --body "
}

@test "Loop PR の module の構文が壊れていれば、読み込まずに止まる" {
    run weekly_without_loop_pr_lib 'harness_loop_pr_init() {'
    assert_failure
    assert_output --partial 'harness-loop-pr.bash is missing or broken'
    refute_output --partial 'command not found'
    run cat "$ALERT_LOG"
    assert_line --partial "issue create --label harness-analysis --title ${FAILED_TITLE} --body "
}

@test "Loop PR の module に綴りや公開の関数が欠けていれば止まる" {
    run weekly_without_loop_pr_lib '# empty'
    assert_failure
    assert_output --partial 'harness-loop-pr.bash lacks the publish steps'
    refute_output --partial 'command not found'
    run weekly_without_loop_pr_lib "$(sed 's/^harness_loop_pr_review_instructions() {/_removed() {/' "$BATS_TEST_DIRNAME/../dot_claude/scripts/lib/harness-loop-pr.bash")"
    assert_failure
    assert_output --partial 'harness-loop-pr.bash lacks the publish steps'
    run cat "$ALERT_LOG"
    assert_line --partial "issue create --label harness-analysis --title ${FAILED_TITLE} --body "
}

@test "Loop PR の module か Review Outcome の lib を読めずに止まった run も、起動時に読んだ前の成功の古さを、この run の失敗の Issue に任せたと出す" {
    # 前の成功の日数は Loop PR の module(Review Outcome の lib はその中で読む)を読み込む前に読むので、その読み込みで
    # 止まった run の report_stops も使う
    seed_heartbeat "$(($(date +%s) - 9 * 86400))"
    run weekly_without_loop_pr_lib
    assert_failure
    assert_output --partial 'harness-loop-pr.bash is missing or broken'
    assert_output --partial 'last success was 9 days ago; the failure issue of this run reports it'
    run weekly_without_review_outcome_lib
    assert_failure
    assert_output --partial 'harness-review-outcome.bash is missing or broken'
    assert_output --partial 'last success was 9 days ago; the failure issue of this run reports it'
}

# Review Outcome の lib だけが無いか壊れた(健全性の lib・Integrity Snapshot の lib と、Review Outcome の lib を読む
# Loop PR の module は在る)入口スクリプトの複製で起動する
weekly_without_review_outcome_lib() { # [<lib に置く中身>]
    local dir="$BATS_TEST_TMPDIR/nooutcome"
    mkdir -p "$dir/lib"
    cp "$SCRIPT" "$dir/harness-weekly.sh"
    cp "$BATS_TEST_DIRNAME/../dot_claude/scripts/lib/harness-health.bash" \
        "$BATS_TEST_DIRNAME/../dot_claude/scripts/lib/harness-integrity.bash" \
        "$BATS_TEST_DIRNAME/../dot_claude/scripts/lib/harness-loop-pr.bash" "$dir/lib/"
    [[ $# -eq 0 ]] || printf '%s\n' "$1" >"$dir/lib/harness-review-outcome.bash"
    bash "$dir/harness-weekly.sh"
}

@test "Review Outcome の lib が無いか壊れていれば、読み込まずに止まり失敗の Issue を作る" {
    run weekly_without_review_outcome_lib
    assert_failure
    assert_output --partial 'harness-review-outcome.bash is missing or broken'
    refute_output --partial 'command not found'
    run weekly_without_review_outcome_lib 'harness_review_outcome_init() {'
    assert_failure
    assert_output --partial 'harness-review-outcome.bash is missing or broken'
    run weekly_without_review_outcome_lib '# empty'
    assert_failure
    assert_output --partial 'harness-review-outcome.bash lacks the review outcome checks'
    run cat "$ALERT_LOG"
    assert_line --partial "issue create --label harness-analysis --title ${FAILED_TITLE} --body "
}

# 本文の lib だけが無いか壊れた(ほかの lib は在る)入口スクリプトの複製で起動する
weekly_without_pr_body_lib() { # [<lib に置く中身>]
    local dir="$BATS_TEST_TMPDIR/noprbody"
    mkdir -p "$dir/lib"
    cp "$SCRIPT" "$dir/harness-weekly.sh"
    cp "$BATS_TEST_DIRNAME/../dot_claude/scripts/lib/harness-health.bash" \
        "$BATS_TEST_DIRNAME/../dot_claude/scripts/lib/harness-integrity.bash" \
        "$BATS_TEST_DIRNAME/../dot_claude/scripts/lib/harness-loop-pr.bash" \
        "$BATS_TEST_DIRNAME/../dot_claude/scripts/lib/harness-review-outcome.bash" "$dir/lib/"
    [[ $# -eq 0 ]] || printf '%s\n' "$1" >"$dir/lib/harness-pr-body.bash"
    bash "$dir/harness-weekly.sh"
}

@test "本文の lib が無いか壊れていれば、読み込まずに止まり失敗の Issue を作る" {
    run weekly_without_pr_body_lib
    assert_failure
    assert_output --partial 'harness-pr-body.bash is missing or broken'
    refute_output --partial 'command not found'
    run weekly_without_pr_body_lib 'harness_pr_body_init() {'
    assert_failure
    assert_output --partial 'harness-pr-body.bash is missing or broken'
    run weekly_without_pr_body_lib '# empty'
    assert_failure
    assert_output --partial 'harness-pr-body.bash lacks the PR body sections'
    run cat "$ALERT_LOG"
    assert_line --partial "issue create --label harness-analysis --title ${FAILED_TITLE} --body "
    assert [ ! -f "$ARGV_LOG" ]
}

@test "Loop PR の module を読み込む前に止まった run のブランチの Issue も、lib が組み立てるのと同じ綴りで公開の手順を書く" {
    mv "$HARNESS_WEEKLY_REPO" "$HOME/repo"
    export HARNESS_WEEKLY_REPO="$HOME/repo"
    leftover_branch harness/review-2026-09-01
    # 綴りの正本(lib)で組み立てた手順。report_stops は lib が無い run では自分の写しで同じ文を作る
    expected=$(
        # shellcheck source=../dot_claude/scripts/lib/harness-loop-pr.bash
        source "$BATS_TEST_DIRNAME/../dot_claude/scripts/lib/harness-loop-pr.bash"
        printf -- '- 公開する: `%s` の後に、`~/repo` で `%s`' \
            "$(harness_loop_pr_push_command harness/review-2026-09-01 '~/repo')" \
            "$(harness_loop_pr_create_command harness/review-2026-09-01)"
    )
    run weekly_without_loop_pr_lib
    assert_failure
    assert_output --partial 'harness-loop-pr.bash is missing or broken'
    run cat "$ALERT_LOG"
    assert_line --partial 'issue create --label harness-analysis --title harness: ループのブランチ harness/review-2026-09-01 が PR になっていない'
    run cat "$ALERT_BODIES"
    assert_line "$expected"
    assert_output --partial '- 公開する: `git -C ~/repo push origin harness/review-2026-09-01` の後に、`~/repo` で `gh pr create --draft --base main --head harness/review-2026-09-01`'
    refute_output --partial "$HOME"
}


@test "スナップショットの前に止まった run の report_stops も、CLI を呼ばずに、確かめられなかったと書く" {
    leftover_adopted_branch
    rm "$HOME/.claude/scripts/harness-detect-failures.sh"
    hide_adoptions_in_verdict_cli now
    run weekly
    assert_failure
    assert_output --partial 'selecting pending sessions with'
    refute_output --partial 'harness-integrity:'
    assert [ ! -e "$BATS_TEST_TMPDIR/verdict-called" ]
    run cat "$ALERT_BODIES"
    assert_output --partial 'Verdict CLI を確かめられなかった'
    refute_output --partial 'Verdict CLI を信頼できなかった'
}

@test "ハッシュを取れない週の記録は、照合できないとして PR を作らずに失敗する(WARN で公開を続けない)" {
    seed_queue
    old_record 2026-09-26
    cat >"$STUBS/claude-pre" <<PRE
if [[ "\$*" == *'harness-review skill'* ]]; then
    chmod 000 "$RATES/2026-09-26.json"
fi
PRE
    sed -i.bak '2r '"$STUBS/claude-pre" "$STUBS/claude"
    run weekly
    chmod 644 "$RATES/2026-09-26.json"
    assert_failure
    assert_output --partial "could not hash $RATES/2026-09-26.json"
    refute_output --partial 'WARN failed to commit the weekly failure rate records'
    refute grep -q 'pr create' "$GH_LOG"
    refute_heartbeat_written
}

@test "ハッシュを取れる週の記録なら、持ち越した記録も PR に載せる(照合できない側の対)" {
    seed_queue
    old_record 2026-09-26
    run weekly
    assert_success
    run git -C "$ORIGIN" diff --name-only "main..$BRANCH" -- "$RATES_REPO_DIR"
    assert_line "$RATES_REPO_DIR/2026-09-26.json"
}

# 各 claude の後のデータの照合。queue が空の週と当日の PR が既にある週、選別が失敗で終わる run は repo に写す工程を
# 通らないので、claude が書き換えたデータを照合しないと、書き換えがログに出ないまま次の run のスナップショットが正として持ち越す

@test "queue が空の週は、持ち越した週の記録が書き換えられていなければ heartbeat を書く" {
    old_record 2026-09-26
    run weekly
    assert_success
    assert_output --partial 'queue is empty; skipped review'
    assert_heartbeat_written
}

@test "queue が空の週に抽出の claude が週の記録を書き換えたら、heartbeat を書かずに失敗する" {
    old_record 2026-09-26
    rewrite_record_in reflect 2026-09-26
    run weekly
    assert_failure
    assert_output --partial "changed: $RATES/2026-09-26.json"
    refute_output --partial 'queue is empty; skipped review'
    refute_heartbeat_written
}

@test "当日の PR が既にある週に抽出の claude が週の記録を書き換えたら、heartbeat を書かずに失敗する" {
    seed_queue
    old_record 2026-09-26
    git -C "$HARNESS_WEEKLY_REPO" push -q origin "main:refs/heads/${BRANCH}"
    rewrite_record_in reflect 2026-09-26
    run weekly
    assert_failure
    assert_output --partial "changed: $RATES/2026-09-26.json"
    refute_output --partial 'already exists on origin'
    refute_heartbeat_written
}

@test "抽出の claude が失敗した run で週の記録が書き換えられていたら、書き換えをログに出す" {
    old_record 2026-09-26
    run_in reflect "printf '{\"tampered\":true}\n' >\"$RATES/2026-09-26.json\"; export STUB_CLAUDE_MODE=is_error"
    run weekly
    assert_failure
    assert_output --partial 'reflect: claude failed'
    assert_output --partial "changed: $RATES/2026-09-26.json"
    assert_output --partial 'could not be trusted after reflect'
    refute_heartbeat_written
}

# 選別の claude が成功していても、照合に落ちた run は選別の結果の振り分け(未 commit の変更の確認)を通らず
# Loop PR の module の失敗した選別の案内に回る。commit が 0 件なので、claude の失敗ではなく記録の書き換えを告げる文面を出す
@test "選別の claude が commit されていない変更を残した run で週の記録が書き換えられていたら、書き換えをログに出す" {
    seed_queue
    old_record 2026-09-26
    rewrite_record_in review 2026-09-26
    STUB_REVIEW_MODE=dirty run weekly
    assert_failure
    assert_output --partial "changed: $RATES/2026-09-26.json"
    assert_output --partial 'review made no commits, and the records the job uses were changed'
    refute_output --partial 'review failed before committing'
    refute_heartbeat_written
}

# 選別の claude が失敗した run(Loop PR の module の失敗した選別の案内)のデータの照合。書き換えが無い側は
# 「選別の claude が commit の前に失敗したら、claude の失敗として告げる」と
# 「選別の claude が commit の後に失敗したら、手で作る PR の本文に検出の節を足す」

@test "選別の claude が commit の前に失敗した run は、claude の失敗として告げる(書き換えが無い側)" {
    seed_queue
    review_fails_after_commit
    STUB_REVIEW_MODE=none run weekly
    assert_failure
    assert_output --partial 'review failed before committing'
    refute_output --partial 'the records the job uses were changed'
}

@test "選別の claude が commit の前に失敗した run で週の記録が書き換えられていたら、書き換えをログに出す" {
    seed_queue
    old_record 2026-09-26
    review_fails_after_commit
    rewrite_record_in review 2026-09-26
    STUB_REVIEW_MODE=none run weekly
    assert_failure
    assert_output --partial 'review made no commits, and the records the job uses were changed'
    refute_output --partial 'review failed before committing'
    assert_output --partial "changed: $RATES/2026-09-26.json"
}

@test "選別が commit の後に失敗した run で週の記録が書き換えられていたら、手で公開する手順を案内しない" {
    seed_queue
    old_record 2026-09-26
    review_fails_after_commit
    rewrite_record_in review 2026-09-26
    run weekly
    assert_failure
    assert_output --partial "changed: $RATES/2026-09-26.json"
    assert_output --partial 'do not publish the branch as it is'
    refute_output --partial 'To publish by hand'
    run cat "$HDIR/review-pr-body-$TODAY.md"
    refute_line '## 失敗の検出'
    refute_line '## Failure Pattern の再発率'
}

# 書き換えが無い側は、選別が成功して PR を作る run(既定の adopt)
@test "選別の claude が成功しても週の記録を書き換えていたら、PR を作らず、手で公開する手順を案内しない" {
    seed_queue
    old_record 2026-09-26
    rewrite_record_in review 2026-09-26
    run weekly
    assert_failure
    assert_output --partial "changed: $RATES/2026-09-26.json"
    assert_output --partial 'do not publish the branch as it is'
    refute_output --partial 'To publish by hand'
    refute grep -q 'pr create' "$GH_LOG"
    refute_heartbeat_written
}

# PR を作った後の経路。Verdict の CLI の adopted が照合のほかの理由で失敗しても、Rule Ledger の記録と heartbeat は止めない

# adopted だけを失敗させる Verdict の CLI に差し替える(スナップショットの前なので書き換えではない)
verdict_fails_on_adopted() {
    mv "$HOME/.claude/scripts/harness-verdict.sh" "$HOME/.claude/scripts/harness-verdict-real.sh"
    cat >"$HOME/.claude/scripts/harness-verdict.sh" <<'EOF2'
#!/usr/bin/env bash
[[ "$1" != adopted ]] || exit 1
exec bash "$HOME/.claude/scripts/harness-verdict-real.sh" "$@"
EOF2
}

@test "Verdict の CLI の adopted が失敗しても、PR を作った後の Rule Ledger の記録と heartbeat は止めない" {
    seed_queue
    verdict_fails_on_adopted
    run weekly
    assert_success
    assert_output --partial 'WARN could not read the adopted verdicts'
    assert_output --partial 'opened draft PR https://github.com/example/dotfiles/pull/42'
    assert_output --partial 'Rule Ledger record(s)'
    refute_output --partial 'could not be trusted'
    assert_heartbeat_written
}
