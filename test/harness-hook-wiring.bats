# 改善ループの入口になる hook の配線の契約テスト(ADR 0011)。
#
# briefing と reflect トリガーの配線を、ループの PR から外せないようにする。このテストを Guarded Path に
# 載せる理由は scripts/guarded-paths.txt の「改善ループ自身」の節。
#
# settings.json.tmpl はループが変えてよいので、profile ごとの分岐で片方の profile でだけ配線を外す変更も
# ありうる。そのため test/fixtures/ の全 profile で描画して検査する。
#
# 描画と chezmoi が無いときの扱いは test/settings-hooks.bats と同じく test/helpers/render.bash に任せる。
PROFILES=(personal work)

setup_file() {
    load 'helpers/render'
    export TMPDIR="$BATS_FILE_TMPDIR/tmp"
    mkdir -p "$TMPDIR"
    local profile
    for profile in "${PROFILES[@]}"; do
        render_template "$profile" "$RENDER_REPO/dot_claude/settings.json.tmpl" >"$BATS_FILE_TMPDIR/settings-$profile.json"
    done
}

setup() {
    load 'helpers/setup'
}

# loop_registrations SETTINGS EVENT NAME: EVENT で NAME を呼ぶ hook エントリを 1 行 1 JSON で出す。
# extra は type / command / timeout 以外のキー(async や if は配線を残したまま起動を変える)
loop_registrations() {
    jq -c --arg event "$2" --arg script "\"\$HOME/.claude/scripts/$3.sh\"" '
        .hooks[$event][]?
        | . as $group
        | .hooks[]
        | select((.command // "") | contains($script))
        | {matcher: ($group.matcher // ""), type, command, extra: (keys - ["type", "command", "timeout"])}
    ' "$1"
}

# expected_command NAME: NAME を起動する command の全文。パスを含むかだけを見ると、
# `true || "<script>"` のようにパスを残したまま実行しない command に書き換えても通るので、全文で照合する
expected_command() {
    printf '%s' "bash -c 'mkdir -p \"\$HOME/.claude/logs\" && \"\$HOME/.claude/scripts/$1.sh\" 2>>\"\$HOME/.claude/logs/harness-errors.log\" || true'"
}

# assert_loop_wired EVENT NAME MATCHER_JQ: 全 profile で、ちょうど 1 つ配線され、command が expected_command と
# 一致し、matcher が MATCHER_JQ を満たす
assert_loop_wired() {
    local profile
    for profile in "${PROFILES[@]}"; do
        run loop_registrations "$BATS_FILE_TMPDIR/settings-$profile.json" "$1" "$2"
        assert_success
        [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ] ||
            fail "$profile: $2 の $1 の登録がちょうど 1 つではない: $output"
        run jq -e --arg command "$(expected_command "$2")" \
            ".type == \"command\" and .command == \$command and .extra == [] and ($3)" <<<"$output"
        assert_success
    done
}

@test "disableAllHooks で hook 全体を止めていない" {
    local profile
    for profile in "${PROFILES[@]}"; do
        run jq -e '(.disableAllHooks // false) == false' "$BATS_FILE_TMPDIR/settings-$profile.json"
        assert_success
    done
}

# briefing の無出力が「hook が死んでいる」合図になるので、起動のたびに走る必要がある
@test "harness-briefing が SessionStart の startup に配線されている" {
    assert_loop_wired SessionStart harness-briefing '.matcher | split("|") | index("startup") != null'
}

@test "harness-reflect-trigger がすべての SessionEnd に配線されている" {
    assert_loop_wired SessionEnd harness-reflect-trigger '.matcher == "" or .matcher == "*"'
}
