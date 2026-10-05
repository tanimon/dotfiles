# Failure Pattern への分類器(harness-classify-failures.sh)の振る舞い検査。
#
# 偽の $HOME に分類器・検出器・Failure Pattern の一覧を本来の配置先(~/.claude/scripts/)へ置き、
# transcript は検出器の fixture を ~/.claude/projects/ の下に写して使う。claude は PATH 上のスタブで、
# 標準入力のプロンプトを $PROMPT_LOG に写し、STUB_CLASSIFY に応じた結果を出す:
#   all:<pattern>  プロンプトの項目の id をすべて <pattern> に分類する(既定は all:shell-pitfall)
#   raw            STUB_CLASSIFY_RAW をそのまま結果の文字列にする
#   is_error       結果に is_error を立てる
bats_require_minimum_version 1.5.0

setup() {
    load 'helpers/setup'
    load 'helpers/exec-cache'
    unset HARNESS_CLASSIFY_BUDGET_USD HARNESS_CLASSIFY_MAX_ITEMS STUB_CLASSIFY STUB_CLASSIFY_RAW
    export HOME="$BATS_TEST_TMPDIR/home"
    HDIR="$HOME/.claude/harness"
    PROJECTS="$HOME/.claude/projects/-work-repo"
    mkdir -p "$HDIR" "$PROJECTS" "$HOME/.claude/scripts"
    cp "$BATS_TEST_DIRNAME/../dot_claude/scripts/executable_harness-detect-failures.sh" \
        "$HOME/.claude/scripts/harness-detect-failures.sh"
    cp "$BATS_TEST_DIRNAME/../dot_claude/scripts/harness-failure-patterns.json" \
        "$HOME/.claude/scripts/harness-failure-patterns.json"
    SCRIPT="$HOME/.claude/scripts/harness-classify-failures.sh"
    cp "$BATS_TEST_DIRNAME/../dot_claude/scripts/executable_harness-classify-failures.sh" "$SCRIPT"
    FIXTURES="$BATS_TEST_DIRNAME/fixtures/harness-detect-failures"
    LEDGER="$HDIR/detections.jsonl"
    RECORDS="$HDIR/classifications.jsonl"
    export PROMPT_LOG="$BATS_TEST_TMPDIR/prompt.txt"
    export ARGV_LOG="$BATS_TEST_TMPDIR/argv.log"
    STUBS="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STUBS"
    install_exec "$STUBS/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$ARGV_LOG"
cat >"$PROMPT_LOG"
mode=${STUB_CLASSIFY:-all:shell-pitfall}
case "$mode" in
all:*)
    answer=$(grep -oE '^\{"id":[0-9]+' "$PROMPT_LOG" | grep -oE '[0-9]+$' |
        jq -R -s -c --arg p "${mode#all:}" 'split("\n") | map(select(length > 0) | {id: tonumber, pattern: $p})')
    jq -n -c --arg r "$answer" '{type: "result", is_error: false, result: $r}'
    ;;
raw) jq -n -c --arg r "$STUB_CLASSIFY_RAW" '{type: "result", is_error: false, result: $r}' ;;
is_error) printf '{"type":"result","is_error":true,"result":"Reached maximum budget"}\n' ;;
esac
EOF
    export PATH="$STUBS:$PATH"
    NOW=$(date +%s)
}

# add_session <session_id> <fixture> [epoch]: fixture を transcript として置き、検出の記録に 1 行足す
add_session() {
    local epoch=${3:-$NOW} counts
    cp "$FIXTURES/$2.jsonl" "$PROJECTS/$1.jsonl"
    counts=$(bash "$HOME/.claude/scripts/harness-detect-failures.sh" "$PROJECTS/$1.jsonl" |
        jq -cs 'group_by(.signal) | map({key: .[0].signal, value: length}) | from_entries')
    printf '{"session_id":"%s","run":"r","date":"d","epoch":%s,"counts":%s}\n' "$1" "$epoch" "$counts" >>"$LEDGER"
}

