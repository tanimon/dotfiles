# 週ごとの Failure Pattern の再発率(harness-failure-rates.sh)の振る舞い検査。
#
# 偽の $HOME に検出の記録(detections.jsonl)と分類の記録(classifications.jsonl)を書き、
# Weekly Rate Record(failure-pattern-rates/<日付>.json)と PR 本文の推移の節を確かめる。export は base にする git の作業ツリーを
# 作り、書き出した記録・件数の行を確かめる(記録を選ぶ規則の検査はここだけ。Loop PR の module の bats は CLI を記録を選ばない stub に置き換えて配線だけを見る)。
bats_require_minimum_version 1.5.0

setup() {
    load 'helpers/setup'
    export HOME="$BATS_TEST_TMPDIR/home"
    HDIR="$HOME/.claude/harness"
    RATES="$HDIR/failure-pattern-rates"
    mkdir -p "$HDIR" "$HOME/.claude/scripts"
    cp "$BATS_TEST_DIRNAME/../dot_claude/scripts/harness-failure-patterns.json" \
        "$HOME/.claude/scripts/harness-failure-patterns.json"
    SCRIPT="$HOME/.claude/scripts/harness-failure-rates.sh"
    cp "$BATS_TEST_DIRNAME/../dot_claude/scripts/executable_harness-failure-rates.sh" "$SCRIPT"
    NOW=$(date +%s)
    TODAY=$(date +%Y-%m-%d)
}

# detection <session_id> <epoch> <counts>
detection() {
    printf '{"session_id":"%s","run":"r","date":"d","epoch":%s,"counts":%s}\n' "$1" "$2" "$3" >>"$HDIR/detections.jsonl"
}

# classification <session_id> <line> <pattern> <epoch>
classification() {
    printf '{"session_id":"%s","line":%s,"signal":"tool_error","pattern":"%s","run":"c","epoch":%s}\n' \
        "$1" "$2" "$3" "$4" >>"$HDIR/classifications.jsonl"
}

# week_record <date> <since> <until> [classification]: 推移の節の入力にする週の記録を直接置く
week_record() {
    mkdir -p "$RATES"
    jq -n -c --arg date "$1" --argjson since "$2" --argjson until "$3" --arg status "${4:-ok}" '
        {date: $date, since: $since, until: $until, sessions: 4, detections: 3, classified: 2, classification: $status,
         patterns: {"shell-pitfall": {occurrences: 2, sessions: 1, rate: 0.25}, unclassified: {occurrences: 0, sessions: 0, rate: 0}}}' \
        >"$RATES/$1.json"
}

@test "前の週の記録が無ければ、期間の始まりは直近 7 日" {
    run bash "$SCRIPT" since "$TODAY"
    assert_success
    assert [ "$output" -ge "$((NOW - 7 * 86400))" ]
    assert [ "$output" -le "$((NOW - 7 * 86400 + 5))" ]
}

@test "期間の始まりは前の週の記録の終わりで、同じ日の記録は見ない" {
    week_record 2026-09-26 100 2000
    week_record 2026-10-03 2000 3000
    week_record "$TODAY" 3000 4000
    run bash "$SCRIPT" since "$TODAY"
    assert_success
    assert_output '3000'
}

