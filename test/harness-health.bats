# 自己改善ループの健全性の判定(lib/harness-health.bash)の interface の検査。
# briefing と doctor は、ここで検査する level と文言を表示するだけなので、
# 判定の場合分けはこのファイルにだけ書く。
setup() {
    load 'helpers/setup'
    LIB="$BATS_TEST_DIRNAME/../dot_claude/scripts/lib/harness-health.bash"
    export HOME="$BATS_TEST_TMPDIR/home"
    HDIR="$HOME/.claude/harness"
    PLIST="$HOME/Library/LaunchAgents/local.dotfiles.harness-weekly.plist"
    mkdir -p "$HDIR"
    stub_uname Darwin
}

# ホストの OS に依存しないよう uname をスタブにする
stub_uname() {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat >"$BATS_TEST_TMPDIR/bin/uname" <<EOF
#!/usr/bin/env bash
printf '%s\\n' $1
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/uname"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

weekly_installed() {
    mkdir -p "$(dirname "$PLIST")" "$HOME/.claude/scripts"
    : >"$PLIST"
    printf '#!/usr/bin/env bash\n' >"$HOME/.claude/scripts/harness-weekly.sh"
    chmod +x "$HOME/.claude/scripts/harness-weekly.sh"
}

heartbeat_days_ago() {
    printf '%s\n' "$(($(date +%s) - $1 * 86400))" >"$HDIR/weekly-heartbeat"
}

weekly() {
    # shellcheck source=../dot_claude/scripts/lib/harness-health.bash
    source "$LIB"
    harness_health_weekly
}

@test "状態ディレクトリは ~/.claude/harness" {
    source "$LIB"
    run harness_health_dir
    assert_success
    assert_output "$HDIR"
}

@test "初期化は state.json / pending.jsonl / queue.md を作り、既にあれば上書きしない" {
    rm -rf "$HDIR"
    source "$LIB"
    run harness_health_bootstrap
    assert_success
    assert_equal "$(cat "$HDIR/state.json")" '{"version":1}'
    assert [ -f "$HDIR/pending.jsonl" ]
    assert [ ! -s "$HDIR/pending.jsonl" ]
    run grep -c '^## ' "$HDIR/queue.md"
    assert_output 0
    printf '{"version":1,"last_review_epoch":1}\n' >"$HDIR/state.json"
    printf 'x\n' >"$HDIR/pending.jsonl"
    run harness_health_bootstrap
    assert_success
    assert_equal "$(cat "$HDIR/state.json")" '{"version":1,"last_review_epoch":1}'
    assert_equal "$(cat "$HDIR/pending.jsonl")" 'x'
}

@test "heartbeat が新しければ ok で、OK の行に経過日数を出す" {
    weekly_installed
    heartbeat_days_ago 2
    run weekly
    assert_success
    assert_line "$(printf 'ok\tweekly job last succeeded 2d ago')"
    assert_line "$(printf 'summary\tweekly: 2d ago')"
    refute_line --regexp '^(warn|fail)'
}

@test "heartbeat が 1 周期(8 日)より古ければ fail で、対処を添える" {
    weekly_installed
    heartbeat_days_ago 8
    run weekly
    assert_success
    assert_line --regexp '^fail	weekly job last succeeded 8d ago — check ~/Library/Logs/harness-weekly\.log'
    assert_output --partial 'launchctl kickstart gui/$(id -u)/local.dotfiles.harness-weekly'
}

@test "heartbeat が 7 日前なら まだ ok" {
    weekly_installed
    heartbeat_days_ago 7
    run weekly
    assert_line "$(printf 'ok\tweekly job last succeeded 7d ago')"
}

@test "heartbeat が数値でなければ fail で、消して再実行するよう添える" {
    weekly_installed
    printf 'oops\n' >"$HDIR/weekly-heartbeat"
    run weekly
    assert_success
    assert_line --regexp "^fail	weekly-heartbeat is not a number — delete ${HDIR}/weekly-heartbeat and check "
    refute_line --regexp '^ok	weekly'
}

@test "heartbeat が先頭 0 付きでも 10 進数として判定する(8 進数として落ちない)" {
    weekly_installed
    printf '0899\n' >"$HDIR/weekly-heartbeat"
    run weekly
    assert_success
    assert_line --regexp '^fail	weekly job last succeeded [0-9]+d ago — '
}

@test "heartbeat が無く、plist を置いてから 1 周期経っていなければ ok(初回がまだ)で never と出す" {
    weekly_installed
    run weekly
    assert_success
    assert_line --regexp '^ok	weekly job has not run yet'
    assert_line "$(printf 'summary\tweekly: never')"
    refute_line --regexp '^(warn|fail)'
}

@test "heartbeat が無く、plist を置いてから 1 周期経っていれば fail" {
    weekly_installed
    touch -t 202001010000 "$PLIST"
    run weekly
    assert_success
    assert_line --regexp '^fail	weekly job has never succeeded since it was installed — check '
}

@test "plist があるのに入口スクリプトが無ければ fail" {
    weekly_installed
    rm "$HOME/.claude/scripts/harness-weekly.sh"
    heartbeat_days_ago 0
    run weekly
    assert_success
    assert_line --regexp "^fail	harness-weekly\.sh is not deployed or not executable — run 'chezmoi apply'"
}

@test "macOS で plist が無ければ warn で、chezmoi apply を案内する" {
    run weekly
    assert_success
    assert_output "$(printf "warn\tweekly job not installed (%s missing) — run 'chezmoi apply'" "$PLIST")"
}

@test "launchd の無い OS では plist が無ければ何も出さない" {
    stub_uname Linux
    heartbeat_days_ago 30
    run weekly
    assert_success
    assert_output ''
}

# 週次ジョブが Issue で知らせる停止の判定(#402)。送るのはジョブで、lib は判定だけを持つ

@test "前の成功が 1 周期(8 日)より古ければ、その日数を出す(次の run の起動時に、走らなかった週を知らせる)" {
    heartbeat_days_ago 9
    source "$LIB"
    run harness_health_missed_run_days
    assert_success
    assert_output 9
}

@test "前の成功が 7 日前なら、走らなかった週として出さない" {
    heartbeat_days_ago 7
    source "$LIB"
    run harness_health_missed_run_days
    assert_success
    assert_output ''
}

@test "heartbeat が無い・数値でないときは、走らなかった週として出さない(初回か、briefing が別に知らせる)" {
    source "$LIB"
    run harness_health_missed_run_days
    assert_success
    assert_output ''
    printf 'oops\n' >"$HDIR/weekly-heartbeat"
    run harness_health_missed_run_days
    assert_success
    assert_output ''
}

iso_days_ago() {
    jq -rn --argjson e "$(($(date +%s) - $1 * 86400))" '$e | todate'
}

@test "ループのブランチの PR のうち、作られてから 14 日以上経ったものを番号・URL・日数で出す" {
    source "$LIB"
    prs=$(jq -n --arg old "$(iso_days_ago 15)" --arg fresh "$(iso_days_ago 13)" '[
        {number: 1, url: "https://github.com/o/r/pull/1", headRefName: "harness/review-2026-09-01", createdAt: $old},
        {number: 2, url: "https://github.com/o/r/pull/2", headRefName: "harness/review-2026-09-03", createdAt: $fresh},
        {number: 3, url: "https://github.com/o/r/pull/3", headRefName: "feature/x", createdAt: $old}
    ]')
    run harness_health_stale_prs "$(date +%s)" harness/review- <<<"$prs"
    assert_success
    assert_output "$(printf '1\thttps://github.com/o/r/pull/1\t15')"
}

@test "放置された PR が無ければ何も出さない" {
    source "$LIB"
    run harness_health_stale_prs "$(date +%s)" harness/review- <<<'[]'
    assert_success
    assert_output ''
}

@test "PR の一覧が JSON として読めなければ失敗を返す" {
    source "$LIB"
    run harness_health_stale_prs "$(date +%s)" harness/review- <<<'not json'
    assert_failure
}

loop_repo() {
    export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
    export GIT_CONFIG_SYSTEM=/dev/null
    printf '[user]\n\tname = test\n\temail = test@example.com\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n' \
        >"$GIT_CONFIG_GLOBAL"
    REPO="$BATS_TEST_TMPDIR/repo"
    git init -q --bare "$BATS_TEST_TMPDIR/origin.git"
    git clone -q "$BATS_TEST_TMPDIR/origin.git" "$REPO" 2>/dev/null
    git -C "$REPO" commit -q --allow-empty -m init
    git -C "$REPO" push -q origin main
}


@test "ループのブランチのうち、基準日以前の日付で origin/main に無い commit を持つものを、ブランチ名と件数で出す" {
    loop_repo
    git -C "$REPO" switch -q -c harness/review-2026-09-01
    git -C "$REPO" commit -q --allow-empty -m a
    git -C "$REPO" commit -q --allow-empty -m b
    git -C "$REPO" switch -q -c harness/review-2026-09-08 main
    git -C "$REPO" switch -q -c harness/review-2026-09-15 main
    git -C "$REPO" commit -q --allow-empty -m today
    git -C "$REPO" switch -q -c harness/review-2026-09-09 main
    git -C "$REPO" commit -q --allow-empty -m yesterday-of-cutoff
    git -C "$REPO" switch -q -c harness/review-manual main
    git -C "$REPO" commit -q --allow-empty -m not-a-date
    git -C "$REPO" switch -q -c feature/x main
    git -C "$REPO" commit -q --allow-empty -m other
    source "$LIB"
    run harness_health_unpublished_loop_branches "$REPO" harness/review- 2026-09-08
    assert_success
    assert_output "$(printf 'harness/review-2026-09-01\t2')"
}

@test "origin/main が無ければ、判定できないので失敗を返す" {
    loop_repo
    git -C "$REPO" update-ref -d refs/remotes/origin/main
    source "$LIB"
    run harness_health_unpublished_loop_branches "$REPO" harness/review- 2026-09-08
    assert_failure
}
