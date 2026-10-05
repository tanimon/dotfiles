# 週ごとの Failure Pattern の再発率(harness-failure-rates.sh)の振る舞い検査。
#
# 偽の $HOME に検出の記録(detections.jsonl)と分類の記録(classifications.jsonl)を書き、
# 週の記録(failure-pattern-rates/<日付>.json)と PR 本文の推移の節を確かめる。
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
    run --separate-stderr bash "$SCRIPT" trend --weeks 4
    assert_success
    assert_line '## Failure Pattern の再発率'
    assert_line '| Failure Pattern | 2026-09-19 | 2026-09-26 | 2026-10-03 | 2026-10-10 |'
    assert_line '| `shell-pitfall` | 25% (2) | 25% (2) | 記録なし | 25% (2) |'
    assert_line '| 未分類 | 0% (0) | 0% (0) | 記録なし | 0% (0) |'
    # その週の一覧に無かった Failure Pattern(後から足したもの)は - にする
    assert_line '| `unverified-claim` | - | - | 記録なし | - |'
    assert_line '| セッション数 | 4 | 4 | 4 | 4 |'
    assert_line '| 分類した失敗 / 検出した失敗 | 2 / 3 | 2 / 3 | 2 / 3 | 2 / 3 |'
    refute_output --partial '2026-09-12'
}

@test "週の記録が無ければ推移の節は記録が無いことを書く" {
    run --separate-stderr bash "$SCRIPT" trend --weeks 4
    assert_success
    assert_line '## Failure Pattern の再発率'
    assert_output --partial '週の記録はまだ無い'
}

@test "検出器にかけたセッションが 0 件の週の率は - にする" {
    mkdir -p "$RATES"
    printf '{"date":"2026-10-10","since":0,"until":1,"sessions":0,"detections":0,"classified":0,"classification":"ok","patterns":{"unclassified":{"occurrences":0,"sessions":0,"rate":null}}}\n' \
        >"$RATES/2026-10-10.json"
    run --separate-stderr bash "$SCRIPT" trend --weeks 4
    assert_success
    assert_line '| 未分類 | - |'
}