@test "期間の分類から Failure Pattern ごとの件数・セッション数・率を記録する" {
    since=$((NOW - 3600))
    detection s1 "$((NOW - 60))" '{"tool_error":2}'
    detection s2 "$((NOW - 60))" '{"tool_error":1}'
    detection s3 "$((NOW - 60))" '{}'
    detection s4 "$((NOW - 60))" '{}'
    detection old "$((since - 1))" '{"tool_error":5}'
    classification s1 3 shell-pitfall "$NOW"
    classification s1 5 shell-pitfall "$NOW"
    classification s2 7 unclassified "$NOW"
    classification old 1 shell-pitfall "$((since - 1))"
    run bash "$SCRIPT" record "$TODAY" --since "$since" --classification ok
    assert_success
    run jq -c '{date, sessions, detections, classified, classification}' "$RATES/$TODAY.json"
    assert_output "{\"date\":\"$TODAY\",\"sessions\":4,\"detections\":3,\"classified\":3,\"classification\":\"ok\"}"
    run jq -c '.patterns["shell-pitfall"], .patterns.unclassified, .patterns["unverified-claim"]' "$RATES/$TODAY.json"
    assert_output "$(printf '%s\n' \
        '{"occurrences":2,"sessions":1,"rate":0.25}' \
        '{"occurrences":1,"sessions":1,"rate":0.25}' \
        '{"occurrences":0,"sessions":0,"rate":0}')"
    run jq -e --argjson since "$since" --argjson now "$NOW" '.since == $since and .until >= $now' "$RATES/$TODAY.json"
    assert_success
}

@test "週の記録には id と数値だけを残す" {
    detection s1 "$NOW" '{"tool_error":1}'
    classification s1 3 shell-pitfall "$NOW"
    run bash "$SCRIPT" record "$TODAY" --since "$((NOW - 60))" --classification ok
    assert_success
    run cat "$RATES/$TODAY.json"
    refute_output --partial 's1'
    refute_output --partial 'tool_error'
}

@test "分類に失敗した週はそのことを記録する" {
    detection s1 "$NOW" '{"tool_error":1}'
    run bash "$SCRIPT" record "$TODAY" --since "$((NOW - 60))" --classification failed
    assert_success
    run jq -r '.classification, .classified' "$RATES/$TODAY.json"
    assert_output "$(printf '%s\n' failed 0)"
}

@test "推移の節は直近の週を古い順に並べ、率と件数を出す" {
    week_record 2026-09-12 0 1
    week_record 2026-09-19 1 2
    week_record 2026-09-26 2 3
    week_record 2026-10-03 3 4 failed
    week_record 2026-10-10 4 5
    # 渡した日付より後の記録は見ない
    week_record 2026-10-17 5 6
    run --separate-stderr bash "$SCRIPT" trend 2026-10-10 --weeks 4
    assert_success
    assert_line '## Failure Pattern の再発率'
    assert_line '| Failure Pattern | 2026-09-19 | 2026-09-26 | 2026-10-03 | 2026-10-10 |'
    refute_output --partial '2026-10-17'
    assert_line '| `shell-pitfall` | 25% (2) | 25% (2) | 記録なし | 25% (2) |'
    assert_line '| 未分類 | 0% (0) | 0% (0) | 記録なし | 0% (0) |'
    # その週の一覧に無かった Failure Pattern(後から足したもの)は - にする
    assert_line '| `unverified-claim` | - | - | 記録なし | - |'
    assert_line '| セッション数 | 4 | 4 | 4 | 4 |'
    assert_line '| 分類した失敗 / 検出した失敗 | 2 / 3 | 2 / 3 | 2 / 3 | 2 / 3 |'
    refute_output --partial '2026-09-12'
}

@test "週の記録が無ければ推移の節は記録が無いことを書く" {
    run --separate-stderr bash "$SCRIPT" trend 2026-10-10 --weeks 4
    assert_success
    assert_line '## Failure Pattern の再発率'
    assert_output --partial '週の記録はまだ無い'
}

@test "検出器にかけたセッションが 0 件の週の率は - にする" {
    mkdir -p "$RATES"
    printf '{"date":"2026-10-10","since":0,"until":1,"sessions":0,"detections":0,"classified":0,"classification":"ok","patterns":{"unclassified":{"occurrences":0,"sessions":0,"rate":null}}}\n' \
        >"$RATES/2026-10-10.json"
    run --separate-stderr bash "$SCRIPT" trend 2026-10-10 --weeks 4
    assert_success
    assert_line '| 未分類 | - |'
}

