# ticket-guard: 範囲内のリポジトリで、マーカーの無い gh issue/pr create を deny する。
setup() {
    load 'helpers/setup'
    SCRIPT="$BATS_TEST_DIRNAME/../dot_claude/scripts/executable_ticket-guard.sh"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    unset TICKET_GUARD_OWNERS
    REPO_DIR="$BATS_TEST_TMPDIR/repo"
    git init -q "$REPO_DIR"
    git -C "$REPO_DIR" remote add origin https://github.com/tanimon/sample.git
    BODY_DIR="$BATS_TEST_TMPDIR/body"
    mkdir -p "$BODY_DIR"
    MARKER='<!-- ticket-skill -->'
}

# Claude Code と同じく、判定のすべてを stdin の PreToolUse payload から得る。
hook() {
    jq -n --arg c "$1" --arg d "${2:-$REPO_DIR}" \
        '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' | bash "$SCRIPT"
}

decision() {
    printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // empty'
}

reason() {
    printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty'
}

# --- 対: マーカーの有無 ---

@test "body-file にマーカーがある pr create は通す" {
    printf 'body\n\n%s\n' "$MARKER" >"$BODY_DIR/pr.md"
    run hook "gh pr create --title t --body-file $BODY_DIR/pr.md"
    assert_success
    assert_output ''
}

@test "body-file にマーカーが無い pr create は deny" {
    printf 'body\n' >"$BODY_DIR/pr.md"
    run hook "gh pr create --title t --body-file $BODY_DIR/pr.md"
    assert_success
    [ "$(decision "$output")" = deny ]
    [[ "$(reason "$output")" == ticket-guard:* ]]
}

@test "--body にマーカーがある pr create は通す" {
    run hook "gh pr create --title t --body 'x $MARKER'"
    assert_success
    assert_output ''
}

@test "--body にマーカーが無い pr create は deny" {
    run hook "gh pr create --title t --body 'x'"
    assert_success
    [ "$(decision "$output")" = deny ]
}

@test "範囲内の issue create はマーカーがあっても create-issue.sh へ案内して deny" {
    run hook "gh issue create --title t --body 'x $MARKER'"
    [ "$(decision "$output")" = deny ]
    [[ "$(reason "$output")" == *create-issue.sh* ]]
}

@test "-F 短縮形と --body-file= 形も読む" {
    printf '%s\n' "$MARKER" >"$BODY_DIR/p.md"
    run hook "gh pr create -t t -F $BODY_DIR/p.md"
    assert_output ''
    run hook "gh pr create -t t --body-file=$BODY_DIR/p.md"
    assert_output ''
}

@test "heredoc で本文を渡してもマーカーがあれば通す" {
    run hook "gh pr create --title t --body \"\$(cat <<'EOF'
本文
$MARKER
EOF
)\""
    assert_success
    assert_output ''
}

@test "-b 短縮形と --body= 形も読む" {
    run hook "gh pr create -t t -b 'x $MARKER'"
    assert_output ''
    run hook "gh pr create -t t '--body=x $MARKER'"
    assert_output ''
}

@test "マーカーが --title にあっても --body に無ければ deny" {
    run hook "gh pr create --title '$MARKER' --body x"
    [ "$(decision "$output")" = deny ]
}

@test "連結された別の segment にマーカーがあっても deny" {
    run hook "gh pr create --fill; echo '$MARKER'"
    [ "$(decision "$output")" = deny ]
}

@test "--fill はマーカーが無いので deny" {
    run hook "gh pr create --fill"
    [ "$(decision "$output")" = deny ]
}

# --- 対: 範囲 ---

@test "許可リスト外の origin では何もしない" {
    git -C "$REPO_DIR" remote set-url origin https://github.com/someone-else/sample.git
    run hook "gh pr create --title t --body x"
    assert_success
    assert_output ''
}

@test "許可リスト外では issue create も何もしない" {
    git -C "$REPO_DIR" remote set-url origin https://github.com/someone-else/sample.git
    run hook "gh issue create --title t --body x"
    assert_output ''
}

