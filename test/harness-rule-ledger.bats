# Rule Ledger(harness-rule-ledger.sh)の振る舞い検査。
#
# 偽の $HOME に判定の記録(queue-archive.md)・分類の記録(classifications.jsonl)・評価の結果を置き、
# ローカルの記録(~/.claude/harness/rule-ledger/<id>.json)、移行、リポジトリへの書き出し、形式の検査を確かめる。
# gh は PR の作成日を返すスタブにする。
bats_require_minimum_version 1.5.0

setup() {
    load 'helpers/setup'
    unset SENSITIVE_WORK_ORG SENSITIVE_LOCAL_USER SENSITIVE_PATTERNS_LOCAL RULE_LEDGER_WORK_REPOS
    # 移行は PR の作成時刻をローカルの日付にする。テストの期待値をマシンの TZ に依らせない
    export TZ=UTC
    export HOME="$BATS_TEST_TMPDIR/home"
    HDIR="$HOME/.claude/harness"
    LEDGER="$HDIR/rule-ledger"
    mkdir -p "$HDIR" "$HOME/.claude/scripts"
    SCRIPT="$HOME/.claude/scripts/harness-rule-ledger.sh"
    cp "$BATS_TEST_DIRNAME/../dot_claude/scripts/executable_harness-rule-ledger.sh" "$SCRIPT"
    # 判定の記録は Verdict の CLI で読むので、本物を本来の配置先に置く
    cp "$BATS_TEST_DIRNAME/../dot_claude/scripts/executable_harness-verdict.sh" "$HOME/.claude/scripts/harness-verdict.sh"
    STUBS="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STUBS"
    export GH_LOG="$BATS_TEST_TMPDIR/gh.log"
    # gh pr view <url> --json createdAt --jq .createdAt。STUB_GH_FAIL_PR に一致する URL は失敗する。
    # gh pr view <番号> --json state --jq .state は STUB_GH_STATE_<番号>(既定 MERGED)を返す
    cat >"$STUBS/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
[[ "$1 $2" == "pr view" ]] || exit 1
[[ -z "${STUB_GH_FAIL_PR:-}" || "$3" != *"$STUB_GH_FAIL_PR" ]] || exit 1
if [[ "$*" == *'--json state'* ]]; then
    var="STUB_GH_STATE_$3"
    printf '%s\n' "${!var:-MERGED}"
    exit 0
fi
printf '2026-09-28T03:00:00Z\n'
EOF
    chmod +x "$STUBS/gh"
    export PATH="$STUBS:$PATH"
    S1=11111111-1111-4111-8111-111111111111
    S2=22222222-2222-4222-8222-222222222222
    URL=https://github.com/example/dotfiles/pull/42
}

# entry <title> <verdict> [Source の行の中身]
entry() {
    printf '## %s\n\n- **What happened:** x\n' "$1" >>"$HDIR/queue-archive.md"
    [[ -z "${3:-}" ]] || printf -- '- **Source:** %s\n' "$3" >>"$HDIR/queue-archive.md"
    printf -- '- **Verdict:** %s\n\n' "$2" >>"$HDIR/queue-archive.md"
}

sha8() {
    printf '%s' "$1" | shasum -a 256 | cut -c1-8
}

ledger_id() { # <PR 番号> <title>
    printf 'pr%s-%s\n' "$1" "$(sha8 "$2")"
}

classification() { # <session_id> <pattern>
    printf '{"session_id":"%s","line":1,"signal":"tool_error","pattern":"%s","run":"c","epoch":1}\n' "$1" "$2" \
        >>"$HDIR/classifications.jsonl"
}

