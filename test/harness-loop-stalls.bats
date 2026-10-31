# 週次ジョブの Loop Stall(GLOSSARY.md)の module(lib/harness-loop-stalls.bash)の interface の検査。lib を直接 source する。
# 知らせる内容は、送る関数に渡されたタイトルと本文・返り値・ログの行で確かめる。送る関数は、受け取った引数を記録するだけの
# 関数を渡す(Issue の作成とタイトルでの重複の回避は入口スクリプトの alert_issue で、test/harness-weekly.bats が検査する)。
# gh は PATH 上の偽物で、開いている PR の一覧(STUB_GH_OPEN_PRS)とブランチごとの PR の件数(STUB_GH_BRANCH_PRS)だけを返す。
# git は実物で、origin は使い捨ての bare リポジトリにする。Integrity Snapshot の lib・Loop PR の module・Verdict の CLI は本物を使う。
# 週次ジョブがこの module を EXIT trap から 1 回だけ呼ぶこと、Loop PR の module を読めない run では呼ばないことは
# test/harness-weekly.bats が検査する。
setup() {
    load 'helpers/setup'
    unset STUB_GH_OPEN_PRS STUB_GH_BRANCH_PRS STUB_GH_LIST_FAIL STUB_GH_BRANCH_FAIL STUB_SEND_FAIL
    LIB_DIR="$BATS_TEST_DIRNAME/../dot_claude/scripts/lib"
    export HOME="$BATS_TEST_TMPDIR/home"
    HDIR="$HOME/.claude/harness"
    SCRIPTS="$HOME/.claude/scripts"
    mkdir -p "$HDIR" "$SCRIPTS"
    cp "$BATS_TEST_DIRNAME/../dot_claude/scripts/executable_harness-verdict.sh" "$SCRIPTS/harness-verdict.sh"

    export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
    export GIT_CONFIG_SYSTEM=/dev/null
    printf '[user]\n\tname = test\n\temail = test@example.com\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n' \
        >"$GIT_CONFIG_GLOBAL"
    # 本文のパスを ~ で書くことを確かめるため、リポジトリを HOME の下に置く(週次ジョブの既定の置き場所と同じ形)
    REPO="$HOME/repo"
    git init -q --bare "$BATS_TEST_TMPDIR/origin.git"
    git clone -q "$BATS_TEST_TMPDIR/origin.git" "$REPO" 2>/dev/null
    git -C "$REPO" commit -q --allow-empty -m init
    git -C "$REPO" push -q origin main

    export GH_LOG="$BATS_TEST_TMPDIR/gh.log"
    : >"$GH_LOG"
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat >"$BATS_TEST_TMPDIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
[[ "$1 $2" == "pr list" ]] || exit 98
if [[ "$*" == *--head* ]]; then
    [[ -z "${STUB_GH_BRANCH_FAIL:-}" ]] || exit 1
    printf '%s\n' "${STUB_GH_BRANCH_PRS-0}"
else
    [[ -z "${STUB_GH_LIST_FAIL:-}" ]] || exit 1
    printf '%s\n' "${STUB_GH_OPEN_PRS-[]}"
fi
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/gh"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

    export ALERT_TITLES="$BATS_TEST_TMPDIR/alert-titles.log"
    export ALERT_BODIES="$BATS_TEST_TMPDIR/alert-bodies.md"
    : >"$ALERT_TITLES"
    : >"$ALERT_BODIES"
    # 週次ジョブと同じく、Integrity Snapshot の lib、Loop PR の module、この module の順に読む
    # shellcheck source=../dot_claude/scripts/lib/harness-integrity.bash
    source "$LIB_DIR/harness-integrity.bash"
    # shellcheck source=../dot_claude/scripts/lib/harness-loop-pr.bash
    source "$LIB_DIR/harness-loop-pr.bash"
    # shellcheck source=../dot_claude/scripts/lib/harness-loop-stalls.bash
    source "$LIB_DIR/harness-loop-stalls.bash"
}

