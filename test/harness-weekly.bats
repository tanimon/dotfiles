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
# cwd(ジョブが用意した worktree)で STUB_REVIEW_MODE に応じた変更と commit を行う。
# git は実物を使い、origin は使い捨ての bare リポジトリにする。GIT_CONFIG_GLOBAL /
# GIT_CONFIG_SYSTEM を潰すのは、このマシンの署名や push の設定を持ち込まないため。
# gh と pnpm はスタブで、gh は呼ばれた引数と --body-file の中身を記録する。
setup() {
    load 'helpers/setup'
    load 'helpers/exec-cache'
    # スクリプトが読む環境変数を、このマシンのシェルから漏らさない
    unset HARNESS_DISABLE HARNESS_WEEKLY_BUDGET_USD HARNESS_WEEKLY_MAX_SESSIONS \
        HARNESS_WEEKLY_REVIEW_BUDGET_USD HARNESS_WEEKLY_REPO
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
    export PNPM_LOG="$BATS_TEST_TMPDIR/pnpm.log"

    export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
    export GIT_CONFIG_SYSTEM=/dev/null
    printf '[user]\n\tname = test\n\temail = test@example.com\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n' \
        >"$GIT_CONFIG_GLOBAL"
    ORIGIN="$BATS_TEST_TMPDIR/origin.git"
    export HARNESS_WEEKLY_REPO="$BATS_TEST_TMPDIR/repo"
    git init -q --bare "$ORIGIN"
    git clone -q "$ORIGIN" "$HARNESS_WEEKLY_REPO" 2>/dev/null
    printf 'line1\nline2\n' >"$HARNESS_WEEKLY_REPO/README.md"
    git -C "$HARNESS_WEEKLY_REPO" add README.md
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
sid=""
while [[ $# -gt 0 ]]; do
    [[ "$1" == "--session-id" ]] && sid="$2"
    shift
done
if [[ "$all_args" == *'harness-review skill'* ]]; then
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
    archive="$HOME/.claude/harness/queue-archive.md"
    branch=$(git branch --show-current)
    adopt() {
        mkdir -p rules && printf 'a\nb\nc\n' >rules/new.md && printf 'keep\n' >README.md
        git add -A && git commit -qm 'harness: add rule'
    }
    case "${STUB_REVIEW_MODE:-adopt}" in
    adopt)
        adopt
        printf '## 採用した変更\n\n- 理由: 同じ失敗の再発を防ぐため\n' >"$body"
        # 記録の書式はプロンプトが指定したものをそのまま使う(run ごとの印を含む)
        verdict=$(grep -oE 'adopted \(harness/review-[^)]*\)' <<<"$all_args" | head -n 1)
        printf -- '- **Verdict:** %s\n' "$verdict" >>"$archive"
        ;;
    no_verdict)
        adopt
        printf 'reason\n' >"$body"
        ;;
    binary_pipe)
        printf 'a\0b' >blob.bin && printf 'x\n' >'a|b.md'
        git add -A && git commit -qm 'harness: binary and pipe'
        printf 'reason\n' >"$body"
        ;;
    two_changes)
        # 採用 2 件が同じファイルに触れる(ファイルごとの表では変更ごとの純増が読めない形)
        mkdir -p rules && printf 'a\nb\n' >rules/shared.md
        git add -A && git commit -qm 'harness: first | entry'
        printf 'a\nb\nc\nd\ne\n' >rules/shared.md && printf 'keep\n' >README.md
        git add -A && git commit -qm 'harness: second entry'
        printf 'reason\n' >"$body"
        ;;
    no_body) adopt ;;
    body_only) printf 'reason\n' >"$body" ;;
    dirty) printf 'x\n' >stray.md ;;
    none) ;;
    esac
else
    printf 'reflect\n' >>"$STAGE_LOG"
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
    install_exec "$STUBS/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