@test "PR の採用ごとに、採用日・Failure Pattern・Eval Case・得点と Δ・PR 番号を記録する" {
    entry '[2026-10-03] uses rule' "adopted (PR $URL)" "session $S1, $S2"
    entry '[2026-10-03] exempted' "adopted (PR $URL) → rules/x.md"
    entry '[2026-10-03] no request' "adopted (PR $URL)"
    classification "$S1" shell-pitfall
    classification "$S2" unclassified
    classification "$S2" shell-pitfall
    classification 33333333-3333-4333-8333-333333333333 other-pattern
    id=$(ledger_id 42 '[2026-10-03] uses rule')
    case_id="2026-10-04-$(sha8 '[2026-10-03] uses rule')"
    cat >"$BATS_TEST_TMPDIR/results.json" <<EOF
{"date":"2026-10-04","cases":[{"title":"[2026-10-03] uses rule","id":"$case_id","status":"evaluated","with":1,"without":0.5,"delta":0.5,"cost_usd":0.1,"runs":{"with":2,"without":2,"excluded":0},"rule_sha256":"abc"}],
 "exempt":[{"title":"[2026-10-03] exempted","reason":"人の判断の誤り"}],"over_cap":[],"cost_usd":0.1}
EOF
    run bash "$SCRIPT" record --pr-url "$URL" --date 2026-10-04 --via weekly --results "$BATS_TEST_TMPDIR/results.json"
    assert_success
    run jq -c . "$LEDGER/$id.json"
    assert_output "{\"id\":\"$id\",\"adopted\":\"2026-10-04\",\"title\":\"[2026-10-03] uses rule\",\"failure_patterns\":[\"shell-pitfall\",\"unclassified\"],\"eval\":{\"status\":\"evaluated\",\"case_id\":\"$case_id\",\"with\":1,\"without\":0.5,\"delta\":0.5},\"pr\":42,\"via\":\"weekly\"}"
    run jq -c '{eval, failure_patterns}' "$LEDGER/$(ledger_id 42 '[2026-10-03] exempted').json"
    assert_output '{"eval":{"status":"exempt","reason":"人の判断の誤り"},"failure_patterns":[]}'
    run jq -c .eval "$LEDGER/$(ledger_id 42 '[2026-10-03] no request').json"
    assert_output '{"status":"missing","reason":"no_request"}'
}

@test "評価の結果を渡さなければ、測っていないと記録する" {
    entry '[2026-10-03] a' "adopted (PR $URL)"
    run bash "$SCRIPT" record --pr-url "$URL" --date 2026-10-04 --via manual
    assert_success
    run jq -c '{eval, via}' "$LEDGER/$(ledger_id 42 '[2026-10-03] a').json"
    assert_output '{"eval":{"status":"missing","reason":"not_measured"},"via":"manual"}'
}

@test "評価できなかったケース・無効のケース・件数の上限を超えたケースも、その判定で記録する" {
    entry '[2026-10-03] invalid' "adopted (PR $URL)"
    entry '[2026-10-03] limited' "adopted (PR $URL)"
    entry '[2026-10-03] capped' "adopted (PR $URL)"
    cat >"$BATS_TEST_TMPDIR/results.json" <<'EOF'
{"date":"2026-10-04","cases":[
 {"title":"[2026-10-03] invalid","id":"2026-10-04-aaaaaaaa","status":"invalid","with":1,"without":1,"cost_usd":0},
 {"title":"[2026-10-03] limited","id":"2026-10-04-bbbbbbbb","status":"not_evaluated","reason":"rate_limited","cost_usd":0}],
 "exempt":[],"over_cap":["[2026-10-03] capped"],"over_cap_cases":[{"title":"[2026-10-03] capped","id":"2026-10-04-cccccccc"}],"cost_usd":0}
EOF
    run bash "$SCRIPT" record --pr-url "$URL" --date 2026-10-04 --via weekly --results "$BATS_TEST_TMPDIR/results.json"
    assert_success
    run jq -c .eval "$LEDGER/$(ledger_id 42 '[2026-10-03] invalid').json"
    assert_output '{"status":"invalid","case_id":"2026-10-04-aaaaaaaa","with":1,"without":1}'
    run jq -c .eval "$LEDGER/$(ledger_id 42 '[2026-10-03] limited').json"
    assert_output '{"status":"not_evaluated","case_id":"2026-10-04-bbbbbbbb","reason":"rate_limited"}'
    run jq -c .eval "$LEDGER/$(ledger_id 42 '[2026-10-03] capped').json"
    assert_output '{"status":"over_cap","case_id":"2026-10-04-cccccccc"}'
}