# 失敗の検出の節。期間の時刻は UTC で書かせて、文字列をそのまま比べる
@test "失敗の検出の節は、その日の Weekly Rate Record の期間の検出を、記録した実行を問わずに数える" {
    export TZ=UTC
    week_record 2026-10-24 1792800000 1793408400
    week_record 2026-10-31 1793408400 1794013200
    # 期間の始まりちょうどは前の週の Weekly Rate Record の分なので数えない。終わりちょうどは数える
    detection before 1792800000 '{"user_negation":7}'
    detection w1 1792800100 '{"tool_error":3,"ci_failure":2}'
    printf 'broken line\n' >>"$HDIR/detections.jsonl"
    printf '{"session_id":"m1","run":"manual","date":"d","epoch":1793000000,"counts":{"user_negation":2}}\n' >>"$HDIR/detections.jsonl"
    detection clean 1793100000 '{}'
    detection w2 1793408400 '{"repeat":2}'
    detection after 1793408401 '{"hook_deny":4}'
    run --separate-stderr bash "$SCRIPT" detections 2026-10-24
    assert_success
    assert_output "$(printf '%s\n' '' '## 失敗の検出' '' \
        '2026-10-24 00:00 から 2026-10-31 01:00 までに検出器にかけたセッション: 4 件(失敗あり 3 件)。' '' \
        '| 信号 | 件数 |' '|---|---:|' '| `tool_error` | 3 |' '| `ci_failure` | 2 |' '| `repeat` | 2 |' \
        '| `user_negation` | 2 |' '| 合計 | 9 |')"
}

@test "失敗の検出の節は、期間に検出が 1 件も無ければ表を出さずに合計 0 を書く" {
    export TZ=UTC
    week_record 2026-10-24 1792800000 1793408400
    detection clean 1792800100 '{}'
    detection after 1793408401 '{"hook_deny":4}'
    run --separate-stderr bash "$SCRIPT" detections 2026-10-24
    assert_success
    assert_output "$(printf '%s\n' '' '## 失敗の検出' '' \
        '2026-10-24 00:00 から 2026-10-31 01:00 までに検出器にかけたセッション: 1 件(失敗あり 0 件)。' '' '合計: 0')"
}

# record が書いた Weekly Rate Record の期間をそのまま失敗の検出の節に読ませ、2 つの数え方を同じ期間で比べる
@test "失敗の検出の節の合計は、同じ日の Weekly Rate Record の detections と一致する" {
    since=$((NOW - 3600))
    detection s1 "$((NOW - 60))" '{"tool_error":2,"ci_failure":1}'
    detection s2 "$((NOW - 60))" '{"repeat":3}'
    detection s3 "$((NOW - 60))" '{}'
    detection old "$((since - 1))" '{"tool_error":5}'
    run bash "$SCRIPT" record "$TODAY" --since "$since" --classification ok
    assert_success
    run jq '.detections' "$RATES/$TODAY.json"
    assert_output '6'
    run --separate-stderr bash "$SCRIPT" detections "$TODAY"
    assert_success
    assert_line '| 合計 | 6 |'
}

@test "数値でない件数と object でない counts は、Weekly Rate Record の detections でも失敗の検出の節でも数えない" {
    since=$((NOW - 3600))
    detection s1 "$((NOW - 60))" '{"tool_error":2}'
    detection odd "$((NOW - 60))" '{"tool_error":"3","hook_deny":1}'
    detection list "$((NOW - 60))" '[4]'
    run bash "$SCRIPT" record "$TODAY" --since "$since" --classification ok
    assert_success
    run jq '.detections' "$RATES/$TODAY.json"
    assert_output '3'
    run --separate-stderr bash "$SCRIPT" detections "$TODAY"
    assert_success
    assert_line '| `tool_error` | 2 |'
    assert_line '| `hook_deny` | 1 |'
    assert_line '| 合計 | 3 |'
}