if [[ "$1 $2" == "pr list" ]]; then
    printf '%s\n' "${STUB_GH_PR_LIST-https://github.com/example/dotfiles/pull/41}"
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
    # pending が空の週は claude を起動しないので、既定では処理対象を 1 件置く。transcript が無いので
    # 選別は検出器にかけずに残す
    printf '{"session_id":"seed","transcript_path":"/tmp/s","cwd":"/tmp","recorded_epoch":1}\n' >"$HDIR/pending.jsonl"
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
    before=$(date +%s)
    run weekly
    assert_success
    assert [ -f "$HDIR/weekly-heartbeat" ]
    hb=$(cat "$HDIR/weekly-heartbeat")
    assert [ "$hb" -ge "$before" ]
}

@test "claude が非 0 で終わると失敗し、heartbeat を書き換えない" {
    printf '100\n' >"$HDIR/weekly-heartbeat"
    STUB_CLAUDE_MODE=exit1 run weekly
    assert_failure
    assert_equal "$(cat "$HDIR/weekly-heartbeat")" "100"
}

@test "結果が is_error なら exit 0 でも失敗とし、heartbeat を書かない" {
    STUB_CLAUDE_MODE=is_error run weekly
    assert_failure
    assert [ ! -f "$HDIR/weekly-heartbeat" ]
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
    assert [ ! -f "$HDIR/weekly-heartbeat" ]
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
    assert [ ! -f "$HDIR/weekly-heartbeat" ]
}

@test "止まった実行が残した lock は取り戻して実行する" {
    bash -c 'exit 0' &
    dead=$!
    wait "$dead"
    mkdir -p "$HDIR/weekly.lock"
    printf '%s\n' "$dead" >"$HDIR/weekly.lock/pid"
    run weekly
    assert_success
    assert [ -f "$HDIR/weekly-heartbeat" ]
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
    assert [ -f "$HDIR/weekly-heartbeat" ]
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
    assert [ -f "$HDIR/weekly-heartbeat" ]
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
    run git -C "$ORIGIN" log --format=%s -1 "$BRANCH"
    assert_output 'harness: add rule'
    assert [ -f "$HDIR/weekly-heartbeat" ]
}

@test "PR の本文に採用の理由と、追加・削除・純増の行数が載る" {
    seed_queue
    run weekly
    assert_success
    run cat "$GH_BODY"
    assert_output --partial '理由: 同じ失敗の再発を防ぐため'
    assert_output --partial '## 純増'
    assert_output --partial '| `rules/new.md` | +3 | -0 |'
    assert_output --partial '| `README.md` | +1 | -2 |'
    assert_output --partial '合計: +4 / -2(純増 +2 行)'
    assert_output --partial '| harness: add rule | +4 | -2 |'
}

@test "同じファイルに触れる採用が複数あっても、純増を変更(commit)ごとに載せる" {
    seed_queue
    STUB_REVIEW_MODE=two_changes run weekly
    assert_success
    run cat "$GH_BODY"
    assert_output --partial '| harness: first \| entry | +2 | -0 |'
    assert_output --partial '| harness: second entry | +4 | -2 |'
    assert_output --partial '| `rules/shared.md` | +5 | -0 |'
    assert_output --partial '合計: +6 / -2(純増 +4 行)'
}

