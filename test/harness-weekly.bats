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
#
# 検査するのは入口スクリプトの振る舞い: 工程の順序、早期に終わる分岐、lib の読み込みの失敗、週次ジョブ自身の停止の通知
# (失敗の Issue・走らなかった週の Issue)と EXIT trap が Loop Stall の module を呼ぶ配線、抽出の prompt と claude の起動。Loop Stall の
# 判定と文面は test/harness-loop-stalls.bats が Loop Stall の module の interface で検査する。Loop PR の経路(当日のブランチの照会・worktree の準備・依存のインストール・本文・公開・
# Metrics-only PR・評価・Rule Ledger・失敗した選別の案内)と選別の prompt の中身は test/harness-loop-pr.bats が Loop PR の
# module の interface で検査する。ここに残す Loop PR の経路の通し実行は、入口スクリプトの配線(選別の claude の失敗が module に届くこと、
# module の失敗で run が失敗して heartbeat を書かないこと、選別の後に締めの確認(前の run の未公開の採用と finish_run)をすること、queue が空の週に
# Metrics-only PR の入口を呼ぶこと、選別の claude に採用の印と書き込みの規則の文が渡ること)を見るものだけ。
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
all_args="$*"
case "$all_args" in
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
if [[ "$all_args" == *'--no-session-persistence'* ]]; then
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
    # 結果ファイル(落とした変更と deploy-only の修正)。空配列で書く
    printf '{"dropped":[],"deploy_only":[]}\n' >"$HOME/.claude/harness/review-result-$(date +%Y-%m-%d).json"
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
    # 開いているループの PR の一覧(Metrics-only PR を作るかの判定)。STUB_GH_OPEN_LOOP_PR の URL を出し、既定は無し。
    # 開いている PR があるときの判定は test/harness-loop-pr.bats が Loop PR の module の interface で検査する
    [[ -z "${STUB_GH_OPEN_LOOP_PR:-}" ]] || printf '%s\n' "$STUB_GH_OPEN_LOOP_PR"
    exit 0
fi
if [[ "$1 $2" == "pr list" ]]; then
    printf 'https://github.com/example/dotfiles/pull/41\n'
    exit 0
fi
if [[ "$1 $2" == "pr view" && "$*" == *'--json state'* ]]; then
    # Rule Ledger の書き出しが引く PR の状態
    printf 'MERGED\n'
    exit 0