# 送る関数。タイトルと本文を記録し、STUB_SEND_FAIL があれば送れなかったとして 1 を返す
record_alert() { # <タイトル> <本文>
    printf '%s\n' "$1" >>"$ALERT_TITLES"
    printf '%s\n---\n' "$2" >>"$ALERT_BODIES"
    [[ -z "${STUB_SEND_FAIL:-}" ]]
}

report() {
    harness_loop_stalls_report "$REPO" harness/review- record_alert
}

iso_days_ago() {
    jq -rn --argjson e "$(($(date +%s) - $1 * 86400))" '$e | todate'
}

# 今日の <日数> 日前のローカルの日付
day_ago() {
    jq -rn --argjson e "$(($(date +%s) - $1 * 86400))" '$e | localtime | strftime("%Y-%m-%d")'
}

# origin/main に無い commit を <件数>(既定 1)持つブランチを作る
branch_ahead() { # <ブランチ> [<件数>]
    local i
    git -C "$REPO" switch -q -c "$1" main
    for ((i = 0; i < ${2:-1}; i++)); do
        git -C "$REPO" commit -q --allow-empty -m "commit $i"
    done
    git -C "$REPO" switch -q main
}

# ループのブランチの採用が PR にならないまま判定の記録に残っている
adopted_verdict() { # <ブランチ>
    printf -- '## [2026-01-01] old\n\n- **Verdict:** adopted (%s run old)\n' "$1" >"$HDIR/queue-archive.md"
}

# Verdict の CLI を、呼ばれたら印のファイルを残して何も返さない偽物に差し替える(採用を隠す書き換え)
hide_adoptions_in_verdict_cli() {
    cat >"$SCRIPTS/harness-verdict.sh" <<EOF
#!/usr/bin/env bash
touch "$BATS_TEST_TMPDIR/verdict-called"
exit 0
EOF
}

@test "Loop PR が 14 日以上開いたままなら、PR ごとにタイトルと対処を載せた本文を送る" {
    STUB_GH_OPEN_PRS=$(jq -n --arg old "$(iso_days_ago 15)" --arg fresh "$(iso_days_ago 13)" '[
        {number: 51, url: "https://github.com/example/dotfiles/pull/51", headRefName: "harness/review-2026-09-01", createdAt: $old},
        {number: 52, url: "https://github.com/example/dotfiles/pull/52", headRefName: "harness/review-2026-09-15", createdAt: $fresh},
        {number: 53, url: "https://github.com/example/dotfiles/pull/53", headRefName: "feature/x", createdAt: $old}
    ]')
    export STUB_GH_OPEN_PRS
    run report
    assert_success
    run cat "$GH_LOG"
    assert_line 'pr list --state open --limit 100 --json number,url,headRefName,createdAt'
    run cat "$ALERT_TITLES"
    assert_output 'harness: ループの PR #51 が 14 日以上放置されている'
    run cat "$ALERT_BODIES"
    assert_output --partial 'ループの PR https://github.com/example/dotfiles/pull/51 が作られてから 15 日、マージもクローズもされていない。'
    assert_output --partial 'draft なら `gh pr ready 51` で draft を外してから、マージする'
    assert_output --partial '`gh pr close 51` で閉じる'
}

@test "放置された Loop PR もループのブランチも無ければ、何も送らずに 0 を返す" {
    run report
    assert_success
    assert_output ''
    run cat "$ALERT_TITLES"
    assert_output ''
}

@test "開いている PR の一覧を取れなければ、WARN を出して 1 を返し、ループのブランチは見る" {
    branch_ahead "harness/review-$(day_ago 8)"
    STUB_GH_LIST_FAIL=1 run report
    assert_failure 1
    assert_output --partial 'harness-weekly: WARN could not list the open PRs to find loop PRs left for 14 days'
    run cat "$ALERT_TITLES"
    assert_output "harness: ループのブランチ harness/review-$(day_ago 8) が PR になっていない"
}

@test "開いている PR の一覧が JSON として読めなければ、WARN を出して 1 を返す" {
    STUB_GH_OPEN_PRS='not json' run report
    assert_failure 1
    assert_output --partial 'harness-weekly: WARN could not list the open PRs to find loop PRs left for 14 days'
}

