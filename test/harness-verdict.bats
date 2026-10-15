# Verdict の CLI(harness-verdict.sh)の振る舞い検査。
#
# 偽の $HOME に判定の記録(queue-archive.md)だけを置き、サブコマンドの標準出力と終了コードを確かめる。
bats_require_minimum_version 1.5.0

setup() {
    load 'helpers/setup'
    export HOME="$BATS_TEST_TMPDIR/home"
    HDIR="$HOME/.claude/harness"
    ARCHIVE="$HDIR/queue-archive.md"
    QUEUE="$HDIR/queue.md"
    mkdir -p "$HDIR"
    # settle が読む環境変数を、このマシンのシェルから漏らさない
    unset HARNESS_REVIEW_RUN
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

# --- settle ---

# queue に項目を置く。queue_entry <見出し> [What happened の中身]
queue_entry() {
    [[ -f "$QUEUE" ]] || printf '# Harness improvement queue\n\nAppended by /harness-reflect.\n\n' >"$QUEUE"
    printf '## %s\n\n- **What happened:** %s\n- **Source:** session %s\n\n' "$1" "${2:-x}" "$S1" >>"$QUEUE"
}

settle() {
    run --separate-stderr bash "$SCRIPT" settle "$@"
}

# 書き換えが無いことを、実行前に取った写しとの byte 単位の比較で確かめる
snapshot() {
    cp "$QUEUE" "$BATS_TEST_TMPDIR/queue.before"
    rm -f "$BATS_TEST_TMPDIR/archive.before"
    [[ ! -f "$ARCHIVE" ]] || cp "$ARCHIVE" "$BATS_TEST_TMPDIR/archive.before"
}

assert_unchanged() {
    cmp "$QUEUE" "$BATS_TEST_TMPDIR/queue.before"
    if [[ -f "$BATS_TEST_TMPDIR/archive.before" ]]; then
        cmp "$ARCHIVE" "$BATS_TEST_TMPDIR/archive.before"
    else
        assert [ ! -e "$ARCHIVE" ]
    fi
}

# settle が exit 2 で止まり、queue も archive も書き換えないことを確かめる
assert_rejected() {
    run --separate-stderr bash "$SCRIPT" settle "$@"
    [[ "$status" -eq 2 ]] || fail "expected exit 2 for settle $* (got $status: $stderr)"
    assert_unchanged
}

@test "settle は 4 つの kind それぞれで項目を queue から archive の末尾へ移し、Verdict 行を付ける" {
    queue_entry 'a1'
    queue_entry 'a2'
    queue_entry 'r'
    queue_entry 'h'
    queue_entry 'm'
    queue_entry 'keep'
    HARNESS_REVIEW_RUN='harness/review-2026-10-10 run abc' settle --title 'a1' adopted
    assert_success
    settle --title 'a2' adopted --pr-url "$URL"
    assert_success
    settle --title 'r' rejected 'duplicate of rules/x.md'
    assert_success
    settle --title 'h' handoff 'example/other'
    assert_success
    settle --title 'm' merged 'a1'
    assert_success
    run --separate-stderr bash "$SCRIPT" entries
    assert_success
    run jq -r '[.title, .raw] | @tsv' <<<"$output"
    assert_output "$(printf '%s\t%s\n' a1 'adopted (harness/review-2026-10-10 run abc)' a2 "adopted (PR $URL)" \
        r 'rejected (duplicate of rules/x.md)' h 'handoff (example/other)' m 'merged into a1')"
    run grep '^## ' "$QUEUE"
    assert_output '## keep'
}

@test "settle は項目の本文をそのまま移し、末尾の空行の代わりに Verdict 行を付けて前の項目と空行で区切る" {
    printf '## old\n- **Verdict:** rejected (x)\n' >"$ARCHIVE"
    queue_entry 'new' 'what'
    queue_entry 'next'
    settle --title 'new' rejected 'why'
    assert_success
    assert_output ''
    run cat "$ARCHIVE"
    assert_output "$(printf '## old\n- **Verdict:** rejected (x)\n\n## new\n\n- **What happened:** what\n- **Source:** session %s\n- **Verdict:** rejected (why)' "$S1")"
    run cat "$QUEUE"
    assert_output "$(printf '# Harness improvement queue\n\nAppended by /harness-reflect.\n\n## next\n\n- **What happened:** x\n- **Source:** session %s' "$S1")"
}

@test "見出しと merged の統合先は ) を含んでよい(merged into は行末まで読む)" {
    queue_entry 'glob は `(N)` ではなく'
    queue_entry 'other (2)'
    settle --title 'other (2)' merged 'glob は `(N)` ではなく'
    assert_success
    run --separate-stderr bash "$SCRIPT" entries
    assert_output "{\"title\":\"other (2)\",\"kind\":\"merged\",\"arg\":\"glob は \`(N)\` ではなく\",\"raw\":\"merged into glob は \`(N)\` ではなく\",\"sources\":[\"$S1\"]}"
}

@test "見出しを変えずに同じ見出しへ merged すると、見出しを変える手順を添えて exit 2" {
    printf '## x\n\n- **What happened:** earlier\n- **Verdict:** rejected (why)\n' >"$ARCHIVE"
    queue_entry 'x' 'later'
    run --separate-stderr bash "$SCRIPT" settle --title 'x' merged 'x'
    assert_failure 2
    assert_equal "$stderr" "harness-verdict: an entry cannot be merged into itself. To merge it into an earlier entry with the same title in $ARCHIVE, rename only its '## ' line in $QUEUE (e.g. append the date) and settle it under the new title with merged 'x'; nothing written"
}

@test "merged の統合先は archive にあってもよい" {
    printf '## done\n- **Verdict:** rejected (x)\n' >"$ARCHIVE"
    queue_entry 'later'
    settle --title 'later' merged 'done'
    assert_success
    run grep -c '^## later$' "$ARCHIVE"
    assert_output '1'
}

@test "settle は書き込みの前に誤りを見つけたら、queue も archive も書き換えずに exit 2 で止まる" {
    queue_entry 'dup'
    queue_entry 'dup'
    queue_entry 'one'
    printf '## old\n- **Verdict:** rejected (x)\n' >"$ARCHIVE"
    snapshot
    local nl=$'a\nb'
    assert_rejected --title missing rejected x
    assert_rejected --title dup rejected x
    assert_rejected --title one nope x
    assert_rejected --title one rejected
    assert_rejected --title one rejected ''
    assert_rejected --title one rejected 'a)b'
    assert_rejected --title one handoff 'a)b'
    assert_rejected --title one rejected "$nl"
    assert_rejected --title "$nl" rejected x
    assert_rejected --title one merged nowhere
    assert_rejected --title one merged "$nl"
    assert_rejected --title one merged one
    assert_rejected --title one adopted
    assert_rejected --title one adopted --pr-url ''
    assert_rejected --title one adopted --pr-url 'https://x/1)'
    assert_rejected --title one adopted extra --pr-url "$URL"
    assert_rejected --title one rejected x --pr-url "$URL"
    assert_rejected --title one rejected x y
    assert_rejected --title '' rejected x
    assert_rejected one rejected x
    assert_rejected --title one
    assert_rejected --title
    # adopted の印は環境変数か --pr-url のどちらか 1 つだけで、空や ) を含む値は使わない
    export HARNESS_REVIEW_RUN='b run 1'
    assert_rejected --title one adopted --pr-url "$URL"
    export HARNESS_REVIEW_RUN=''
    assert_rejected --title one adopted --pr-url "$URL"
    assert_rejected --title one adopted
    export HARNESS_REVIEW_RUN='b run 1)'
    assert_rejected --title one adopted
}

@test "archive への追記の後に止まった項目は、再実行で queue からの削除だけを行う" {
    queue_entry 'x'
    queue_entry 'y'
    cp "$QUEUE" "$BATS_TEST_TMPDIR/queue.orig"
    settle --title 'x' rejected 'why'
    assert_success
    # queue からの削除の前に止まった状態(archive にはあり、queue にも残っている)
    cp "$BATS_TEST_TMPDIR/queue.orig" "$QUEUE"
    cp "$ARCHIVE" "$BATS_TEST_TMPDIR/archive.once"
    settle --title 'x' rejected 'why'
    assert_success
    cmp "$ARCHIVE" "$BATS_TEST_TMPDIR/archive.once"
    run grep -c '^## x$' "$ARCHIVE"
    assert_output '1'
    run grep '^## ' "$QUEUE"
    assert_output '## y'
}

@test "再実行で Verdict が前回と違えば、何も書き換えずに exit 2" {
    queue_entry 'x'
    cp "$QUEUE" "$BATS_TEST_TMPDIR/queue.orig"
    settle --title 'x' rejected 'why'
    assert_success
    cp "$BATS_TEST_TMPDIR/queue.orig" "$QUEUE"
    snapshot
    assert_rejected --title 'x' rejected 'other reason'
    assert_rejected --title 'x' adopted --pr-url "$URL"
}

@test "同じ見出しの別の項目が archive にあれば、再実行とは読まずに exit 2" {
    printf '## x\n\n- **What happened:** earlier\n- **Verdict:** rejected (why)\n' >"$ARCHIVE"
    queue_entry 'x' 'later'
    snapshot
    assert_rejected --title 'x' rejected 'why'
}

# 書き戻す直前の比較(cmp)の前に、並行する /harness-reflect の追記を再現する偽の cmp を置く。
# 最初の STUB_CMP_SKIP 回(既定 0)の後、呼ばれるたびに STUB_CMP_TARGET(既定 queue)に 1 項目足し(STUB_CMP_TIMES 回まで)、本物の cmp を呼ぶ
install_racing_cmp() {
    local real_cmp
    real_cmp=$(command -v cmp)
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat >"$BATS_TEST_TMPDIR/bin/cmp" <<STUB
#!/usr/bin/env bash
count=\$(cat "$BATS_TEST_TMPDIR/cmp.count" 2>/dev/null || echo 0)
printf '%s\n' \$((count + 1)) >"$BATS_TEST_TMPDIR/cmp.count"
added=\$((count - \${STUB_CMP_SKIP:-0}))
if [[ "\$added" -ge 0 && "\$added" -lt "\$STUB_CMP_TIMES" ]]; then
    printf '## reflected %s\n\n- **What happened:** y\n\n' "\$added" >>"\${STUB_CMP_TARGET:-$QUEUE}"
fi
exec "$real_cmp" "\$@"
STUB
    chmod +x "$BATS_TEST_TMPDIR/bin/cmp"
}

@test "書き戻す直前に queue が変わっていたら作り直し、並行する追記を失わない" {
    queue_entry 'x'
    install_racing_cmp
    STUB_CMP_TIMES=1 PATH="$BATS_TEST_TMPDIR/bin:$PATH" run --separate-stderr bash "$SCRIPT" settle --title 'x' rejected 'why'
    assert_success
    run grep '^## ' "$QUEUE"
    assert_output '## reflected 0'
    run grep -c '^## x$' "$ARCHIVE"
    assert_output '1'
}

@test "queue が 3 回続けて変わっていたら、何も書かずに exit 1" {
    queue_entry 'x'
    install_racing_cmp
    snapshot
    STUB_CMP_TIMES=3 PATH="$BATS_TEST_TMPDIR/bin:$PATH" run --separate-stderr bash "$SCRIPT" settle --title 'x' rejected 'why'
    assert_failure 1
    assert [ ! -e "$ARCHIVE" ]
    # queue は並行する追記が足されただけで、x は残る
    run grep '^## ' "$QUEUE"
    assert_output "$(printf '## x\n## reflected 0\n## reflected 1\n## reflected 2')"
    run head -c "$(wc -c <"$BATS_TEST_TMPDIR/queue.before")" "$QUEUE"
    assert_output "$(cat "$BATS_TEST_TMPDIR/queue.before")"
}

@test "判定の記録が 3 回続けて変わっていたら、判定の記録が変わったと伝えて何も書かずに exit 1" {
    queue_entry 'x'
    printf '## old\n- **Verdict:** rejected (x)\n' >"$ARCHIVE"
    install_racing_cmp
    cp "$QUEUE" "$BATS_TEST_TMPDIR/queue.before"
    STUB_CMP_TARGET="$ARCHIVE" STUB_CMP_TIMES=99 PATH="$BATS_TEST_TMPDIR/bin:$PATH" run --separate-stderr bash "$SCRIPT" settle --title 'x' rejected 'why'
    assert_failure 1
    assert_equal "$stderr" "harness-verdict: $ARCHIVE kept changing while settling '## x' (3 times); nothing written"
    cmp "$QUEUE" "$BATS_TEST_TMPDIR/queue.before"
    run grep -c '^## x$' "$ARCHIVE"
    assert_output '0'
}

@test "判定の記録への追記の後に queue が変わっていたら、作り直して queue からの削除だけを行う" {
    queue_entry 'x'
    install_racing_cmp
    # 1 回目の比較(追記の前)は通し、2 回目(queue からの削除の前)で追記を起こす
    STUB_CMP_SKIP=1 STUB_CMP_TIMES=1 PATH="$BATS_TEST_TMPDIR/bin:$PATH" run --separate-stderr bash "$SCRIPT" settle --title 'x' rejected 'why'
    assert_success
    run grep '^## ' "$QUEUE"
    assert_output '## reflected 0'
    run grep -c '^## x$' "$ARCHIVE"
    assert_output '1'
}

@test "判定の記録への追記の後に queue が変わり続けたら、追記済みで queue に残ったと伝えて exit 1" {
    queue_entry 'x'
    install_racing_cmp
    STUB_CMP_SKIP=1 STUB_CMP_TIMES=3 PATH="$BATS_TEST_TMPDIR/bin:$PATH" run --separate-stderr bash "$SCRIPT" settle --title 'x' rejected 'why'
    assert_failure 1
    assert_equal "$stderr" "harness-verdict: $QUEUE kept changing while settling '## x'; it was appended to $ARCHIVE but is still in $QUEUE (run the same settle again to remove it)"
    run grep -c '^## x$' "$ARCHIVE"
    assert_output '1'
    run grep '^## ' "$QUEUE"
    assert_output "$(printf '## x\n## reflected 0\n## reflected 1\n## reflected 2')"
}

@test "settle は置き換える queue と判定の記録の mode を保つ" {
    queue_entry 'x'
    printf '## old\n- **Verdict:** rejected (x)\n' >"$ARCHIVE"
    chmod 644 "$QUEUE" "$ARCHIVE"
    settle --title 'x' rejected 'why'
    assert_success
    run ls -l "$QUEUE" "$ARCHIVE"
    assert_line --index 0 --regexp '^-rw-r--r--'
    assert_line --index 1 --regexp '^-rw-r--r--'
}

@test "判定の記録を新しく作るときは、umask どおりの mode にする" {
    queue_entry 'x'
    umask 022
    settle --title 'x' rejected 'why'
    assert_success
    run ls -l "$ARCHIVE"
    assert_output --regexp '^-rw-r--r--'
}

@test "同じ見出しの別の項目で止まったときは、queue の見出しを変える手順を伝える" {
    printf '## x\n\n- **What happened:** earlier\n- **Verdict:** rejected (why)\n' >"$ARCHIVE"
    queue_entry 'x' 'later'
    settle --title 'x' rejected 'why'
    assert_failure 2
    [[ "$stderr" == *"rename only its '## ' line in $QUEUE"* ]] || fail "no recovery hint: $stderr"
}

@test "コードフェンスの中の # の行では項目を切らず、Verdict 行とも読まない" {
    queue_entry 'before'
    printf '## fenced\n\n- **What happened:** x\n\n```sh\n# comment\n- **Verdict:** rejected (example)\n```\n\n- **Source:** session %s\n\n' "$S1" >>"$QUEUE"
    queue_entry 'after'
    settle --title 'fenced' rejected 'why'
    assert_success
    run grep -c 'comment' "$QUEUE"
    assert_output '0'
    run grep '^## ' "$QUEUE"
    assert_output "$(printf '## before\n## after')"
    run --separate-stderr bash "$SCRIPT" entries
    assert_success
    assert_output "{\"title\":\"fenced\",\"kind\":\"rejected\",\"arg\":\"why\",\"raw\":\"rejected (why)\",\"sources\":[\"$S1\"]}"
}

@test "閉じ忘れたコードフェンスは次の ## の見出しで閉じ、後ろの項目を飲み込まない" {
    printf '## open\n\n```sh\n# comment\n- **Verdict:** rejected (inside)\n\n## next\n- **Verdict:** handoff (a/b)\n\n# 2026-10\n\n- **Verdict:** adopted (PR %s)\n' "$URL" >"$ARCHIVE"
    run --separate-stderr bash "$SCRIPT" entries
    assert_success
    assert_equal "${lines[0]}" '{"title":"open","kind":"unknown","raw":"","sources":[]}'
    assert_equal "${lines[1]}" '{"title":"next","kind":"handoff","arg":"a/b","raw":"handoff (a/b)","sources":[]}'
    assert_equal "${#lines[@]}" 2
}

# --- publish / adopted / unpublished ---

RUN='harness/review-2026-10-10 run aaaa'

@test "adopted はその run の印を持つ項目の見出しだけを出す" {
    entry 'mine 1' "adopted ($RUN)"
    entry 'other run' 'adopted (harness/review-2026-10-10 run bbbb)'
    entry 'published' "adopted (PR $URL)"
    entry 'no' 'rejected (x)'
    entry 'mine 2' "adopted ($RUN) → rules/x.md"
    entry 'old mark' 'adopted (harness/review-2026-10-10)'
    run --separate-stderr bash "$SCRIPT" adopted --run "$RUN"
    assert_success
    assert_output "$(printf 'mine 1\nmine 2')"
}

@test "adopted は判定の記録が無ければ何も出さずに成功する" {
    run --separate-stderr bash "$SCRIPT" adopted --run "$RUN"
    assert_success
    assert_output ''
}

@test "publish はその run の印だけを PR の URL に置き換え、件数を出す" {
    entry 'mine 1' "adopted ($RUN)"
    entry 'other run' 'adopted (harness/review-2026-10-10 run bbbb)'
    entry 'published' 'adopted (PR https://github.com/example/dotfiles/pull/1)'
    entry 'mine 2' "adopted ($RUN) → rules/x.md"
    run --separate-stderr bash "$SCRIPT" adopted --run "$RUN"
    assert_output "$(printf 'mine 1\nmine 2')"
    run --separate-stderr bash "$SCRIPT" publish --run "$RUN" --pr-url "$URL"
    assert_success
    assert_output '2'
    run --separate-stderr bash "$SCRIPT" entries
    run jq -r '[.title, .kind, (.pr_url // "-"), (.run // "-"), .raw] | join("|")' <<<"$output"
    assert_output "$(printf '%s\n' \
        "mine 1|adopted|$URL|-|adopted (PR $URL)" \
        'other run|adopted|-|harness/review-2026-10-10 run bbbb|adopted (harness/review-2026-10-10 run bbbb)' \
        'published|adopted|https://github.com/example/dotfiles/pull/1|-|adopted (PR https://github.com/example/dotfiles/pull/1)' \
        "mine 2|adopted|$URL|-|adopted (PR $URL) → rules/x.md")"
    run --separate-stderr bash "$SCRIPT" adopted --run "$RUN"
    assert_output ''
}

@test "publish は Verdict 行だけを書き換え、本文やコードフェンスの中の同じ文字列は残す" {
    {
        printf '## a\n\n- **What happened:** wrote adopted (%s) by hand\n' "$RUN"
        printf '```\n- **Verdict:** adopted (%s)\n```\n' "$RUN"
        printf -- '- **Verdict:** adopted (%s)\n- **Verdict:** adopted (%s)\n' "$RUN" "$RUN"
    } >"$ARCHIVE"
    run --separate-stderr bash "$SCRIPT" publish --run "$RUN" --pr-url "$URL"
    assert_success
    assert_output '1'
    run cat "$ARCHIVE"
    assert_output "$(printf '%s\n' '## a' '' \
        "- **What happened:** wrote adopted ($RUN) by hand" \
        '```' "- **Verdict:** adopted ($RUN)" '```' \
        "- **Verdict:** adopted (PR $URL)" "- **Verdict:** adopted ($RUN)")"
}

@test "publish は置き換える印が無ければ 0 を出して成功し、判定の記録を書き換えない" {
    entry 'a' "adopted (PR $URL)"
    cp "$ARCHIVE" "$BATS_TEST_TMPDIR/archive.before"
    run --separate-stderr bash "$SCRIPT" publish --run "$RUN" --pr-url "$URL"
    assert_success
    assert_output '0'
    cmp "$ARCHIVE" "$BATS_TEST_TMPDIR/archive.before"
    rm "$ARCHIVE"
    run --separate-stderr bash "$SCRIPT" publish --run "$RUN" --pr-url "$URL"
    assert_success
    assert_output '0'
    assert [ ! -e "$ARCHIVE" ]
}

@test "publish は判定の記録の mode を保つ" {
    entry 'a' "adopted ($RUN)"
    chmod 640 "$ARCHIVE"
    run --separate-stderr bash "$SCRIPT" publish --run "$RUN" --pr-url "$URL"
    assert_success
    # stat の書式は BSD と GNU で違う(GNU の -f はファイルシステムの情報を出して成功する)ので ls で見る
    run ls -l "$ARCHIVE"
    assert_output --regexp '^-rw-r-----'
}

@test "publish と adopted の引数の誤りは、判定の記録を書き換えずに exit 2" {
    entry 'a' "adopted ($RUN)"
    entry 'published' "adopted (PR $URL)"
    cp "$ARCHIVE" "$BATS_TEST_TMPDIR/archive.before"
    local args
    for args in \
        "publish|--pr-url|$URL" \
        "publish|--run|$RUN" \
        "publish|--run||--pr-url|$URL" \
        "publish|--run|$RUN|--pr-url|" \
        "publish|--run|$RUN|--pr-url|$URL)" \
        "publish|--run|a)b|--pr-url|$URL" \
        "publish|--run|$RUN|--pr-url|$URL|extra" \
        "publish|--run" \
        'adopted' \
        'adopted|--run|' \
        'adopted|--run|a)b' \
        "publish|--run|PR $URL|--pr-url|$URL/2" \
        "adopted|--run|PR $URL" \
        "adopted|--run|$RUN|extra" \
        'unpublished|--branch|' \
        'unpublished|--branch|a)b' \
        'unpublished|extra'; do
        IFS='|' read -r -a argv <<<"$args"
        run --separate-stderr bash "$SCRIPT" "${argv[@]}"
        [[ "$status" -eq 2 ]] || fail "expected exit 2 for $args (got $status)"
        cmp "$ARCHIVE" "$BATS_TEST_TMPDIR/archive.before"
    done
    run --separate-stderr bash "$SCRIPT" publish --run "$(printf 'a\nb')" --pr-url "$URL"
    assert_failure 2
    cmp "$ARCHIVE" "$BATS_TEST_TMPDIR/archive.before"
}

@test "unpublished は PR になっていない採用の印を、重複を除いて出す" {
    entry 'a' "adopted ($RUN)"
    entry 'b' "adopted ($RUN)"
    entry 'old mark' 'adopted (harness/review-2026-09-27)'
    entry 'published' "adopted (PR $URL)"
    entry 'no' 'rejected (x)'
    entry 'odd' 'adopted (by hand)'
    run --separate-stderr bash "$SCRIPT" unpublished
    assert_success
    assert_output "$(printf '%s\n' "$RUN" 'harness/review-2026-09-27' 'by hand')"
}

@test "unpublished --branch は新旧 2 つの形の印だけに絞り、名前がそのブランチで始まる別のブランチは含めない" {
    entry 'new' 'adopted (harness/review-2026-10-04 run abc)'
    entry 'old' 'adopted (harness/review-2026-10-04)'
    entry 'manual' 'adopted (harness/review-2026-10-04-manual run x)'
    entry 'manual old' 'adopted (harness/review-2026-10-04-manual)'
    entry 'other' 'adopted (harness/review-2026-10-11 run abc)'
    entry 'published' "adopted (PR $URL)"
    run --separate-stderr bash "$SCRIPT" unpublished --branch harness/review-2026-10-04
    assert_success
    assert_output "$(printf '%s\n' 'harness/review-2026-10-04 run abc' 'harness/review-2026-10-04')"
    run --separate-stderr bash "$SCRIPT" unpublished --branch harness/review-2026-10-25
    assert_success
    assert_output ''
}

@test "unpublished は判定の記録が無ければ何も出さずに成功し、読めなければ失敗する" {
    run --separate-stderr bash "$SCRIPT" unpublished
    assert_success
    assert_output ''
    ln -s "$BATS_TEST_TMPDIR/missing" "$ARCHIVE"
    run --separate-stderr bash "$SCRIPT" unpublished
    assert_failure 1
    run --separate-stderr bash "$SCRIPT" adopted --run "$RUN"
    assert_failure 1
    run --separate-stderr bash "$SCRIPT" publish --run "$RUN" --pr-url "$URL"
    assert_failure 1
}

@test "publish は書き戻す直前に判定の記録が変わっていたら作り直し、3 回続けば何も書かずに exit 1" {
    entry 'a' "adopted ($RUN)"
    install_racing_cmp
    STUB_CMP_TARGET="$ARCHIVE" STUB_CMP_TIMES=1 PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
        run --separate-stderr bash "$SCRIPT" publish --run "$RUN" --pr-url "$URL"
    assert_success
    assert_output '1'
    run grep -c -e '^## reflected 0$' -e "^- \*\*Verdict:\*\* adopted (PR $URL)\$" "$ARCHIVE"
    assert_output '2'

    rm -f "$BATS_TEST_TMPDIR/cmp.count"
    entry 'b' "adopted ($RUN)"
    STUB_CMP_TARGET="$ARCHIVE" STUB_CMP_TIMES=3 PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
        run --separate-stderr bash "$SCRIPT" publish --run "$RUN" --pr-url "$URL"
    assert_failure 1
    assert_equal "$stderr" "harness-verdict: $ARCHIVE kept changing while publishing '$RUN' (3 times); nothing written"
    run grep -c "^- \*\*Verdict:\*\* adopted ($RUN)\$" "$ARCHIVE"
    assert_output '1'
}
