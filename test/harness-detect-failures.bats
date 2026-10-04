# 失敗の検出器(harness-detect-failures.sh)の振る舞い検査。
#
# fixture は手書きの合成 transcript(test/fixtures/harness-detect-failures/)。実際の transcript は
# 仕事のセッションを含みうるので、公開リポジトリに写さない。
# 出力は「検出 1 件 = 1 行の JSON」なので、行ごとに完全一致で比べる。
bats_require_minimum_version 1.5.0

setup() {
    load 'helpers/setup'
    SCRIPT="$BATS_TEST_DIRNAME/../dot_claude/scripts/executable_harness-detect-failures.sh"
    FIXTURES="$BATS_TEST_DIRNAME/fixtures/harness-detect-failures"
}

detect() {
    bash "$SCRIPT" "$FIXTURES/$1.jsonl"
}

@test "人の否定: 発言の先頭の否定を検出する(origin の無い古い形式も)" {
    run --separate-stderr detect negation
    assert_success
    assert_output "$(printf '%s\n' \
        '{"line":3,"signal":"user_negation"}' \
        '{"line":5,"signal":"user_negation"}')"
}

@test "中断: 並列のツールの中断と直後の中断の文は 1 件に数え、人の発言の後の中断は別に数える" {
    run --separate-stderr detect interrupt
    assert_success
    assert_output "$(printf '%s\n' \
        '{"line":4,"signal":"user_interrupt"}' \
        '{"line":9,"signal":"user_interrupt"}')"
}

@test "ツール実行の拒否: 拒否の直後の中断の文は数えない" {
    run --separate-stderr detect rejection
    assert_success
    assert_output '{"line":3,"signal":"user_rejection"}'
}

@test "hook の deny を tool_error ではなく hook_deny として検出する" {
    run --separate-stderr detect hook-deny
    assert_success
    assert_output '{"line":3,"signal":"hook_deny"}'
}

@test "CI の赤: gh の失敗を tool_error ではなく ci_failure として検出する(エラーでない結果も)" {
    run --separate-stderr detect ci-failure
    assert_success
    assert_output "$(printf '%s\n' \
        '{"line":3,"signal":"ci_failure"}' \
        '{"line":5,"signal":"ci_failure"}')"
}

@test "ツールのエラー: auto mode の拒否は人の拒否ではなく tool_error に数える" {
    run --separate-stderr detect tool-error
    assert_success
    assert_output "$(printf '%s\n' \
        '{"line":3,"signal":"tool_error"}' \
        '{"line":5,"signal":"tool_error"}' \
        '{"line":7,"signal":"tool_error"}')"
}

@test "繰り返し: 同じツール呼び出しが 3 回続いた時点で 1 件、4 回目は数えない" {
    run --separate-stderr detect repeat
    assert_success
    assert_output '{"line":7,"signal":"repeat"}'
}

@test "失敗を含まない transcript では何も検出しない(紛らわしい形と壊れた行を含む)" {
    run --separate-stderr detect clean
    assert_success
    assert_output ''
}

@test "同じ入力には同じ出力を返す" {
    run --separate-stderr detect interrupt
    first=$output
    run --separate-stderr detect interrupt
    assert_equal "$output" "$first"
}

@test "読めない transcript では exit 2 で理由を出す" {
    run --separate-stderr bash "$SCRIPT" "$BATS_TEST_TMPDIR/missing.jsonl"
    assert_failure 2
    assert_output ''
    [[ "$stderr" == *missing.jsonl* ]]
}

@test "引数が無ければ exit 2" {
    run --separate-stderr bash "$SCRIPT"
    assert_failure 2
}