@test "失敗の検出の節は、その日の Weekly Rate Record が無いか期間を読めなければ失敗する" {
    week_record 2026-10-17 100 200
    detection w1 150 '{"tool_error":1}'
    run --separate-stderr bash "$SCRIPT" detections 2026-10-24
    assert_failure 1
    assert_output ''
    assert_equal "$stderr" "harness-failure-rates: no weekly rate record for 2026-10-24 ($RATES/2026-10-24.json)"
    printf 'broken\n' >"$RATES/2026-10-24.json"
    run --separate-stderr bash "$SCRIPT" detections 2026-10-24
    assert_failure 1
    assert_output ''
    assert_equal "$stderr" "harness-failure-rates: cannot read .since from $RATES/2026-10-24.json"
}

@test "分類に失敗した週の期間は、次の週の期間に含めてもう一度分類させる" {
    week_record 2026-09-19 100 2000
    week_record 2026-09-26 2000 3000 failed
    week_record 2026-10-03 3000 4000 failed
    run bash "$SCRIPT" since "$TODAY"
    assert_success
    assert_output '2000'
}

@test "分類に成功した週が無ければ、最も古い失敗した週の始まりから" {
    week_record 2026-09-26 100 2000 failed
    week_record 2026-10-03 2000 3000 failed
    run bash "$SCRIPT" since "$TODAY"
    assert_success
    assert_output '100'
}

@test "前の週の記録の分類の結果が読めなければ失敗する" {
    week_record 2026-10-03 2000 3000 unknown
    run bash "$SCRIPT" since "$TODAY"
    assert_failure
    assert_output --partial 'cannot read .classification'
}

@test "前の週の記録が読めなければ、直近 7 日に戻さずに失敗する" {
    mkdir -p "$RATES"
    printf 'broken\n' >"$RATES/2026-10-03.json"
    run bash "$SCRIPT" since "$TODAY"
    assert_failure
    assert_output --partial 'cannot read .until'
}

@test "値の無いオプションは使い方の誤りとして 2 で終わる" {
    run bash "$SCRIPT" record "$TODAY" --since
    assert_failure 2
    assert_output --partial 'usage:'
}

# export の base にする git の作業ツリー WT を作る。<日付> のローカルの Weekly Rate Record を置き場に写して commit する
export_worktree() { # [<base に置く日付>…]
    local date
    WT="$BATS_TEST_TMPDIR/wt"
    git init -q -b main "$WT"
    mkdir -p "$WT/docs/harness/failure-pattern-rates"
    for date in "$@"; do
        cp "$RATES/$date.json" "$WT/docs/harness/failure-pattern-rates/"
    done
    printf 'x\n' >"$WT/README.md"
    git -C "$WT" add -A
    git -C "$WT" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false commit -qm base
}

# <日付> のローカルの Weekly Rate Record を、中身 <JSON> で置く
local_week() { # <日付> <JSON>
    mkdir -p "$RATES"
    printf '%s\n' "$2" >"$RATES/$1.json"
}

@test "書き出しは、base に無い Weekly Rate Record だけを worktree の置き場にそのまま写し、件数を 1 行で出す" {
    local_week 2026-10-03 '{"date":"2026-10-03"}'
    local_week 2026-10-10 '{ "date": "2026-10-10" }'
    export_worktree 2026-10-03
    run bash "$SCRIPT" export 2026-10-17 --base HEAD --worktree "$WT"
    assert_success
    assert_output 'harness-failure-rates: exported 1 record(s)'
    run git -C "$WT" status --porcelain --untracked-files=all
    assert_output '?? docs/harness/failure-pattern-rates/2026-10-10.json'
    cmp "$RATES/2026-10-10.json" "$WT/docs/harness/failure-pattern-rates/2026-10-10.json"
}