@test "over_cap_cases の無い古い評価の結果では、上限を超えたケースの case_id を null で記録する" {
    entry '[2026-10-03] capped' "adopted (PR $URL)"
    printf '{"date":"2026-10-04","cases":[],"exempt":[],"over_cap":["[2026-10-03] capped"],"cost_usd":0}\n' \
        >"$BATS_TEST_TMPDIR/results.json"
    run bash "$SCRIPT" record --pr-url "$URL" --date 2026-10-04 --via weekly --results "$BATS_TEST_TMPDIR/results.json"
    assert_success
    run jq -c .eval "$LEDGER/$(ledger_id 42 '[2026-10-03] capped').json"
    assert_output '{"status":"over_cap","case_id":null}'
}

@test "読めない評価の結果は、測っていないと記録して警告する" {
    entry '[2026-10-03] a' "adopted (PR $URL)"
    printf 'not json\n' >"$BATS_TEST_TMPDIR/results.json"
    run bash "$SCRIPT" record --pr-url "$URL" --date 2026-10-04 --via weekly --results "$BATS_TEST_TMPDIR/results.json"
    assert_success
    assert_output --partial 'WARN'
    run jq -c .eval "$LEDGER/$(ledger_id 42 '[2026-10-03] a').json"
    assert_output '{"status":"missing","reason":"not_measured"}'
}

@test "ほかの PR の採用・PR にならなかった採用・却下は記録しない" {
    entry '[2026-10-03] mine' "adopted (PR $URL)"
    entry '[2026-10-03] other pr' 'adopted (PR https://github.com/example/dotfiles/pull/420)'
    entry '[2026-10-03] unpublished' 'adopted (harness/review-2026-10-04 run abc)'
    entry '[2026-10-03] rejected' 'rejected (duplicate)'
    run bash "$SCRIPT" record --pr-url "$URL" --date 2026-10-04 --via weekly
    assert_success
    run ls "$LEDGER"
    assert_output "$(ledger_id 42 '[2026-10-03] mine').json"
}

@test "PR の採用が判定の記録に無ければ、何も書かずに成功する" {
    entry '[2026-10-03] other' 'rejected (x)'
    run bash "$SCRIPT" record --pr-url "$URL" --date 2026-10-04 --via weekly
    assert_success
    assert_output --partial 'no adopted verdict'
    assert [ ! -d "$LEDGER" ] || [ -z "$(ls -A "$LEDGER")" ]
}

@test "Verdict の CLI が無いか失敗すれば、採用が無いとは読まずに失敗する" {
    entry '[2026-10-03] mine' "adopted (PR $URL)"
    rm "$HOME/.claude/scripts/harness-verdict.sh"
    run bash "$SCRIPT" record --pr-url "$URL" --date 2026-10-04 --via weekly
    assert_failure
    refute_output --partial 'no adopted verdict'
    run bash "$SCRIPT" migrate
    assert_failure
    printf '#!/usr/bin/env bash\nexit 1\n' >"$HOME/.claude/scripts/harness-verdict.sh"
    run bash "$SCRIPT" record --pr-url "$URL" --date 2026-10-04 --via weekly
    assert_failure
    refute_output --partial 'no adopted verdict'
    assert [ ! -d "$LEDGER" ]
}