fi
while [[ $# -gt 0 ]]; do
    [[ "$1" == "--body-file" ]] && cp "$2" "$GH_BODY"
    shift
done
printf 'https://github.com/example/dotfiles/pull/42\n'
EOF
    install_exec "$STUBS/pnpm" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "$(pwd)" "$*" >>"$PNPM_LOG"
exit 0
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
    # Eval Case の評価のスクリプトと eval 専用 plugin の雛形も本物を置く(選別が依頼を書かないので、評価の claude は起動しない)
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

@test "queue が空なら選別を起動せず、その旨をログに残す" {
    run weekly
    assert_success
    assert_output --partial 'queue is empty; skipped review'
    run cat "$STAGE_LOG"
    assert_output 'reflect'
    # Metrics-only PR の判定は開いている Loop PR を照会するが、記録が 4 週分に満たないので PR は作らない
    run cat "$GH_LOG"
    refute_output --partial 'pr create'
}

@test "pending が空でも queue に項目があれば選別を起動する" {
    : >"$HDIR/pending.jsonl"
    seed_queue
    run weekly
    assert_success
    run cat "$STAGE_LOG"
    assert_output 'review'
}

@test "抽出と選別の claude の prompt に、書き込みの規則の文を 1 つずつ入れる" {
    seed_queue
    run weekly
    assert_success
    run cat "$ARGV_LOG"
    assert_output --partial 'harness-reflect skill'
    assert_output --partial 'harness-review skill'
    run grep -c 'only with the Write and Edit tools, never with heredocs, echo or printf: .* moving it into place' "$ARGV_LOG"
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

@test "選別の claude が commit の後に失敗したら、その失敗が Loop PR の module に届き、PR を作らずに失敗する" {
    : >"$HDIR/pending.jsonl"
    seed_queue
    STUB_CLAUDE_MODE=is_error run weekly
    assert_failure
    # module が失敗した選別の案内に回したことは、module だけが出すこの行で分かる
    assert_output --partial "harness-weekly: review failed after 1 commit(s) on local branch ${BRANCH}"
    assert [ ! -f "$GH_LOG" ]
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

# 前の run の未公開の採用の確認の中身(案内の文言・成功で終わる各経路・読めないときと照合に落ちたとき)は
# test/harness-loop-pr.bats が検査する。ここでは、Loop PR の module の入口の失敗が run の失敗と heartbeat に届く配線だけを見る
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

@test "permission の拒否(headless では hook の ask も拒否)があれば実行ログに警告を出す" {
    STUB_CLAUDE_MODE=denied run weekly
    assert_success
    assert_output --partial 'WARN reflect: 1 permission denial'
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

# 失敗の検出の節の期間の中身(期間の切り方・読めない行・表の形)は test/harness-failure-rates.bats が再発率の CLI で検査する。
# ここでは、PR を作った後に失敗した run(heartbeat を書かない)の次の run の PR が、前の PR の期間を重ねて数えないことを見る。
# 1 回目の run は Weekly Rate Record を書いた後で PR を作り、Loop PR の module の入口の最後の確認が前の run の採用の残りで失敗する
@test "PR を作った後に失敗した run の次の run の PR は、前の PR が数えた期間の検出を数えない" {
    : >"$HDIR/pending.jsonl"
    now=$(date +%s)
    # 前の成功は検出より前。期間を heartbeat で決めると、1 回目の期間が 2 回目にも入る
    seed_heartbeat "$((now - 3 * 86400))"
    printf '{"session_id":"d1","run":"manual","date":"2026-01-01","epoch":%s,"counts":{"user_negation":5}}\n' \
        "$((now - 600))" >"$HDIR/detections.jsonl"
    printf -- '## [2026-01-01] old\n\n- **Verdict:** adopted (harness/review-2026-01-01)\n' >"$HDIR/queue-archive.md"
    seed_queue
    run weekly
    assert_failure
    assert_output --partial 'never became a PR'
    # Loop PR の module が本物の再発率の CLI の件数の行を読めている(test/harness-loop-pr.bats は CLI を stub にする)
    assert_output --partial 'committed 1 weekly failure rate record(s)'
    refute_heartbeat_written
    run cat "$GH_BODY"
    assert_line '| `user_negation` | 5 |'
    # 1 回目の run を前の日の run にする(同じ日の run は同じ期間の始まりで記録を書き直すため): 記録を前の日付に移し、
    # origin のブランチを消す(残すと 2 回目は当日の PR が既にあるとして選別を省く)
    local previous=2000-01-01 until
    jq --arg date "$previous" '.date = $date' "$RATES/$TODAY.json" >"$RATES/$previous.json"
    rm "$RATES/$TODAY.json" "$GH_BODY"
    git -C "$ORIGIN" branch -q -D "$BRANCH"
    # 2 回目の検出の epoch が 1 回目の記録の終わりと同じ秒にならないようにする
    until=$(jq -e '.until' "$RATES/$previous.json")
    while [[ "$(date +%s)" -le "$until" ]]; do sleep 0.1; done
    add_session err1 tool-error
    # 1 回目の項目は判定の記録に移っているので、別の見出しの項目を置く
    printf '# Harness improvement queue\n\n## [2026-10-04] next entry\n\n- **Scope:** global\n' >"$HDIR/queue.md"
    run weekly
    assert_output --partial 'opened draft PR'
    run cat "$GH_BODY"
    refute_line '| `user_negation` | 5 |'
    assert_line '| `tool_error` | 3 |'
    assert_line '| 合計 | 3 |'
    # 本文の lib が推移の節を本物の再発率の CLI に渡す形(日付の引数)も、ここでしか本物どうしで繋がらない。
    # 呼び方がずれると CLI は使い方の誤りで終わり、本文の lib は節を WARN で省くだけなので、節の列の並びで確かめる
    assert_line "| Failure Pattern | $previous | $TODAY |"
}

# 週次ジョブ自身の停止と Loop Stall を GitHub Issue で知らせる(#402、ADR 0012 の Consequences)。Issue の
# タイトルが重複を避ける鍵で、同じタイトルの Issue が開いていればコメントにする

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

@test "週次ジョブ自身の停止と Loop Stall を知らせる gh の呼び出しは lock を解放してから行う(gh が固まっても lock を握ったままにしない)" {
    # 失敗の Issue と、Loop Stall の module の問い合わせ(開いている PR の一覧とブランチの PR の有無)の両方を見る
    leftover_branch harness/review-2026-09-01
    STUB_GH_OPEN_PRS=$(jq -n --arg old "$(iso_days_ago 15)" '[
        {number: 51, url: "https://github.com/example/dotfiles/pull/51", headRefName: "harness/review-2026-09-01", createdAt: $old}
    ]')
    export STUB_GH_OPEN_PRS
    STUB_CLAUDE_MODE=exit1 run weekly
    assert_failure
    run cat "$ALERT_LOG"
    assert_line --partial "issue create --label harness-analysis --title ${FAILED_TITLE} --body "
    assert_line --partial 'pr list --state open --limit 100 --json number,url,headRefName,createdAt'
    assert_line --partial 'pr list --head harness/review-2026-09-01 '
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

# 前の週の run が PR にならないまま残した、origin/main に無い commit を持つループのブランチ
leftover_branch() { # <ブランチ>
    git -C "$HARNESS_WEEKLY_REPO" switch -q -c "$1"
    printf 'x\n' >"$HARNESS_WEEKLY_REPO/stale.md"
    git -C "$HARNESS_WEEKLY_REPO" add stale.md
    git -C "$HARNESS_WEEKLY_REPO" commit -qm 'harness: fix stale rule'
    git -C "$HARNESS_WEEKLY_REPO" switch -q main
}

# Loop Stall(放置された Loop PR と PR にならないループのブランチ)の判定と文面は test/harness-loop-stalls.bats が
# module の interface で検査する。ここでは、EXIT trap が module を呼び、送る関数に alert_issue を渡していることだけを見る
# (Issue の作成とタイトルでの重複の回避は alert_issue の仕事で、失敗の Issue のケースが検査する)

# 放置された Loop PR と PR にならないループのブランチを 1 つずつ置く
seed_loop_stalls() {
    leftover_branch harness/review-2026-09-01
    STUB_GH_OPEN_PRS=$(jq -n --arg old "$(iso_days_ago 15)" '[
        {number: 51, url: "https://github.com/example/dotfiles/pull/51", headRefName: "harness/review-2026-09-08", createdAt: $old}
    ]')
    export STUB_GH_OPEN_PRS
}

@test "成功した run も、Loop Stall を alert_issue で Issue にする" {
    seed_loop_stalls
    run weekly
    assert_success
    refute_output --partial 'loop stalls were not checked'
    run cat "$ALERT_LOG"
    assert_line --partial 'issue create --label harness-analysis --title harness: ループの PR #51 が 14 日以上放置されている --body '
    assert_line --partial 'issue create --label harness-analysis --title harness: ループのブランチ harness/review-2026-09-01 が PR になっていない --body '
}

@test "Loop Stall の Issue が開いていれば、alert_issue が新しく作らずにコメントにする" {
    seed_loop_stalls
    export STUB_GH_ISSUES='[{"number":9,"title":"harness: ループの PR #51 が 14 日以上放置されている","updatedAt":"2026-01-01T00:00:00Z"}]'
    run weekly
    assert_success
    run cat "$ALERT_LOG"
    assert_line --regexp '^issue comment 9 '
    refute_line --partial 'issue create --label harness-analysis --title harness: ループの PR #51'
}

@test "Loop PR の module を読めずに止まった run は、失敗の Issue と前の成功の古さは扱い、Loop Stall の module は呼ばない" {
    seed_loop_stalls
    seed_heartbeat "$(($(date +%s) - 9 * 86400))"
    run weekly_without_loop_pr_lib
    assert_failure
    assert_output --partial 'harness-loop-pr.bash is missing or broken'
    assert_output --partial 'last success was 9 days ago; the failure issue of this run reports it'
    assert_output --partial 'loop stalls were not checked'
    refute_output --partial 'command not found'
    run cat "$ALERT_LOG"
    assert_line --partial "issue create --label harness-analysis --title ${FAILED_TITLE} --body "
    refute_line --partial 'createdAt'
    refute_line --partial 'pr list --head'
    refute_line --partial 'ループの PR #51'
    refute_line --partial 'ループのブランチ'
}

# Loop Stall の module だけが無いか壊れた(ほかの lib は在る)入口スクリプトの複製で起動する
weekly_without_loop_stalls_lib() { # [<lib に置く中身>]
    local dir="$BATS_TEST_TMPDIR/noloop-stalls"
    mkdir -p "$dir/lib"
    cp "$SCRIPT" "$dir/harness-weekly.sh"
    cp "$BATS_TEST_DIRNAME/../dot_claude/scripts/lib/harness-health.bash" \
        "$BATS_TEST_DIRNAME/../dot_claude/scripts/lib/harness-integrity.bash" \
        "$BATS_TEST_DIRNAME/../dot_claude/scripts/lib/harness-review-outcome.bash" \
        "$BATS_TEST_DIRNAME/../dot_claude/scripts/lib/harness-pr-body.bash" \
        "$BATS_TEST_DIRNAME/../dot_claude/scripts/lib/harness-loop-pr.bash" "$dir/lib/"
    [[ $# -eq 0 ]] || printf '%s\n' "$1" >"$dir/lib/harness-loop-stalls.bash"
    bash "$dir/harness-weekly.sh"
}

@test "Loop Stall の module が無いか壊れているか入口が欠けていれば、読み込まずに止まり失敗の Issue を作る" {
    seed_loop_stalls
    run weekly_without_loop_stalls_lib
    assert_failure
    assert_output --partial 'harness-loop-stalls.bash is missing or broken'
    assert_output --partial 'loop stalls were not checked'
    refute_output --partial 'command not found'
    run weekly_without_loop_stalls_lib 'harness_loop_stalls_report() {'
    assert_failure
    assert_output --partial 'harness-loop-stalls.bash is missing or broken'
    assert_output --partial 'loop stalls were not checked'
    run weekly_without_loop_stalls_lib '# empty'
    assert_failure
    assert_output --partial 'harness-loop-stalls.bash lacks the loop stall checks'
    assert_output --partial 'loop stalls were not checked'
    refute_output --partial 'command not found'
    run cat "$ALERT_LOG"
    assert_line --partial "issue create --label harness-analysis --title ${FAILED_TITLE} --body "
    refute_line --partial 'createdAt'
    assert [ ! -f "$ARGV_LOG" ]
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

@test "健全性の lib を読む前に止まった run は、環境に MISSED_DAYS があっても前の成功の古さを知らせない" {
    MISSED_DAYS=30 LAST_SUCCESS=0 run weekly_without_lib
    assert_failure
    refute_output --partial 'last success was'
    run cat "$ALERT_LOG"
    assert_line --partial "issue create --label harness-analysis --title ${FAILED_TITLE} --body "
    refute_output --partial '日以上成功していなかった'
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

@test "採用 0 件の週に origin/main に無い記録が 4 週分たまったら、Metrics-only PR を作る" {
    old_record 2026-09-12
    old_record 2026-09-19
    old_record 2026-09-26
    run weekly
    assert_success
    run grep -c "^pr create --draft --base main --head ${BRANCH} " "$GH_LOG"
    assert_output 1
    assert_heartbeat_written
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

# Loop PR の module だけが無いか壊れた(ほかの lib は在る)入口スクリプトの複製で起動する
weekly_without_loop_pr_lib() { # [<lib に置く中身>]
    local dir="$BATS_TEST_TMPDIR/noloop-pr"
    mkdir -p "$dir/lib"
    cp "$SCRIPT" "$dir/harness-weekly.sh"
    cp "$BATS_TEST_DIRNAME/../dot_claude/scripts/lib/harness-health.bash" \
        "$BATS_TEST_DIRNAME/../dot_claude/scripts/lib/harness-integrity.bash" \
        "$BATS_TEST_DIRNAME/../dot_claude/scripts/lib/harness-review-outcome.bash" \
        "$BATS_TEST_DIRNAME/../dot_claude/scripts/lib/harness-pr-body.bash" \
        "$BATS_TEST_DIRNAME/../dot_claude/scripts/lib/harness-loop-stalls.bash" "$dir/lib/"
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
    run weekly_without_loop_pr_lib "$(sed 's/^harness_loop_pr_record_command() {/_removed() {/' "$BATS_TEST_DIRNAME/../dot_claude/scripts/lib/harness-loop-pr.bash")"
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

# 抽出の claude の後のデータの照合。queue が空の週と当日の PR が既にある週、抽出が失敗した run は repo に写す工程を
# 通らないので、claude が書き換えたデータを照合しないと、書き換えがログに出ないまま次の run のスナップショットが正として持ち越す。
# 選別の claude の後の照合は Loop PR の module の選別の経路の入口が行う(test/harness-loop-pr.bats)

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