@test "採用した変更が無ければ PR を作らず、その旨をログに残す" {
    seed_queue
    STUB_REVIEW_MODE=none run weekly
    assert_success
    assert_output --partial 'review committed no changes; no PR created'
    assert [ ! -f "$GH_LOG" ]
    assert [ -f "$HDIR/weekly-heartbeat" ]
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

@test "判定の記録の adopted (<ブランチ>) を PR の URL に置き換える" {
    seed_queue
    run weekly
    assert_success
    run cat "$HDIR/queue-archive.md"
    assert_output '- **Verdict:** adopted (PR https://github.com/example/dotfiles/pull/42)'
}

@test "同じ日の前の run が残した採用は今回の PR の URL に置き換えず、heartbeat を書かずに知らせる" {
    printf -- '- **Verdict:** adopted (%s)\n' "$BRANCH" >"$HDIR/queue-archive.md"
    seed_queue
    run weekly
    assert_failure
    assert_output --partial "never became a PR: adopted (${BRANCH})"
    run grep -cF "adopted (${BRANCH})" "$HDIR/queue-archive.md"
    assert_output '1'
    run grep -c 'adopted (PR https://github.com/example/dotfiles/pull/42)' "$HDIR/queue-archive.md"
    assert_output '1'
    assert [ ! -f "$HDIR/weekly-heartbeat" ]
}

@test "判定の記録にブランチ名が無ければ、URL を記録できなかったことを、陳腐化の修正だけなら正常と添えて残す" {
    seed_queue
    STUB_REVIEW_MODE=no_verdict run weekly
    assert_success
    assert_output --partial 'PR URL not recorded'
    assert_output --partial 'normal if the PR only fixes stale rules'
    refute_output --partial 'WARN'
}

@test "バイナリファイルは行数の代わりにバイナリと書き、パスの | はエスケープする" {
    seed_queue
    STUB_REVIEW_MODE=binary_pipe run weekly
    assert_success
    run cat "$GH_BODY"
    assert_output --partial '| `blob.bin` | バイナリ | バイナリ |'
    assert_output --partial '| `a\|b.md` | +1 | -0 |'
    assert_output --partial '合計: +1 / -0(純増 +1 行)'
    assert_output --partial 'バイナリファイル 1 件は行数に含めない'
}

@test "PR を作れたら本文のファイルを消し、作れなかったら残す" {
    seed_queue
    run weekly
    assert_success
    assert [ ! -f "$HDIR/review-pr-body-$(date +%Y-%m-%d).md" ]
    # origin にあるのでローカルのブランチは消す
    run git -C "$HARNESS_WEEKLY_REPO" rev-parse --verify --quiet "refs/heads/$BRANCH"
    assert_failure
    seed_queue
    rm -f "$GH_LOG"
    git -C "$ORIGIN" branch -D "$BRANCH" >/dev/null
    STUB_GH_FAIL=1 run weekly
    assert_failure
    assert [ -s "$HDIR/review-pr-body-$(date +%Y-%m-%d).md" ]
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
    run git -C "$WT" log --format=%s -1
    assert_output 'harness: add rule'
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
    assert [ ! -f "$HDIR/weekly-heartbeat" ]
}

@test "commit が無く落とした変更があれば、採用なしと扱わずに失敗し heartbeat を書かない" {
    seed_queue
    STUB_REVIEW_MODE=none STUB_RESULT='{"dropped":["harness: add rule(shellcheck で失敗)"],"deploy_only":[]}' run weekly
    assert_failure
    assert_output --partial 'dropped 1 change(s)'
    assert_output --partial 'harness: add rule(shellcheck で失敗)'
    refute_output --partial 'committed no changes'
    assert [ ! -f "$GH_LOG" ]
    assert [ ! -f "$HDIR/weekly-heartbeat" ]
    # 調べられるように結果ファイルを残す
    assert [ -s "$HDIR/review-result-$(date +%Y-%m-%d).json" ]
}

@test "commit が無く落とした変更も無ければ、本文があっても PR を作らずに成功する" {
    seed_queue
    STUB_REVIEW_MODE=body_only run weekly
    assert_success
    assert_output --partial 'review committed no changes; no PR created'
    assert [ ! -f "$GH_LOG" ]
    assert [ -f "$HDIR/weekly-heartbeat" ]
    # 日付付きのファイルが週ごとに溜まらない
    assert [ ! -f "$HDIR/review-pr-body-$(date +%Y-%m-%d).md" ]
    assert [ ! -f "$HDIR/review-result-$(date +%Y-%m-%d).json" ]
}

@test "commit が無く deploy-only の修正だけなら成功し、deploy-only.md に残してブリーフィングが警告する" {
    seed_queue
    STUB_REVIEW_MODE=none STUB_RESULT='{"dropped":[],"deploy_only":["~/.claude/settings.json が古い: chezmoi apply で適用する"]}' run weekly
    assert_success
    assert [ ! -f "$GH_LOG" ]
    assert [ -f "$HDIR/weekly-heartbeat" ]
    run cat "$HDIR/deploy-only.md"
    assert_output --partial "## $(date +%Y-%m-%d)"
    assert_output --partial '- ~/.claude/settings.json が古い: chezmoi apply で適用する'
    run bash "$BATS_TEST_DIRNAME/../dot_claude/scripts/executable_harness-briefing.sh"
    assert_output --partial 'ATTENTION'
    assert_output --partial 'deploy-only fix'
    assert_output --partial "$HDIR/deploy-only.md"
}

@test "commit があり落とした変更もあれば PR を作り、本文にジョブが作った落とした変更の節が入る" {
    seed_queue
    STUB_RESULT='{"dropped":["harness: other entry(just lint の oxfmt で失敗)"],"deploy_only":[]}' run weekly
    assert_success
    run cat "$GH_LOG"
    assert_output --regexp "^pr create --draft --base main --head ${BRANCH} "
    run cat "$GH_BODY"
    assert_output --partial '## 落とした変更'
    assert_output --partial '- harness: other entry(just lint の oxfmt で失敗)'
    refute_output --partial '## deploy-only の修正'
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

@test "失敗する run でも deploy-only の修正は deploy-only.md に残す" {
    seed_queue
    STUB_REVIEW_MODE=none STUB_RESULT='{"dropped":["x(prek で失敗)"],"deploy_only":["y を適用する"]}' run weekly
    assert_failure
    run cat "$HDIR/deploy-only.md"
    assert_output --partial '- y を適用する'
}

@test "deploy-only.md には週ごとに追記し、前の記録を消さない" {
    printf '## 2026-01-01\n\n- old fix\n' >"$HDIR/deploy-only.md"
    seed_queue
    STUB_REVIEW_MODE=none STUB_RESULT='{"dropped":[],"deploy_only":["new fix"]}' run weekly
    assert_success
    run cat "$HDIR/deploy-only.md"
    assert_output --partial '- old fix'
    assert_output --partial '- new fix'
}

@test "結果ファイルが無ければ、commit が無くても採用なしと扱わずに失敗する" {
    seed_queue
    STUB_REVIEW_MODE=none STUB_RESULT=missing run weekly
    assert_failure
    assert_output --partial 'review-result-'
    refute_output --partial 'committed no changes'
    assert [ ! -f "$HDIR/weekly-heartbeat" ]
}

@test "同じ日の前の run が残した結果ファイルを今回の結果として読まない" {
    printf '{"dropped":[],"deploy_only":[]}\n' >"$HDIR/review-result-$(date +%Y-%m-%d).json"
    seed_queue
    STUB_REVIEW_MODE=none STUB_RESULT=missing run weekly
    assert_failure
    assert_output --partial 'did not write a valid result file'
    assert [ ! -f "$HDIR/weekly-heartbeat" ]
}

@test "commit されていない変更を残した run でも deploy-only の修正は deploy-only.md に残す" {
    seed_queue
    STUB_REVIEW_MODE=dirty STUB_RESULT='{"dropped":[],"deploy_only":["z を適用する"]}' run weekly
    assert_failure
    assert_output --partial 'uncommitted changes'
    run cat "$HDIR/deploy-only.md"
    assert_output --partial '- z を適用する'
}

@test "同じ deploy-only の修正を再び報告されても deploy-only.md に二重に足さない" {
    printf '## 2026-01-01\n\n- same fix\n' >"$HDIR/deploy-only.md"
    seed_queue
    STUB_REVIEW_MODE=none STUB_RESULT='{"dropped":[],"deploy_only":["same fix","other fix"]}' run weekly
    assert_success
    run grep -c '^- same fix$' "$HDIR/deploy-only.md"
    assert_output '1'
    run grep -c '^- other fix$' "$HDIR/deploy-only.md"
    assert_output '1'
}

@test "同じ結果ファイルの中で重なった deploy-only の修正も deploy-only.md に二重に足さない" {
    seed_queue
    STUB_REVIEW_MODE=none STUB_RESULT='{"dropped":[],"deploy_only":["dup fix","dup fix"]}' run weekly
    assert_success
    run grep -c '^- dup fix$' "$HDIR/deploy-only.md"
    assert_output '1'
}

@test "空や空白だけの要素は数えず、箇条書きの印を二重にしない" {
    seed_queue
    STUB_REVIEW_MODE=none STUB_RESULT='{"dropped":["", "  ", "- "],"deploy_only":["", " - bullet fix ", "* star fix"]}' run weekly
    # dropped が中身の無い要素だけなら、commit 0 件の週を失敗にしない
    assert_success
    assert_output --partial 'review committed no changes; no PR created'
    run cat "$HDIR/deploy-only.md"
    assert_line '- bullet fix'
    assert_line '- star fix'
    refute_line '- '
    refute_output --partial '- - '
    # 件数は中身のある要素だけを数える
    run bash "$BATS_TEST_DIRNAME/../dot_claude/scripts/executable_harness-briefing.sh"
    assert_output --partial '(2)'
}

@test "中身のある落とした変更が 1 つでもあれば、空の要素と混ざっていても失敗する" {
    seed_queue
    STUB_REVIEW_MODE=none STUB_RESULT='{"dropped":["", "x(prek で失敗)"],"deploy_only":[]}' run weekly
    assert_failure
    assert_output --partial 'dropped 1 change(s)'
}

@test "選別の claude が結果ファイルを書いた後に失敗しても、deploy-only の修正は deploy-only.md に残す" {
    : >"$HDIR/pending.jsonl"
    seed_queue
    STUB_CLAUDE_MODE=is_error STUB_RESULT='{"dropped":[],"deploy_only":["w を適用する"]}' run weekly
    assert_failure
    assert_output --partial 'review failed after'
    run cat "$HDIR/deploy-only.md"
    assert_output --partial '- w を適用する'
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

@test "同じ日に deploy-only の修正が加わっても、日付の見出しを重ねない" {
    printf '## %s\n\n- first fix\n\n' "$(date +%Y-%m-%d)" >"$HDIR/deploy-only.md"
    seed_queue
    STUB_REVIEW_MODE=none STUB_RESULT='{"dropped":[],"deploy_only":["second fix"]}' run weekly
    assert_success
    run grep -c "^## $(date +%Y-%m-%d)\$" "$HDIR/deploy-only.md"
    assert_output '1'
    run grep -c '^- second fix$' "$HDIR/deploy-only.md"
    assert_output '1'
}

@test "選別の claude が結果ファイルを書かずに失敗したら、deploy-only.md を作らない" {
    : >"$HDIR/pending.jsonl"
    seed_queue
    STUB_CLAUDE_MODE=is_error STUB_RESULT=missing run weekly
    assert_failure
    assert [ ! -f "$HDIR/deploy-only.md" ]
    refute_output --partial 'failed to record deploy-only'
}

@test "結果ファイルが JSON として読めないか、決めた形でなければ失敗する" {
    for broken in 'not json' '' '{}' '{"dropped":[]}' '{"dropped":"x","deploy_only":[]}' '{"dropped":[1],"deploy_only":[]}' '[]'; do
        rm -f "$HDIR/weekly-heartbeat"
        seed_queue
        STUB_REVIEW_MODE=none STUB_RESULT="$broken" run weekly
        assert_failure
        assert_output --partial 'review-result-'
        assert [ ! -f "$HDIR/weekly-heartbeat" ]
    done
}

@test "commit があっても結果ファイルが無ければ PR を作らずに失敗する" {
    seed_queue
    STUB_RESULT=missing run weekly
    assert_failure
    assert [ ! -f "$GH_LOG" ]
}

@test "commit があるのに本文が無ければ PR を作らずに失敗する" {
    seed_queue
    STUB_REVIEW_MODE=no_body run weekly
    assert_failure
    assert_output --partial 'no PR body'
    assert [ ! -f "$GH_LOG" ]
}

@test "push 後に PR の作成が失敗したら、ブランチ名を添えて失敗する" {
    seed_queue
    STUB_GH_FAIL=1 run weekly
    assert_failure
    assert_output --partial "pushed ${BRANCH} but gh pr create failed"
    assert_output --partial "still say adopted (${BRANCH} run aaaaaaaa-0000-0000-0000-000000000001)"
    assert [ ! -f "$HDIR/weekly-heartbeat" ]
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
    assert [ ! -f "$HDIR/weekly-heartbeat" ]
}

@test "前の run の採用が PR にならないまま判定の記録に残っていれば、heartbeat を書かずに失敗する" {
    printf -- '- **Verdict:** adopted (harness/review-2026-01-01)\n' >"$HDIR/queue-archive.md"
    run weekly
    assert_failure
    assert_output --partial 'never became a PR: adopted (harness/review-2026-01-01)'
    assert [ ! -f "$HDIR/weekly-heartbeat" ]
}

@test "判定の記録の採用がすべて PR の URL になっていれば heartbeat を書く" {
    printf -- '- **Verdict:** adopted (PR https://github.com/example/dotfiles/pull/1)\n' >"$HDIR/queue-archive.md"
    run weekly
    assert_success
    assert [ -f "$HDIR/weekly-heartbeat" ]
}

@test "前の run の採用の残りは、その週の選別と PR の作成を済ませてから知らせる" {
    printf -- '- **Verdict:** adopted (harness/review-2026-01-01)\n' >"$HDIR/queue-archive.md"
    seed_queue
    run weekly
    assert_failure
    assert_output --partial 'never became a PR'
    run cat "$GH_LOG"
    assert_output --regexp "^pr create --draft --base main --head ${BRANCH} "
    run grep -c 'adopted (PR https://github.com/example/dotfiles/pull/42)' "$HDIR/queue-archive.md"
    assert_output '1'
    assert [ ! -f "$HDIR/weekly-heartbeat" ]
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
    assert [ -f "$HDIR/weekly-heartbeat" ]
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
    assert [ ! -f "$HDIR/weekly-heartbeat" ]
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
    assert_output --partial 'Do not write line counts, failure detection counts, dropped changes or deploy-only fixes in the PR body'
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
    assert_output --partial 'harness-select-pending: scanned=2 selected=1 dropped=1 not_scanned=0'
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
    assert [ -f "$HDIR/weekly-heartbeat" ]
}

@test "選別が失敗したら抽出に進まずに失敗する" {
    rm "$HOME/.claude/scripts/harness-detect-failures.sh"
    run weekly
    assert_failure
    assert_output --partial 'selecting pending sessions with'
    assert [ ! -f "$ARGV_LOG" ]
    assert [ ! -f "$HDIR/weekly-heartbeat" ]
}

@test "PR の本文にこの run の信号別の検出件数を載せ、前の run の記録は数えない" {
    : >"$HDIR/pending.jsonl"
    printf '{"session_id":"old","run":"earlier-run","date":"2026-01-01","counts":{"tool_error":9}}\n' \
        >"$HDIR/detections.jsonl"
    add_session clean1 clean
    add_session err1 tool-error
    add_session ci1 ci-failure
    seed_queue
    run weekly
    assert_success
    run cat "$GH_BODY"
    assert_output --partial '## 失敗の検出'
    assert_output --partial 'この run で検出器にかけたセッション: 3 件(失敗あり 2 件)。'
    assert_line '| `tool_error` | 3 |'
    assert_line '| `ci_failure` | 2 |'
    assert_line '| `user_negation` | 0 |'
    assert_line '| `repeat` | 0 |'
    assert_line '| 合計 | 5 |'
}

@test "抽出を省いた週の PR の本文にも 0 件の検出の節を載せる" {
    : >"$HDIR/pending.jsonl"
    seed_queue
    run weekly
    assert_success
    run cat "$GH_BODY"
    assert_output --partial 'この run で検出器にかけたセッション: 0 件(失敗あり 0 件)。'
    assert_line '| 合計 | 0 |'
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