@test "既にある記録は上書きしない" {
    entry '[2026-10-03] a' "adopted (PR $URL)"
    run bash "$SCRIPT" record --pr-url "$URL" --date 2026-10-04 --via weekly
    assert_success
    file="$LEDGER/$(ledger_id 42 '[2026-10-03] a').json"
    before=$(cat "$file")
    run bash "$SCRIPT" record --pr-url "$URL" --date 2026-10-04 --via manual
    assert_success
    assert_output --partial 'already recorded'
    assert_equal "$(cat "$file")" "$before"
}

@test "移行と記録を同時に走らせても、どちらの記録も失わず、壊れた記録も残さない" {
    for i in $(seq 1 20); do entry "[2026-10-03] weekly $i" "adopted (PR $URL)"; done
    for i in $(seq 1 20); do entry "[2026-09-01] old $i" 'adopted (PR https://github.com/example/dotfiles/pull/7)'; done
    bash "$SCRIPT" record --pr-url "$URL" --date 2026-10-04 --via weekly >/dev/null &
    bash "$SCRIPT" migrate >/dev/null &
    bash "$SCRIPT" record --pr-url "$URL" --date 2026-10-04 --via manual >/dev/null &
    wait
    run bash -c "ls '$LEDGER' | grep -c '\.json$'"
    assert_output 40
    run bash "$SCRIPT" check "$LEDGER"
    assert_success
    run ls -A "$LEDGER"
    refute_output --partial '.tmp'
}

@test "移行は PR の採用を作成日の記録として移し、移せないものを理由付きで一覧にする" {
    entry '[2026-07-23] migrated' 'adopted (PR https://github.com/example/dotfiles/pull/373) → rules/x.md' "session $S1"
    entry '[2026-07-23] also' 'adopted (PR https://github.com/example/dotfiles/pull/373)'
    entry '[2026-10-01] unpublished' 'adopted (harness/review-2026-10-04 run abc)'
    entry '[2026-10-01] gh fails' 'adopted (PR https://github.com/example/dotfiles/pull/999)'
    entry '[2026-10-01] odd' 'adopted (by hand)'
    entry '[2026-10-01] rejected' 'rejected (x)'
    classification "$S1" shell-pitfall
    export STUB_GH_FAIL_PR=/999
    run bash "$SCRIPT" migrate
    assert_success
    id=$(ledger_id 373 '[2026-07-23] migrated')
    run jq -c . "$LEDGER/$id.json"
    assert_output "{\"id\":\"$id\",\"adopted\":\"2026-09-28\",\"title\":\"[2026-07-23] migrated\",\"failure_patterns\":[\"shell-pitfall\"],\"eval\":{\"status\":\"exempt\",\"reason\":\"Eval Case の仕組みを入れる前に採用した(移行した記録)\"},\"pr\":373,\"via\":\"migrated\"}"
    run bash "$SCRIPT" migrate
    assert_success
    assert_output --partial 'migrated 0'
    assert_line "$(printf 'skipped\tPR にならなかった週次の run の採用(手で publish するか queue に戻すまで移さない)\t[2026-10-01] unpublished')"
    assert_line "$(printf 'skipped\tPR の作成日を取れない\t[2026-10-01] gh fails')"
    assert_line "$(printf 'skipped\t採用の記録の書式を読めない\t[2026-10-01] odd')"
    refute_output --partial 'rejected'
    run bash -c "ls '$LEDGER' | wc -l | tr -d ' '"
    assert_output 2
    # PR の作成日は PR ごとに 1 回だけ引く
    run grep -c 'pull/373' "$GH_LOG"
    assert_output 2
}

# check <dir>
write_record() { # <dir> <file name> <JSON>
    mkdir -p "$1"
    printf '%s\n' "$3" >"$1/$2"
}

VALID='{"id":"pr1-0a1b2c3d","adopted":"2026-10-04","title":"t","failure_patterns":[],"eval":{"status":"evaluated","case_id":"2026-10-04-0a1b2c3d","with":1,"without":0,"delta":1},"pr":1,"via":"weekly"}'

