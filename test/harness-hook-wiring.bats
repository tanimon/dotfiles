# 改善ループの入口になる hook の配線の契約テスト(ADR 0011)。
#
# briefing と reflect トリガーの配線を、ループの PR から外せないようにする。このテストを Guarded Path に
# 載せる理由は scripts/guarded-paths.txt の「改善ループ自身」の節。
#
# 描画と chezmoi が無いときの扱いは test/settings-hooks.bats と同じく test/helpers/render.bash に任せる。
setup_file() {
    load 'helpers/render'
    export TMPDIR="$BATS_FILE_TMPDIR/tmp"
    mkdir -p "$TMPDIR"
    export SETTINGS="$BATS_FILE_TMPDIR/settings.json"
    render_template personal "$RENDER_REPO/dot_claude/settings.json.tmpl" >"$SETTINGS"
}

setup() {
    load 'helpers/setup'
}

# loop_registrations EVENT NAME: EVENT で NAME を呼ぶ hook エントリを 1 行 1 JSON で出す。
# extra は type / command / timeout 以外のキー(async や if は配線を残したまま起動を変える)
loop_registrations() {
    jq -c --arg event "$1" --arg script "\"\$HOME/.claude/scripts/$2.sh\"" '
        .hooks[$event][]?
        | . as $group
        | .hooks[]
        | select((.command // "") | contains($script))
        | {matcher: ($group.matcher // ""), type, extra: (keys - ["type", "command", "timeout"])}
    ' "$SETTINGS"
}

# assert_loop_wired EVENT NAME MATCHER_JQ: ちょうど 1 つ配線され、matcher が MATCHER_JQ を満たす
assert_loop_wired() {
    run loop_registrations "$1" "$2"
    assert_success
    [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ] ||
        fail "$2 の $1 の登録がちょうど 1 つではない: $output"
    run jq -e ".type == \"command\" and .extra == [] and ($3)" <<<"$output"
    assert_success
}

@test "disableAllHooks で hook 全体を止めていない" {
    run jq -e '(.disableAllHooks // false) == false' "$SETTINGS"
    assert_success
}

# briefing の無出力が「hook が死んでいる」合図になるので、起動のたびに走る必要がある
@test "harness-briefing が SessionStart の startup に配線されている" {
    assert_loop_wired SessionStart harness-briefing '.matcher | split("|") | index("startup") != null'
}

@test "harness-reflect-trigger がすべての SessionEnd に配線されている" {
    assert_loop_wired SessionEnd harness-reflect-trigger '.matcher == "" or .matcher == "*"'
}
