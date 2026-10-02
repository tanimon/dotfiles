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
# Claude Code の読むものだから。hook が呼ぶ script の配置だけは同じ config で
# `chezmoi source-path` に解決させる(.chezmoiignore と属性 prefix の解釈を chezmoi に任せるため)。
#
# chezmoi が無い場合は skip せず fail する(skip にすると CI で全検査が空振りする)。
# 描画は suite 全体で 1 回だけ行う(どの test も同じ描画結果を読むだけなので)
setup_file() {
    export REPO="$BATS_TEST_DIRNAME/.."
    export TMPDIR="$BATS_FILE_TMPDIR/tmp"
    mkdir -p "$TMPDIR"
    export CONFIG="$BATS_FILE_TMPDIR/chezmoi-test.toml"
    printf '[data]\n  profile = "personal"\n  ghOrg = "test-org"\n' >"$CONFIG"
    export DEST="$BATS_FILE_TMPDIR/home"
    mkdir -p "$DEST"
    export SETTINGS="$BATS_FILE_TMPDIR/settings.json"
    chezmoi execute-template --config "$CONFIG" --source "$REPO" \
        <"$REPO/dot_claude/settings.json.tmpl" >"$SETTINGS"
}

setup() {
    load 'helpers/setup'
}

# guard_registrations NAME: PreToolUse で NAME を呼ぶ hook エントリを 1 行 1 JSON で出す。
# extra は type / command / timeout 以外のキー(`async: true` は判定を捨てて
# バックグラウンドで走らせ、`if` は起動条件を絞る — どちらも配線を残したまま guard を無効化する)
guard_registrations() {
    jq -c --arg cmd "\"\$HOME/.claude/scripts/$1.sh\"" '
        .hooks.PreToolUse[]
        | . as $group
        | .hooks[]
        | select((.command // "") | contains($cmd))
        | {matcher: $group.matcher, type, command, timeout, exact: (.command == $cmd),
            extra: (keys - ["type", "command", "timeout"])}
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

# 配線が全部残っていても、この 1 行で全 hook が止まり guard ごとフェイルオープンする
@test "disableAllHooks で hook 全体を止めていない" {
    run jq -e '(.disableAllHooks // false) == false' "$SETTINGS"
    assert_success
}

# guard ごとの契約: PreToolUse / matcher Bash / 1 回だけ / wrapper なしの直接呼び出し / timeout あり /
# async や if のような起動・判定を変えるキーを持たない。
# 直接呼び出しを要求する理由は settings.json.tmpl の該当コメントにある:
# `mkdir -p … && script 2>>log` の形はログの失敗でスクリプト自体が走らず、
# 判定なし=フェイルオープンに化ける。
assert_guard_wired() {
    run guard_registrations "$1"
    assert_success
    [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ] ||
        fail "$1 の PreToolUse 登録がちょうど 1 つではない: $output"
    run jq -e '.matcher == "Bash" and .type == "command" and .exact
        and (.timeout | type == "number" and . > 0) and .extra == []' <<<"$output"
    assert_success
}

@test "git-push-guard が PreToolUse の Bash に直接配線されている" {
    assert_guard_wired git-push-guard
}

@test "curl-localhost-guard が PreToolUse の Bash に直接配線されている" {
    assert_guard_wired curl-localhost-guard
}

@test "hook が呼ぶ script はすべて chezmoi が実行可能として配置する" {
    # 拡張子と subdirectory を問わず拾う(lib/ 配下や .sh 以外を呼ぶ hook も検査から漏らさない)
    run jq -r '[.hooks[][].hooks[] | (.command // "")
        | scan("\\.claude/scripts/([A-Za-z0-9._/-]+\\.[A-Za-z0-9]+)") | .[0]] | unique[]' "$SETTINGS"
    assert_success
    local scripts="$output"
    # 抽出が空なら検査が空振りする。guard 2 本は必ず含まれる
    assert_line git-push-guard.sh
    assert_line curl-localhost-guard.sh
    local name source
    while IFS= read -r name; do
        # Source の有無を自前の命名規則で推測せず chezmoi に解決させる。
        # .chezmoiignore で除外された target も "not managed" で失敗するので、
        # 「Source はあるがデプロイされない」も捕まえる
        source=$(chezmoi source-path --config "$CONFIG" --source "$REPO" \
            --destination "$DEST" "$DEST/.claude/scripts/$name") ||
            fail "hook が呼ぶ $name を chezmoi が配置しない(Source が無いか .chezmoiignore で除外されている)"
        # executable_ 属性が無いと chezmoi は実行権限なしで配置し、hook は起動できない
        case "${source##*/}" in
        *executable_*) ;;
        *) fail "hook が呼ぶ $name の Source $source に executable_ 属性が無い" ;;
        esac
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
    local expected=(PermissionRequest PostCompact PostToolUse PostToolUseFailure PreToolUse Stop StopFailure SubagentStart SubagentStop TeammateIdle UserPromptSubmit SessionStart)
    run jq -r '[.hooks | to_entries[]
        | select([.value[].hooks[] | select((.command // "") | test("orca/agent-hooks"))] | length == 1)
        | .key] | sort | join(" ")' "$SETTINGS"
    assert_success
    assert_output "$(printf '%s\n' "${expected[@]}" | sort | paste -sd ' ' -)"
    # 2 つ以上持つ event と、1 文字でも違うコピーを捕まえる
    run jq -r '[.hooks[][].hooks[] | select((.command // "") | test("orca/agent-hooks")) | .command] | "\(length) \(unique | length)"' "$SETTINGS"
    assert_output "${#expected[@]} 1"
    # matcher が絞られると orca はその event の大半を受け取れなくなる。全件一致(省略・"" ・"*")だけを許す
    run jq -r '[.hooks[][] | select(any(.hooks[]; (.command // "") | test("orca/agent-hooks")))
        | (.matcher // "") | if . == "" then "*" else . end] | unique | join(" ")' "$SETTINGS"
    assert_output "*"
}