@test "形式の検査は、決めた形の記録だけのディレクトリを通す" {
    dir="$BATS_TEST_TMPDIR/ledger"
    write_record "$dir" pr1-0a1b2c3d.json "$VALID"
    write_record "$dir" pr2-ffffffff.json '{"id":"pr2-ffffffff","adopted":"2026-10-04","title":"u","failure_patterns":["a-b"],"eval":{"status":"exempt","reason":"r"},"pr":2,"via":"migrated"}'
    run bash "$SCRIPT" check "$dir"
    assert_success
}

@test "形式の検査は、記録の形が違うファイルを名前付きで落とす" {
    dir="$BATS_TEST_TMPDIR/ledger"
    write_record "$dir" pr1-0a1b2c3d.json "$VALID"
    write_record "$dir" pr1-11111111.json "$(jq -c '.id = "pr1-11111111" | del(.eval.delta)' <<<"$VALID")"
    write_record "$dir" pr1-22222222.json "$(jq -c '.id = "pr1-99999999"' <<<"$VALID")"
    write_record "$dir" pr1-33333333.json "$(jq -c '.id = "pr1-33333333" | .extra = 1' <<<"$VALID")"
    write_record "$dir" pr1-44444444.json "$(jq -c '.id = "pr1-44444444" | .title = "a\nb"' <<<"$VALID")"
    write_record "$dir" pr1-55555555.json "$(jq -c '.id = "pr1-55555555" | .eval = {status: "missing", reason: "free text"}' <<<"$VALID")"
    write_record "$dir" pr1-66666666.json "$(jq -c '.id = "pr1-66666666" | .pr = 2' <<<"$VALID")"
    write_record "$dir" notes.md 'x'
    run bash "$SCRIPT" check "$dir"
    assert_failure
    for name in 11111111 22222222 33333333 44444444 55555555 66666666; do
        assert_output --partial "pr1-$name.json"
    done
    assert_output --partial 'notes.md'
    refute_output --partial '0a1b2c3d'
}

@test "形式の検査は、リポジトリの Rule Ledger を通す" {
    run bash "$SCRIPT" check "$BATS_TEST_DIRNAME/../docs/harness/rule-ledger"
    assert_success
}

# export --base <rev> --worktree <dir>
make_worktree() {
    WT="$BATS_TEST_TMPDIR/wt"
    mkdir -p "$WT/scripts"
    git -C "$WT" init -q -b main
    git -C "$WT" config user.email t@example.com
    git -C "$WT" config user.name t
    git -C "$WT" config commit.gpgsign false
    cp "$BATS_TEST_DIRNAME/../scripts/scan-sensitive-info.sh" "$BATS_TEST_DIRNAME/../scripts/sensitive-patterns.txt" "$WT/scripts/"
    : >"$WT/scripts/sensitive-allowlist.txt"
    git -C "$WT" add -A
    git -C "$WT" commit -qm init
    export SENSITIVE_WORK_ORG=acmework SENSITIVE_LOCAL_USER='' SENSITIVE_PATTERNS_LOCAL="$BATS_TEST_TMPDIR/none"
    # 仕事のリポジトリ名は ~/ghq/github.com/<org>/ のディレクトリ名から引く
    mkdir -p "$HOME/ghq/github.com/$SENSITIVE_WORK_ORG/shop_admin" "$HOME/ghq/github.com/$SENSITIVE_WORK_ORG/core-lib"
}