@test "書き出しは、その日の記録は base にあっても中身が違えば写し、ほかの日付の記録は中身が違っても写さない" {
    local_week 2026-10-10 '{"date":"2026-10-10"}'
    local_week 2026-10-17 '{"date":"2026-10-17"}'
    export_worktree 2026-10-10 2026-10-17
    # base の記録を人が直した後の前の日付と、同じ日の再実行が書き直したその日の記録
    local_week 2026-10-10 '{"date":"2026-10-10","fixed":true}'
    local_week 2026-10-17 '{"date":"2026-10-17","rerun":true}'
    run bash "$SCRIPT" export 2026-10-17 --base HEAD --worktree "$WT"
    assert_success
    assert_output 'harness-failure-rates: exported 1 record(s)'
    run git -C "$WT" status --porcelain --untracked-files=all
    assert_output ' M docs/harness/failure-pattern-rates/2026-10-17.json'
    cmp "$RATES/2026-10-17.json" "$WT/docs/harness/failure-pattern-rates/2026-10-17.json"
}

@test "書き出しは、その日の記録が base と JSON として同じなら写さない" {
    local_week 2026-10-17 '{"date":"2026-10-17","sessions":1}'
    export_worktree 2026-10-17
    local_week 2026-10-17 '{ "sessions": 1, "date": "2026-10-17" }'
    run bash "$SCRIPT" export 2026-10-17 --base HEAD --worktree "$WT"
    assert_success
    assert_output 'harness-failure-rates: exported 0 record(s)'
    run git -C "$WT" status --porcelain --untracked-files=all
    assert_output ''
}

@test "書き出しは、その日の記録が JSON として読めなければ base と違うものとして写す" {
    local_week 2026-10-17 '{"date":"2026-10-17"}'
    export_worktree 2026-10-17
    local_week 2026-10-17 'not json'
    run bash "$SCRIPT" export 2026-10-17 --base HEAD --worktree "$WT"
    assert_success
    assert_output 'harness-failure-rates: exported 1 record(s)'
}

@test "書き出しの --dry-run は、写す件数を 1 行で出し、worktree にもローカルの置き場にも何も書かない" {
    local_week 2026-10-03 '{"date":"2026-10-03"}'
    local_week 2026-10-10 '{"date":"2026-10-10"}'
    local_week 2026-10-17 '{"date":"2026-10-17"}'
    export_worktree
    # 記録の無い base では置き場のディレクトリも無い(git は空のディレクトリを持たない)
    rm -r "$WT/docs"
    local before
    before=$(ls -A "$RATES")
    run bash "$SCRIPT" export 2026-10-17 --base HEAD --worktree "$WT" --dry-run
    assert_success
    assert_output 'harness-failure-rates: would export 3 record(s)'
    run git -C "$WT" status --porcelain --untracked-files=all --ignored
    assert_output ''
    assert [ ! -e "$WT/docs" ]
    assert_equal "$(ls -A "$RATES")" "$before"
}

@test "書き出しは、ローカルに Weekly Rate Record が無ければ置き場を作らずに 0 件と出す" {
    export_worktree
    run bash "$SCRIPT" export 2026-10-17 --base HEAD --worktree "$WT"
    assert_success
    assert_output 'harness-failure-rates: exported 0 record(s)'
    run git -C "$WT" status --porcelain --untracked-files=all
    assert_output ''
}

@test "書き出しは、base を引けなければ何も写さずに失敗し、base か worktree が無ければ使い方の誤りとして 2 で終わる" {
    local_week 2026-10-10 '{"date":"2026-10-10"}'
    export_worktree
    run bash "$SCRIPT" export 2026-10-17 --base no-such-revision --worktree "$WT"
    assert_failure 1
    assert_output --partial 'cannot resolve no-such-revision'
    run git -C "$WT" status --porcelain --untracked-files=all
    assert_output ''
    run bash "$SCRIPT" export 2026-10-17 --worktree "$WT"
    assert_failure 2
    run bash "$SCRIPT" export 2026-10-17 --base HEAD
    assert_failure 2
}