classify() {
    bash "$SCRIPT" --since "$((NOW - 3600))" --session-id 11111111-2222-3333-4444-555555555555
}

@test "期間内に失敗を検出したセッションの失敗を 1 件 1 行で記録する" {
    add_session err1 tool-error
    add_session ci1 ci-failure
    run --separate-stderr classify
    assert_success
    assert_output 'harness-classify-failures: sessions=2 items=5 classified=5 over_cap=0 missing_transcripts=0'
    run jq -c '{session_id, line, signal, pattern}' "$RECORDS"
    assert_output "$(printf '%s\n' \
        '{"session_id":"err1","line":3,"signal":"tool_error","pattern":"shell-pitfall"}' \
        '{"session_id":"err1","line":5,"signal":"tool_error","pattern":"shell-pitfall"}' \
        '{"session_id":"err1","line":7,"signal":"tool_error","pattern":"shell-pitfall"}' \
        '{"session_id":"ci1","line":3,"signal":"ci_failure","pattern":"shell-pitfall"}' \
        '{"session_id":"ci1","line":5,"signal":"ci_failure","pattern":"shell-pitfall"}')"
    run jq -e --argjson now "$NOW" 'select((.epoch | type) != "number" or .epoch < $now or .run != "11111111-2222-3333-4444-555555555555")' "$RECORDS"
    assert_failure
}

@test "一覧に当てはまらない失敗は unclassified として記録する" {
    add_session err1 tool-error
    STUB_CLASSIFY=all:unclassified run classify
    assert_success
    run jq -r .pattern "$RECORDS"
    assert_output "$(printf '%s\n' unclassified unclassified unclassified)"
}

@test "プロンプトに一覧の id と失敗の前後の抜粋を渡し、記録には抜粋を残さない" {
    add_session err1 tool-error
    run classify
    assert_success
    run cat "$PROMPT_LOG"
    assert_output --partial '- unverified-claim: '
    assert_output --partial '- external-cause: '
    assert_output --partial '"unclassified"'
    assert_output --partial 'cat missing.toml'
    assert_output --partial 'No such file or directory'
    run cat "$RECORDS"
    refute_output --partial 'missing.toml'
}

@test "claude はツールを持たせず、記録を残さない session として起動する" {
    add_session err1 tool-error
    run classify
    assert_success
    run cat "$ARGV_LOG"
    assert_output --regexp '(^| )-p( |$)'
    assert_output --partial '--tools  '
    assert_output --partial '--no-session-persistence'
    assert_output --partial '--session-id 11111111-2222-3333-4444-555555555555'
    assert_output --partial '--max-budget-usd 2'
    assert_output --partial '--output-format json'
    refute_output --partial 'dangerously-skip-permissions'
}

@test "コードフェンスで囲んだ配列も読む" {
    add_session err1 tool-error
    STUB_CLASSIFY=raw STUB_CLASSIFY_RAW=$'```json\n[{"id":1,"pattern":"tool-contract"},{"id":2,"pattern":"tool-contract"},{"id":3,"pattern":"external-cause"}]\n```' \
        run classify
    assert_success
    run jq -r .pattern "$RECORDS"
    assert_output "$(printf '%s\n' tool-contract tool-contract external-cause)"
}

# 形式の違反は、どれも記録を 1 行も書かずに失敗する(分類の一部だけを記録して再発率を歪めない)
@test "項目の id が欠けた出力は拒否し、何も記録しない" {
    add_session err1 tool-error
    STUB_CLASSIFY=raw STUB_CLASSIFY_RAW='[{"id":1,"pattern":"tool-contract"},{"id":2,"pattern":"tool-contract"}]' run classify
    assert_failure
    assert_output --partial 'invalid'
    assert [ ! -s "$RECORDS" ]
}