@test "書き出しは、base に無いローカルの記録だけをリポジトリの置き場に写す" {
    make_worktree
    entry '[2026-10-03] a' "adopted (PR $URL)"
    entry '[2026-10-03] b' "adopted (PR $URL)"
    bash "$SCRIPT" record --pr-url "$URL" --date 2026-10-04 --via weekly >/dev/null
    a=$(ledger_id 42 '[2026-10-03] a')
    b=$(ledger_id 42 '[2026-10-03] b')
    mkdir -p "$WT/docs/harness/rule-ledger"
    cp "$LEDGER/$a.json" "$WT/docs/harness/rule-ledger/"
    git -C "$WT" add -A && git -C "$WT" commit -qm a
    run bash "$SCRIPT" export --base HEAD --worktree "$WT"
    assert_success
    assert_output --partial 'exported 1 record(s)'
    run git -C "$WT" status --porcelain
    assert_output "?? docs/harness/rule-ledger/$b.json"
    cmp "$LEDGER/$b.json" "$WT/docs/harness/rule-ledger/$b.json"
}

@test "書き出しは、仕事の識別子を含む記録の自由記述を伏せて写す" {
    make_worktree
    entry '[2026-10-03] acmework の worktree で起きた' "adopted (PR $URL)"
    printf '{"date":"2026-10-04","cases":[],"exempt":[{"title":"[2026-10-03] acmework の worktree で起きた","reason":"acmework 固有"}],"over_cap":[],"cost_usd":0}\n' \
        >"$BATS_TEST_TMPDIR/results.json"
    bash "$SCRIPT" record --pr-url "$URL" --date 2026-10-04 --via weekly --results "$BATS_TEST_TMPDIR/results.json" >/dev/null
    id=$(ledger_id 42 '[2026-10-03] acmework の worktree で起きた')
    run bash "$SCRIPT" export --base HEAD --worktree "$WT"
    assert_success
    assert_output --partial "redacted the free text of $id"
    refute_output --partial acmework
    run grep -ci acmework "$WT/docs/harness/rule-ledger/$id.json"
    assert_output 0
    run jq -c '{title, eval}' "$WT/docs/harness/rule-ledger/$id.json"
    assert_output '{"title":"(仕事の文脈を含むため伏せた)","eval":{"status":"exempt","reason":"(仕事の文脈を含むため伏せた)"}}'
    run bash "$SCRIPT" check "$WT/docs/harness/rule-ledger"
    assert_success
}

@test "書き出しは、形の壊れたローカルの記録を写さずに警告する" {
    make_worktree
    mkdir -p "$LEDGER"
    printf '{"id":"broken"}\n' >"$LEDGER/2026-10-04-deadbeef.json"
    run bash "$SCRIPT" export --base HEAD --worktree "$WT"
    assert_success
    assert_output --partial 'WARN'
    assert_output --partial '2026-10-04-deadbeef.json'
    assert [ ! -e "$WT/docs/harness/rule-ledger/2026-10-04-deadbeef.json" ]
}

@test "書き出しは、識別子の検査を走らせられなければ何も写さずに失敗する" {
    make_worktree
    git -C "$WT" rm -q scripts/scan-sensitive-info.sh
    git -C "$WT" commit -qm 'drop the guard'
    entry '[2026-10-03] a' "adopted (PR $URL)"
    bash "$SCRIPT" record --pr-url "$URL" --date 2026-10-04 --via weekly >/dev/null
    run bash "$SCRIPT" export --base HEAD --worktree "$WT"
    assert_failure
    assert [ ! -e "$WT/docs/harness/rule-ledger" ]
}

@test "書き出しは、worktree で弱められた検査ではなく base の identity leak guard とローカルのパターンを使う" {
    make_worktree
    base=$(git -C "$WT" rev-parse HEAD)
    # 選別の claude の commit がスキャナとパターンを弱めた worktree
    printf '#!/usr/bin/env bash\nexit 0\n' >"$WT/scripts/scan-sensitive-info.sh"
    : >"$WT/scripts/sensitive-patterns.txt"
    git -C "$WT" commit -qam 'weaken the guard'
    printf 'oldaccountname\n' >"$BATS_TEST_TMPDIR/local-patterns.txt"
    export SENSITIVE_PATTERNS_LOCAL="$BATS_TEST_TMPDIR/local-patterns.txt"
    entry '[2026-10-03] oldaccountname の設定' "adopted (PR $URL)"
    entry '[2026-10-03] acmework の worktree' "adopted (PR $URL)"
    bash "$SCRIPT" record --pr-url "$URL" --date 2026-10-04 --via weekly >/dev/null
    run bash "$SCRIPT" export --base "$base" --worktree "$WT"
    assert_success
    run jq -r .title "$WT/docs/harness/rule-ledger/$(ledger_id 42 '[2026-10-03] oldaccountname の設定').json"
    assert_output '(仕事の文脈を含むため伏せた)'
    run jq -r .title "$WT/docs/harness/rule-ledger/$(ledger_id 42 '[2026-10-03] acmework の worktree').json"
    assert_output '(仕事の文脈を含むため伏せた)'
}