@test "-R で範囲外のリポジトリを指せば何もしない" {
    run hook "gh pr create -R someone-else/sample --title t --body x"
    assert_output ''
}

@test "-R で範囲内のリポジトリを指せば cwd が範囲外でも判定する" {
    git -C "$REPO_DIR" remote set-url origin https://github.com/someone-else/sample.git
    run hook "gh pr create --repo tanimon/sample --title t --body x"
    [ "$(decision "$output")" = deny ]
}

@test "git リポジトリでない cwd では何もしない" {
    run hook "gh pr create --title t --body x" "$BATS_TEST_TMPDIR"
    assert_output ''
}

# --- 読めない body-file ---

@test "body-file が相対パスなら理由付きで deny" {
    run hook "gh pr create --title t --body-file pr.md"
    [ "$(decision "$output")" = deny ]
    [[ "$(reason "$output")" == *絶対パス* ]]
}

@test "body-file が変数を含むなら理由付きで deny" {
    run hook 'gh pr create --title t --body-file "$TMPDIR/pr.md"'
    [ "$(decision "$output")" = deny ]
    [[ "$(reason "$output")" == *変数* ]]
}

@test "body-file がチルダで始まるならチルダの理由で deny" {
    run hook "gh pr create --title t --body-file ~/pr.md"
    [ "$(decision "$output")" = deny ]
    [[ "$(reason "$output")" == *チルダ* ]]
}

@test "body-file が標準入力なら deny" {
    run hook "gh pr create --title t --body-file -"
    [ "$(decision "$output")" = deny ]
}

@test "body-file が存在しなければ deny" {
    run hook "gh pr create --title t --body-file $BODY_DIR/missing.md"
    [ "$(decision "$output")" = deny ]
}

# --- 作成コマンドではないもの ---

@test "連結された作成コマンドも判定する" {
    run hook "cd $REPO_DIR && git push && gh pr create --title t --body x"
    [ "$(decision "$output")" = deny ]
}

@test "VAR=value の前置があっても判定する" {
    run hook "GH_PROMPT_DISABLED=1 gh issue create --title t --body x"
    [ "$(decision "$output")" = deny ]
}

@test "if の then の後ろの作成コマンドも判定する" {
    run hook "if true; then gh pr create --title t --body x; fi"
    [ "$(decision "$output")" = deny ]
}

@test "if / while の条件にある作成コマンドも判定する" {
    run hook "if gh pr create --fill; then echo ok; fi"
    [ "$(decision "$output")" = deny ]
    run hook "while gh pr create --fill; do break; done"
    [ "$(decision "$output")" = deny ]
    run hook "if false; then :; elif gh pr create --fill; then :; fi"
    [ "$(decision "$output")" = deny ]
}

@test "command 前置の作成コマンドも判定する" {
    run hook "command gh issue create --title t --body x"
    [ "$(decision "$output")" = deny ]
}

@test "! と then の後ろでもマーカーがあれば通す" {
    run hook "if ! gh pr view; then gh pr create --title t --body 'x $MARKER'; fi"
    assert_success
    assert_output ''
}

@test "alias の gh pr new も判定する" {
    run hook "gh pr new --title t --body x"
    [ "$(decision "$output")" = deny ]
}

@test "gh pr edit は対象外" {
    run hook "gh pr edit 1 --body x"
    assert_output ''
}

@test "引用符の中の gh pr create は対象外" {
    run hook 'git commit -m "gh pr create を直す"'
    assert_output ''
}

@test "heredoc の本文の行にある gh pr create は対象外" {
    run hook "git commit -F - <<'EOF'
gh pr create --title t
EOF"
    assert_output ''
}

@test "gh を含まないコマンドは無出力" {
    run hook "ls -la"
    assert_output ''
}

@test "引用符が閉じないコマンドは判定せず通す" {
    run hook "gh pr create --title 't"
    assert_output ''
}
