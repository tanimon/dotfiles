# ~/.claude/settings.json の hook 配線の契約テスト。
#
# guard hook(git-push-guard / curl-localhost-guard)は ADR 0009 の強制点だが、
# 未配線だと無出力=判定なしでフェイルオープンする。script 単体のテスト
# (test/git-push-guard.bats / test/curl-localhost-guard.bats)は配線を見ないので、
# hooks ブロックから登録を消しても他の suite は緑のまま通る。この suite がその穴を塞ぐ。
#
# seam は 1 つだけ: `chezmoi execute-template --config <test toml> --source <repo>`
# で描画した結果を jq で見る(test/global-instructions.bats と同じ)。Source の
# 文字列を直接 grep しないのは、テンプレートのコメントや分岐を通った後の実体が
# Claude Code の読むものだから。
#
# chezmoi が無い場合は skip せず fail する(skip にすると CI で全検査が空振りする)。
setup() {
    load 'helpers/setup'
    REPO="$BATS_TEST_DIRNAME/.."
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"
    mkdir -p "$TMPDIR"
    CONFIG="$BATS_TEST_TMPDIR/chezmoi-test.toml"
    printf '[data]\n  profile = "personal"\n  ghOrg = "test-org"\n' >"$CONFIG"
    SETTINGS="$BATS_TEST_TMPDIR/settings.json"
    chezmoi execute-template --config "$CONFIG" --source "$REPO" \
        <"$REPO/dot_claude/settings.json.tmpl" >"$SETTINGS"
}

# guard_registrations NAME: PreToolUse で NAME を呼ぶ hook エントリを 1 行 1 JSON で出す
guard_registrations() {
    jq -c --arg cmd "\"\$HOME/.claude/scripts/$1.sh\"" '
        .hooks.PreToolUse[]
        | . as $group
        | .hooks[]
        | select(.command | contains($cmd))
        | {matcher: $group.matcher, type, command, timeout, exact: (.command == $cmd)}
    ' "$SETTINGS"
}

@test "chezmoi が使える(この suite は skip しない)" {
    run command -v chezmoi
    assert_success
}

@test "描画結果が JSON として読める" {
    run jq -e '.hooks | type == "object"' "$SETTINGS"
    assert_success
}

# guard ごとの契約: PreToolUse / matcher Bash / 1 回だけ / wrapper なしの直接呼び出し / timeout あり。
# 直接呼び出しを要求する理由は settings.json.tmpl の該当コメントにある:
# `mkdir -p … && script 2>>log` の形はログの失敗でスクリプト自体が走らず、
# 判定なし=フェイルオープンに化ける。
assert_guard_wired() {
    run guard_registrations "$1"
    assert_success
    [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ] ||
        fail "$1 の PreToolUse 登録がちょうど 1 つではない: $output"
    run jq -e '.matcher == "Bash" and .type == "command" and .exact
        and (.timeout | type == "number" and . > 0)' <<<"$output"
    assert_success
}

@test "git-push-guard が PreToolUse の Bash に直接配線されている" {
    assert_guard_wired git-push-guard
}

@test "curl-localhost-guard が PreToolUse の Bash に直接配線されている" {
    assert_guard_wired curl-localhost-guard
}

@test "hook が呼ぶ script はすべて実行可能な Source として実在する" {
    run jq -r '[.. | objects | select(has("command")) | .command
        | scan("\\.claude/scripts/([A-Za-z0-9._-]+\\.sh)") | .[0]] | unique[]' "$SETTINGS"
    assert_success
    local scripts="$output"
    # 抽出が空なら検査が空振りする。guard 2 本は必ず含まれる
    assert_line git-push-guard.sh
    assert_line curl-localhost-guard.sh
    local name
    while IFS= read -r name; do
        # executable_ prefix が無いと chezmoi は実行権限なしで配置し、hook は起動できない
        [ -f "$REPO/dot_claude/scripts/executable_$name" ] ||
            fail "hook が呼ぶ $name に対応する dot_claude/scripts/executable_$name が無い"
    done <<<"$scripts"
}

# hook が未配線・クラッシュしたときの最後の砦(settings.json.tmpl の deny のコメント参照)
@test "force push の先頭フラグ形が permissions.deny に残っている" {
    local rule
    for rule in 'Bash(git push --force-with-lease:*)' 'Bash(git push --force:*)' 'Bash(git push -f:*)'; do
        jq -e --arg r "$rule" '.permissions.deny | index($r) != null' "$SETTINGS" >/dev/null ||
            fail "permissions.deny に $rule が無い"
    done
}

# orca の agent-hook ディスパッチャは live の ~/.claude/settings.json から verbatim に
# 取り込んだもの(#339)。12 箇所の手作業コピーなので、取りこぼしと食い違いをここで捕まえる。
# Notification と SessionEnd に無いのは取り込み時点の live ファイルの状態で、
# orca 側の意図かどうかは確かめていない。
@test "orca の agent-hook は Notification と SessionEnd を除く全 event に同一のものが 1 つずつある" {
    # 描画結果に現れた event だけを数えると、event ブロックごと消えたときに素通りする。
    # 期待する event を literal で持ち、orca hook を持つ event の集合と完全一致を見る
    local expected='PermissionRequest PostCompact PostToolUse PostToolUseFailure PreToolUse Stop StopFailure SubagentStart SubagentStop TeammateIdle UserPromptSubmit SessionStart'
    run jq -r '[.hooks | to_entries[]
        | select([.value[].hooks[] | select(.command | test("orca/agent-hooks"))] | length == 1)
        | .key] | sort | join(" ")' "$SETTINGS"
    assert_success
    assert_output "$(printf '%s\n' $expected | sort | paste -sd ' ' -)"
    # 2 つ以上持つ event と、1 文字でも違うコピーを捕まえる
    run jq -r '[.hooks[][].hooks[] | select(.command | test("orca/agent-hooks")) | .command] | "\(length) \(unique | length)"' "$SETTINGS"
    assert_output "12 1"
}