@test "書き出しは、マージされた PR と --pr の PR の記録だけを写し、閉じた PR・開いた別の PR・状態を引けない PR の記録は残す" {
    make_worktree
    for n in 42 43 44 45 46; do
        entry "[2026-10-03] pr $n" "adopted (PR https://github.com/example/dotfiles/pull/$n)"
        bash "$SCRIPT" record --pr-url "https://github.com/example/dotfiles/pull/$n" --date 2026-10-04 --via weekly >/dev/null
    done
    export STUB_GH_STATE_43=CLOSED STUB_GH_STATE_44=OPEN STUB_GH_STATE_45=OPEN STUB_GH_FAIL_PR=46
    run bash "$SCRIPT" export --base HEAD --worktree "$WT" --pr 45
    assert_success
    assert_output --partial 'exported 2 record(s)'
    assert_output --partial "not exported $(ledger_id 43 '[2026-10-03] pr 43'): its PR #43 was closed without a merge"
    assert_output --partial "not exported $(ledger_id 44 '[2026-10-03] pr 44'): its PR #44 is still open"
    assert_output --partial "not exported $(ledger_id 46 '[2026-10-03] pr 46'): cannot read the state of its PR #46"
    run ls "$WT/docs/harness/rule-ledger"
    assert_output "$(printf '%s.json\n' "$(ledger_id 42 '[2026-10-03] pr 42')" "$(ledger_id 45 '[2026-10-03] pr 45')" | sort)"
    # 写さなかった記録もローカルには残す
    assert [ -f "$LEDGER/$(ledger_id 43 '[2026-10-03] pr 43').json" ]
    # --pr の PR は状態を引かない
    run grep -c 'pr view 45' "$GH_LOG"
    assert_output 0
}

@test "書き出しは、初めて写した形を残し、仕事のリポジトリの一覧から名前が消えても同じ形で写す" {
    make_worktree
    mkdir -p "$HOME/ghq/github.com/$SENSITIVE_WORK_ORG/newrepo"
    entry '[2026-10-03] newrepo の設定' "adopted (PR $URL)"
    bash "$SCRIPT" record --pr-url "$URL" --date 2026-10-04 --via weekly >/dev/null
    id=$(ledger_id 42 '[2026-10-03] newrepo の設定')
    run bash "$SCRIPT" export --base HEAD --worktree "$WT"
    assert_success
    first=$(cat "$WT/docs/harness/rule-ledger/$id.json")
    run jq -r .title <<<"$first"
    assert_output '(仕事の文脈を含むため伏せた)'
    assert [ -f "$LEDGER/exported/$id.json" ]
    # 前の PR が未マージの間に、仕事のリポジトリが手元から消えた
    rm -rf "$WT/docs" "$HOME/ghq/github.com/$SENSITIVE_WORK_ORG/newrepo"
    run bash "$SCRIPT" export --base HEAD --worktree "$WT"
    assert_success
    assert_equal "$(cat "$WT/docs/harness/rule-ledger/$id.json")" "$first"
    # 残した形が無ければ、伏せない形で写る(上の比較が残した形によるものであることの対)
    rm -rf "$WT/docs" "$LEDGER/exported"
    run bash "$SCRIPT" export --base HEAD --worktree "$WT"
    assert_success
    run jq -r .title "$WT/docs/harness/rule-ledger/$id.json"
    assert_output '[2026-10-03] newrepo の設定'
}