@test "送る関数が失敗したら 1 を返す" {
    STUB_GH_OPEN_PRS=$(jq -n --arg old "$(iso_days_ago 15)" '[
        {number: 51, url: "https://github.com/example/dotfiles/pull/51", headRefName: "harness/review-2026-09-01", createdAt: $old}
    ]')
    export STUB_GH_OPEN_PRS
    STUB_SEND_FAIL=1 run report
    assert_failure 1
    run cat "$ALERT_TITLES"
    assert_output 'harness: ループの PR #51 が 14 日以上放置されている'
}

@test "PR にならないまま origin/main に無い commit を持つ、7 日以上前のループのブランチは、~ で書いた公開と削除の手順を送る" {
    branch=harness/review-$(day_ago 8)
    branch_ahead "$branch" 2
    harness_integrity_snapshot
    run report
    assert_success
    run cat "$GH_LOG"
    assert_line "pr list --head $branch --state all --json number --jq length"
    run cat "$ALERT_TITLES"
    assert_output "harness: ループのブランチ $branch が PR になっていない"
    run cat "$ALERT_BODIES"
    assert_line "ループのブランチ \`$branch\` が、PR にならないまま \`~/repo\` に残っている(origin/main に無い commit: 2 件)。週次ジョブはこのブランチを公開しない。"
    assert_line "- 公開する: \`git -C ~/repo push origin $branch\` の後に、\`~/repo\` で \`gh pr create --draft --base main --head $branch\`"
    assert_line "- 要らなければ消す: \`git -C ~/repo branch -D $branch\`"
    refute_output --partial 'Verdict CLI'
    refute_output --partial "$HOME"
}

@test "基準日(今日の 7 日前)以前の日付のブランチだけを見て、日付で終わらない名前・ほかの prefix・commit の無いブランチは照会しない" {
    branch_ahead "harness/review-$(day_ago 7)"
    branch_ahead "harness/review-$(day_ago 6)"
    branch_ahead "harness/review-$(day_ago 0)-x"
    branch_ahead harness/review-manual
    branch_ahead "feature/$(day_ago 30)"
    git -C "$REPO" branch "harness/review-$(day_ago 9)" main
    harness_integrity_snapshot
    run report
    assert_success
    run grep -c -- '--head' "$GH_LOG"
    assert_output 1
    run cat "$ALERT_TITLES"
    assert_output "harness: ループのブランチ harness/review-$(day_ago 7) が PR になっていない"
}

@test "ループのブランチに PR があれば(手動の review や squash マージ)送らず、消し方をログに出す" {
    branch=harness/review-$(day_ago 8)
    branch_ahead "$branch"
    harness_integrity_snapshot
    STUB_GH_BRANCH_PRS=1 run report
    assert_success
    assert_output --partial "harness-weekly: $branch already has a PR; delete it with git -C $REPO branch -D $branch to stop checking it"
    run cat "$ALERT_TITLES"
    assert_output ''
}

@test "Verdict の CLI に PR になっていない採用が残るブランチは、失敗の Issue が知らせるので PR を照会せず送らない" {
    branch=harness/review-$(day_ago 8)
    branch_ahead "$branch"
    adopted_verdict "$branch"
    harness_integrity_snapshot
    run report
    assert_success
    assert_output --partial "harness-weekly: $branch has an adopted verdict in $HDIR/queue-archive.md; the failure issue reports it"
    run cat "$GH_LOG"
    refute_line --partial '--head'
    run cat "$ALERT_TITLES"
    assert_output ''
}

@test "スナップショットの後に Verdict の CLI が書き換えられた run では、CLI を呼ばずに、信頼できなかったと書いて送る" {
    branch=harness/review-$(day_ago 8)
    branch_ahead "$branch"
    adopted_verdict "$branch"
    harness_integrity_snapshot
    hide_adoptions_in_verdict_cli
    run report
    assert_success
    assert [ ! -e "$BATS_TEST_TMPDIR/verdict-called" ]
    refute_output --partial 'has an adopted verdict'
    run cat "$ALERT_TITLES"
    assert_output "harness: ループのブランチ $branch が PR になっていない"
    run cat "$ALERT_BODIES"
    assert_output --partial 'Verdict CLI を信頼できなかった(claude の起動後に週次ジョブが使うスクリプトが書き換えられていた。ログの `harness-integrity:` の行を参照)ため、このブランチに PR になっていない採用が残っているかは確かめていない。'
}