@test "同じ id を重ねた出力は拒否し、何も記録しない" {
    add_session err1 tool-error
    STUB_CLASSIFY=raw STUB_CLASSIFY_RAW='[{"id":1,"pattern":"tool-contract"},{"id":2,"pattern":"tool-contract"},{"id":2,"pattern":"tool-contract"},{"id":3,"pattern":"tool-contract"}]' run classify
    assert_failure
    assert [ ! -s "$RECORDS" ]
}

@test "一覧に無い pattern の出力は拒否し、何も記録しない" {
    add_session err1 tool-error
    STUB_CLASSIFY=all:made-up-pattern run classify
    assert_failure
    assert_output --partial 'invalid'
    assert [ ! -s "$RECORDS" ]
}

@test "JSON として読めない出力は拒否し、何も記録しない" {
    add_session err1 tool-error
    STUB_CLASSIFY=raw STUB_CLASSIFY_RAW='分類しました: 全部 shell-pitfall です' run classify
    assert_failure
    assert [ ! -s "$RECORDS" ]
}

@test "claude が is_error を返したら失敗し、何も記録しない" {
    add_session err1 tool-error
    STUB_CLASSIFY=is_error run classify
    assert_failure
    assert [ ! -s "$RECORDS" ]
}

@test "分類済みの失敗は渡さず、渡すものが無ければ claude を起動しない" {
    add_session err1 tool-error
    run classify
    assert_success
    rm -f "$ARGV_LOG"
    run --separate-stderr classify
    assert_success
    assert_output 'harness-classify-failures: sessions=1 items=0 classified=0 over_cap=0 missing_transcripts=0'
    assert [ ! -f "$ARGV_LOG" ]
    run wc -l <"$RECORDS"
    assert_output --regexp '^ *3$'
}

@test "期間より前の記録と失敗の無いセッションは分類しない" {
    add_session old1 tool-error "$((NOW - 7200))"
    add_session clean1 clean
    add_session ci1 ci-failure
    run --separate-stderr classify
    assert_success
    assert_output 'harness-classify-failures: sessions=1 items=2 classified=2 over_cap=0 missing_transcripts=0'
    run jq -r .session_id "$RECORDS"
    assert_output "$(printf '%s\n' ci1 ci1)"
}

@test "件数の上限を超えた分は渡さずに数える" {
    add_session err1 tool-error
    add_session ci1 ci-failure
    HARNESS_CLASSIFY_MAX_ITEMS=2 run --separate-stderr classify
    assert_success
    assert_output 'harness-classify-failures: sessions=2 items=2 classified=2 over_cap=3 missing_transcripts=0'
    assert_equal "$(grep -c '^{"id":' "$PROMPT_LOG")" 2
}

@test "transcript が見つからないセッションは飛ばして数える" {
    add_session err1 tool-error
    rm "$PROJECTS/err1.jsonl"
    add_session ci1 ci-failure
    run --separate-stderr classify
    assert_success
    assert_output 'harness-classify-failures: sessions=2 items=2 classified=2 over_cap=0 missing_transcripts=1'
}

@test "一覧が壊れていたら claude を起動せずに失敗する" {
    add_session err1 tool-error
    printf '{"patterns":[{"id":"unclassified","description":"x"}]}\n' >"$HOME/.claude/scripts/harness-failure-patterns.json"
    run classify
    assert_failure
    assert [ ! -f "$ARGV_LOG" ]
}

@test "リポジトリの一覧は決めた形で、unclassified を含まない" {
    run jq -e '.patterns | type == "array" and length > 0
        and all(.[]; (.id | type == "string" and test("^[a-z0-9-]+$")) and (.description | type == "string" and length > 0))
        and (map(.id) | unique | length) == length
        and all(.[]; .id != "unclassified")' "$BATS_TEST_DIRNAME/../dot_claude/scripts/harness-failure-patterns.json"
    assert_success
}

@test "値の無いオプションは使い方の誤りとして 2 で終わる" {
    run bash "$SCRIPT" --since 1 --session-id
    assert_failure 2
    assert_output --partial 'usage:'
}