@test "書き出しは、仕事のリポジトリ名を含む記録の自由記述を伏せて写す" {
    make_worktree
    entry '[2026-10-03] Shop_Admin の .gitignore に足す' "adopted (PR $URL)"
    entry '[2026-10-03] 個人の設定' "adopted (PR $URL)"
    bash "$SCRIPT" record --pr-url "$URL" --date 2026-10-04 --via weekly >/dev/null
    id=$(ledger_id 42 '[2026-10-03] Shop_Admin の .gitignore に足す')
    other=$(ledger_id 42 '[2026-10-03] 個人の設定')
    run bash "$SCRIPT" export --base HEAD --worktree "$WT"
    assert_success
    assert_output --partial "redacted the free text of $id"
    run jq -r .title "$WT/docs/harness/rule-ledger/$id.json"
    assert_output '(仕事の文脈を含むため伏せた)'
    run jq -r .title "$WT/docs/harness/rule-ledger/$other.json"
    assert_output '[2026-10-03] 個人の設定'
}

@test "書き出しは、仕事の org を引けなければ何も写さずに失敗する" {
    make_worktree
    export SENSITIVE_WORK_ORG=''
    entry '[2026-10-03] a' "adopted (PR $URL)"
    bash "$SCRIPT" record --pr-url "$URL" --date 2026-10-04 --via weekly >/dev/null
    run bash "$SCRIPT" export --base HEAD --worktree "$WT"
    assert_failure
    assert_output --partial 'work org'
    assert [ ! -e "$WT/docs/harness/rule-ledger" ]
}

@test "書き出しは、仕事のリポジトリの一覧を読めなければ何も写さずに失敗する" {
    make_worktree
    rm -rf "$HOME/ghq"
    entry '[2026-10-03] a' "adopted (PR $URL)"
    bash "$SCRIPT" record --pr-url "$URL" --date 2026-10-04 --via weekly >/dev/null
    run bash "$SCRIPT" export --base HEAD --worktree "$WT"
    assert_failure
    assert [ ! -e "$WT/docs/harness/rule-ledger" ]
}

@test "移行は括弧の無い採用の行も、書式を読めないものとして一覧に出す" {
    entry '[2026-07-23] bare' 'adopted'
    entry '[2026-07-23] note' 'adopted — 手で反映した'
    entry '[2026-07-23] unclosed' 'adopted (PR https://github.com/example/dotfiles/pull/373'
    entry '[2026-07-23] rejected' 'rejected'
    run bash "$SCRIPT" migrate
    assert_success
    assert_line "$(printf 'skipped\t採用の記録の書式を読めない\t[2026-07-23] bare')"
    assert_line "$(printf 'skipped\t採用の記録の書式を読めない\t[2026-07-23] note')"
    assert_line "$(printf 'skipped\t採用の記録の書式を読めない\t[2026-07-23] unclosed')"
    refute_output --partial 'rejected'
    assert_output --partial 'skipped 3'
    assert [ ! -d "$LEDGER" ] || [ -z "$(ls -A "$LEDGER")" ]
}

@test "移行は Eval Case を入れた後に作った PR の採用を移さず、record で記録するよう一覧に出す" {
    cat >"$STUBS/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
printf '2026-10-10T03:00:00Z\n'
EOF
    entry '[2026-10-09] new' 'adopted (PR https://github.com/example/dotfiles/pull/500)'
    run bash "$SCRIPT" migrate
    assert_success
    assert_line "$(printf 'skipped\tEval Case を入れた後の採用(record で記録する)\t[2026-10-09] new')"
    assert [ ! -d "$LEDGER" ] || [ -z "$(ls -A "$LEDGER")" ]
}