@test "スナップショットの前に止まった run では、CLI を呼ばずに、確かめられなかったと書いて送る" {
    branch=harness/review-$(day_ago 8)
    branch_ahead "$branch"
    adopted_verdict "$branch"
    hide_adoptions_in_verdict_cli
    run report
    assert_success
    assert [ ! -e "$BATS_TEST_TMPDIR/verdict-called" ]
    run cat "$ALERT_TITLES"
    assert_output "harness: ループのブランチ $branch が PR になっていない"
    run cat "$ALERT_BODIES"
    assert_output --partial 'Verdict CLI を確かめられなかった(この run は改ざんの検出の準備の前に止まった)ため、このブランチに PR になっていない採用が残っているかは確かめていない。'
    refute_output --partial 'Verdict CLI を信頼できなかった'
}

@test "Verdict の CLI が失敗したら、そのブランチは送らずに WARN を出して 1 を返す" {
    branch=harness/review-$(day_ago 8)
    branch_ahead "$branch"
    cat >"$SCRIPTS/harness-verdict.sh" <<'EOF'
#!/usr/bin/env bash
exit 2
EOF
    harness_integrity_snapshot
    run report
    assert_failure 1
    assert_output --partial "harness-weekly: WARN could not read the unpublished verdicts of $branch from $HDIR/queue-archive.md"
    run cat "$ALERT_TITLES"
    assert_output ''
}

@test "ブランチの PR の有無を照会できなければ、そのブランチは送らずに WARN を出して 1 を返す" {
    branch=harness/review-$(day_ago 8)
    branch_ahead "$branch"
    harness_integrity_snapshot
    STUB_GH_BRANCH_FAIL=1 run report
    assert_failure 1
    assert_output --partial "harness-weekly: WARN could not check whether $branch has a PR"
    run cat "$ALERT_TITLES"
    assert_output ''
}

@test "手で公開するコマンドの綴りを Loop PR の module から受け取れなければ、手順が空の本文を送らずに WARN を出して 1 を返す" {
    branch=harness/review-$(day_ago 8)
    branch_ahead "$branch"
    harness_integrity_snapshot
    harness_loop_pr_push_command() { return 1; }
    run report
    assert_failure 1
    assert_output --partial "harness-weekly: WARN could not build the issue for $branch"
    run cat "$ALERT_TITLES"
    assert_output ''
}

@test "origin/main が無ければ、ループのブランチを判定できないので WARN を出して 1 を返す" {
    branch_ahead "harness/review-$(day_ago 8)"
    git -C "$REPO" update-ref -d refs/remotes/origin/main
    run report
    assert_failure 1
    assert_output --partial "harness-weekly: WARN could not list the loop branches in $REPO (is origin/main fetched?)"
    run cat "$ALERT_TITLES"
    assert_output ''
}

@test "date が失敗したら、基準日を作れないので放置された PR もループのブランチも WARN を出して 1 を返す" {
    branch_ahead "harness/review-$(day_ago 8)"
    cat >"$BATS_TEST_TMPDIR/bin/date" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/date"
    run report
    assert_failure 1
    assert_output --partial 'harness-weekly: WARN could not read the current time to find loop PRs left for 14 days'
    assert_output --partial "harness-weekly: WARN could not compute the cutoff date to find the loop branches in $REPO"
    run cat "$GH_LOG"
    assert_output ''
    run cat "$ALERT_TITLES"
    assert_output ''
}

@test "この lib とその bats は Guarded Path に載っている" {
    run bash "$BATS_TEST_DIRNAME/../scripts/check-guarded-paths.sh" --uncovered "$BATS_TEST_DIRNAME/../scripts/guarded-paths.txt" \
        dot_claude/scripts/lib/harness-loop-stalls.bash test/harness-loop-stalls.bats
    assert_success
    assert_output ''
}
