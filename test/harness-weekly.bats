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

    cat >"$STUBS/nono" <<'EOF'
#!/usr/bin/env bash
printf 'nono' >>"$ARGV_LOG"
printf ' %s' "$@" >>"$ARGV_LOG"
printf '\n' >>"$ARGV_LOG"
exit 99
EOF
    cat >"$STUBS/claude" <<'EOF'
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
    body="$HOME/.claude/harness/review-pr-body.md"
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
        printf -- '- **Verdict:** adopted (%s)\n' "$branch" >>"$archive"
        ;;
    no_verdict)
        adopt
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
    cat >"$STUBS/uuidgen" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${STUB_UUID:-AAAAAAAA-0000-0000-0000-000000000001}"
EOF
    cat >"$STUBS/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
while [[ $# -gt 0 ]]; do
    [[ "$1" == "--body-file" ]] && cp "$2" "$GH_BODY"
    shift
done
[[ -z "${STUB_GH_FAIL:-}" ]] || exit 1
printf 'https://github.com/example/dotfiles/pull/42\n'
EOF
    cat >"$STUBS/pnpm" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "$(pwd)" "$*" >>"$PNPM_LOG"
[[ -z "${STUB_PNPM_FAIL:-}" ]]
EOF
    chmod +x "$STUBS"/*
    export PATH="$STUBS:$PATH"
    # pending が空の週は claude を起動しないので、既定では処理対象を 1 件置く
    printf '{"session_id":"seed","transcript_path":"/tmp/s","cwd":"/tmp","recorded_epoch":1}\n' >"$HDIR/pending.jsonl"
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
}

@test "採用した変更が無ければ PR を作らず、その旨をログに残す" {
    seed_queue
    STUB_REVIEW_MODE=none run weekly
    assert_success
    assert_output --partial 'review adopted no changes; no PR created'
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

@test "判定の記録にブランチ名が無ければ、URL を記録できなかったと警告する" {
    seed_queue
    STUB_REVIEW_MODE=no_verdict run weekly
    assert_success
    assert_output --partial 'WARN'
    assert_output --partial 'PR URL not recorded'
}

@test "commit されていない変更が残っていたら PR を作らずに失敗する" {
    seed_queue
    STUB_REVIEW_MODE=dirty run weekly
    assert_failure
    assert_output --partial 'uncommitted changes'
    assert [ ! -f "$GH_LOG" ]
    assert [ ! -f "$HDIR/weekly-heartbeat" ]
}

@test "本文があるのに commit が無ければ、採用なしと扱わずに失敗する" {
    seed_queue
    STUB_REVIEW_MODE=body_only run weekly
    assert_failure
    assert_output --partial 'no commits'
    refute_output --partial 'adopted no changes'
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
