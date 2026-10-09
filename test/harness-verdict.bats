# Verdict の CLI(harness-verdict.sh)の振る舞い検査。
#
# 偽の $HOME に判定の記録(queue-archive.md)だけを置き、サブコマンドの標準出力と終了コードを確かめる。
bats_require_minimum_version 1.5.0

setup() {
    load 'helpers/setup'
    export HOME="$BATS_TEST_TMPDIR/home"
    HDIR="$HOME/.claude/harness"
    ARCHIVE="$HDIR/queue-archive.md"
    mkdir -p "$HDIR"
    SCRIPT="$BATS_TEST_DIRNAME/../dot_claude/scripts/executable_harness-verdict.sh"
    S1=11111111-1111-4111-8111-111111111111
    S2=22222222-2222-4222-8222-222222222222
    URL=https://github.com/example/dotfiles/pull/42
}

# entry <title> <verdict(空なら Verdict 行を書かない)> [Source の行の中身]
entry() {
    printf '## %s\n\n- **What happened:** x\n' "$1" >>"$ARCHIVE"
    [[ -z "${3:-}" ]] || printf -- '- **Source:** %s\n' "$3" >>"$ARCHIVE"
    [[ -z "$2" ]] || printf -- '- **Verdict:** %s\n' "$2" >>"$ARCHIVE"
    printf '\n' >>"$ARCHIVE"
}

@test "entries は adopted・rejected・handoff・merged を構造化した JSON で出す" {
    entry 'published' "adopted (PR $URL) → rules/x.md" "session $S1, $S2"
    entry 'unpublished' 'adopted (harness/review-2026-10-04 run abc)'
    entry 'old mark' 'adopted (harness/review-2026-09-27)'
    entry 'no' 'rejected (duplicate of x)'
    entry 'elsewhere' 'handoff (example/other)'
    entry 'folded' 'merged into published'
    run --separate-stderr bash "$SCRIPT" entries
    assert_success
    assert_equal "${lines[0]}" "{\"title\":\"published\",\"kind\":\"adopted\",\"pr_url\":\"$URL\",\"raw\":\"adopted (PR $URL) → rules/x.md\",\"sources\":[\"$S1\",\"$S2\"]}"
    assert_equal "${lines[1]}" '{"title":"unpublished","kind":"adopted","run":"harness/review-2026-10-04 run abc","raw":"adopted (harness/review-2026-10-04 run abc)","sources":[]}'
    assert_equal "${lines[2]}" '{"title":"old mark","kind":"adopted","run":"harness/review-2026-09-27","raw":"adopted (harness/review-2026-09-27)","sources":[]}'
    assert_equal "${lines[3]}" '{"title":"no","kind":"rejected","arg":"duplicate of x","raw":"rejected (duplicate of x)","sources":[]}'
    assert_equal "${lines[4]}" '{"title":"elsewhere","kind":"handoff","arg":"example/other","raw":"handoff (example/other)","sources":[]}'
    assert_equal "${lines[5]}" '{"title":"folded","kind":"merged","arg":"published","raw":"merged into published","sources":[]}'
    assert_equal "${#lines[@]}" 6
}

@test "括弧の中が PR で始まる採用は run にせず、閉じ括弧の手前までを pr_url にする" {
    entry 'a' "adopted (PR $URL)(allowWrite に追加)"
    entry 'b' "adopted (PR $URL) for (1) | handoff (x/y)"
    entry 'c' "adopted (PR $URL, 補足)"
    run --separate-stderr bash "$SCRIPT" entries
    assert_success
    run jq -c '[.kind, .pr_url, .run]' <<<"$output"
    assert_output "$(printf '["adopted","%s",null]\n' "$URL" "$URL" "$URL, 補足")"
}

@test "PR でも run の印でもない採用の中身は run に入れる" {
    entry 'odd' 'adopted (by hand)'
    run --separate-stderr bash "$SCRIPT" entries
    assert_success
    assert_output '{"title":"odd","kind":"adopted","run":"by hand","raw":"adopted (by hand)","sources":[]}'
}

@test "括弧の無い rejected と Verdict 行の無い項目は unknown として raw 付きで出す" {
    entry 'bare' 'rejected'
    entry 'bare reason' 'rejected — 重複'
    entry 'no verdict' ''
    entry 'bare adopted' 'adopted'
    run --separate-stderr bash "$SCRIPT" entries
    assert_success
    assert_equal "${lines[0]}" '{"title":"bare","kind":"unknown","raw":"rejected","sources":[]}'
    assert_equal "${lines[1]}" '{"title":"bare reason","kind":"unknown","raw":"rejected — 重複","sources":[]}'
    assert_equal "${lines[2]}" '{"title":"no verdict","kind":"unknown","raw":"","sources":[]}'
    assert_equal "${lines[3]}" '{"title":"bare adopted","kind":"unknown","raw":"adopted","sources":[]}'
}

@test "項目ごとに最初の Verdict 行と Source 行を使い、# の見出しで項目を閉じる" {
    cat >"$ARCHIVE" <<EOF
# Archive

## first
- **Source:** session $S1
- **Source:** session $S2
- **Verdict:** rejected (one)
- **Verdict:** adopted (PR $URL)

# 2026-10

- **Verdict:** adopted (PR $URL)
## second
- **Verdict:** handoff (a/b)
EOF
    run --separate-stderr bash "$SCRIPT" entries
    assert_success
    assert_equal "${lines[0]}" "{\"title\":\"first\",\"kind\":\"rejected\",\"arg\":\"one\",\"raw\":\"rejected (one)\",\"sources\":[\"$S1\"]}"
    assert_equal "${lines[1]}" '{"title":"second","kind":"handoff","arg":"a/b","raw":"handoff (a/b)","sources":[]}'
    assert_equal "${#lines[@]}" 2
}

@test "title はタブを空白にするだけで、前後の空白は残す" {
    printf '## a\tb  \n- **Verdict:** rejected (x\ty)\n' >"$ARCHIVE"
    run --separate-stderr bash "$SCRIPT" entries
    assert_success
    assert_output '{"title":"a b  ","kind":"rejected","arg":"x y","raw":"rejected (x y)","sources":[]}'
}

@test "判定の記録が無ければ何も出さずに成功する" {
    run --separate-stderr bash "$SCRIPT" entries
    assert_success
    assert_output ''
}

@test "判定の記録を読めなければ失敗する" {
    mkdir "$ARCHIVE"
    run --separate-stderr bash "$SCRIPT" entries
    assert_failure
    assert_output ''
}

@test "判定の記録がリンク先の無い symlink なら、記録が無いとは読まずに失敗する" {
    ln -s "$HDIR/missing.md" "$ARCHIVE"
    run --separate-stderr bash "$SCRIPT" entries
    assert_failure
    assert_output ''
}

@test "知らないサブコマンドと引数の無い起動は usage で exit 2" {
    run --separate-stderr bash "$SCRIPT" nope
    assert_failure 2
    run --separate-stderr bash "$SCRIPT"
    assert_failure 2
    run --separate-stderr bash "$SCRIPT" entries extra
    assert_failure 2
}
