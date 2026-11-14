# issue-linkage-guard: 範囲内のリポジトリで、マーカーの無い gh issue/pr create を deny する。
setup() {
    load 'helpers/setup'
    SCRIPT="$BATS_TEST_DIRNAME/../dot_claude/scripts/executable_issue-linkage-guard.sh"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    unset ISSUE_LINKAGE_GUARD_OWNERS GH_REPO GH_HOST
    REPO_DIR="$BATS_TEST_TMPDIR/repo"
    git init -q "$REPO_DIR"
    git -C "$REPO_DIR" remote add origin https://github.com/tanimon/sample.git
    BODY_DIR="$BATS_TEST_TMPDIR/body"
    mkdir -p "$BODY_DIR"
    MARKER='<!-- issue-linkage -->'
    TAB=$'\t'
    # shell-reader の上限(8192 byte)を超える本文
    LONG_BODY=$(printf 'x%.0s' {1..9000})
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
    [[ "$(reason "$output")" == issue-linkage-guard:* ]]
    # 理由は issue-linkage スキルの SKILL.md とマーカーを案内する
    [[ "$(reason "$output")" == *'~/.claude/skills/issue-linkage/SKILL.md'* ]]
    [[ "$(reason "$output")" == *"$MARKER"* ]]
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
    [[ "$(reason "$output")" == *'bash ~/.claude/skills/issue-linkage/scripts/create-issue.sh'* ]]
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

@test "heredoc の本文に空白を含む二重引用符があってもマーカーがあれば通す" {
    run hook "gh pr create --title t --body \"\$(cat <<'EOF'
See \"foo bar\" here
$MARKER
EOF
)\""
    assert_success
    assert_output ''
}

@test "heredoc の本文に空白を含む二重引用符があり、マーカーが無ければ deny し、本文にマーカーが無いと伝える" {
    run hook "gh pr create --title t --body \"\$(cat <<'EOF'
See \"foo bar\" here
本文
EOF
)\""
    [ "$(decision "$output")" = deny ]
    [[ "$(reason "$output")" == *本文にマーカーが無い* ]]
    [[ "$(reason "$output")" != *コマンド置換* ]]
}

@test "--body の置換の中に heredoc が見つからなければ、置換の中を読めないと伝える" {
    run hook "gh pr create --title t --body \"\$(cat body.md)\""
    [ "$(decision "$output")" = deny ]
    [[ "$(reason "$output")" == *コマンド置換* ]]
}

@test "前置の GH_REPO= で範囲外を指せば何もしない" {
    run hook "GH_REPO=someone-else/sample gh pr create --title t --body x"
    assert_success
    assert_output ''
}

@test "前置の GH_REPO= で範囲内を指せば cwd が範囲外でも判定する" {
    git -C "$REPO_DIR" remote set-url origin https://github.com/someone-else/sample.git
    run hook "GH_REPO=tanimon/sample gh pr create --title t --body x"
    [ "$(decision "$output")" = deny ]
}

@test "-R は前置の GH_REPO= より優先する" {
    run hook "GH_REPO=tanimon/sample gh pr create -R someone-else/sample --title t --body x"
    assert_success
    assert_output ''
}

@test "値を取るオプションの値が -R に見えても作成先として読まない" {
    run hook "gh pr create --label -Rsomeone-else/sample --title t --body x"
    [ "$(decision "$output")" = deny ]
}

@test "upstream remote が範囲外の fork の clone では何もしない" {
    git -C "$REPO_DIR" remote add upstream https://github.com/someone-else/sample.git
    run hook "gh pr create --title t --body x"
    assert_success
    assert_output ''
}

@test "短いオプションに値を続けた -F<path> / -F=<path> / -b<text> も読む" {
    printf 'body\n\n%s\n' "$MARKER" >"$BODY_DIR/pr.md"
    run hook "gh pr create -t t -F$BODY_DIR/pr.md"
    assert_output ''
    run hook "gh pr create -t t -F=$BODY_DIR/pr.md"
    assert_output ''
    run hook "gh pr create -t t '-bx $MARKER'"
    assert_output ''
    printf 'body\n' >"$BODY_DIR/plain.md"
    run hook "gh pr create -t t -F$BODY_DIR/plain.md"
    [ "$(decision "$output")" = deny ]
}

@test "-R に値を続けた形も範囲の判定に使う" {
    run hook "gh pr create -t t -Rsomeone-else/sample -b x"
    assert_output ''
    run hook "gh pr create -t t -Rtanimon/sample -b x"
    [ "$(decision "$output")" = deny ]
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

@test "--title の値が -F で始まっても本文ファイルとして読まない" {
    printf 'body\n\n%s\n' "$MARKER" >"$BODY_DIR/pr.md"
    run hook "gh pr create --body-file $BODY_DIR/pr.md --title '-Fix typo'"
    assert_success
    assert_output ''
}

@test "--title の値が -b で始まりマーカーを含んでも本文として読まない" {
    run hook "gh pr create -t '-b$MARKER' --fill"
    [ "$(decision "$output")" = deny ]
}

@test "--help / -h / --dry-run は作成しないので判定しない" {
    run hook "gh pr create --help"
    assert_output ''
    run hook "gh issue create -h"
    assert_output ''
    run hook "gh pr create --fill --dry-run"
    assert_output ''
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

# --- heredoc で本文ファイルを書いた直後の gh pr create(対) ---

@test "heredoc で書いた本文ファイルにマーカーがあれば、直後の pr create は通す" {
    run hook "cat > $BODY_DIR/pr.md <<'EOF2'
body

$MARKER
EOF2
gh pr create --title t --body-file $BODY_DIR/pr.md"
    assert_success
    assert_output ''
}

@test "heredoc で書いた本文ファイルにマーカーが無ければ、直後の pr create は deny" {
    run hook "cat > $BODY_DIR/pr.md <<'EOF2'
body
EOF2
gh pr create --title t --body-file $BODY_DIR/pr.md"
    assert_success
    [ "$(decision "$output")" = deny ]
    [[ "$(reason "$output")" == issue-linkage-guard:* ]]
}

@test "heredoc の本文に引用符が閉じない apostrophe があっても、直後の pr create は判定する" {
    run hook "cat > $BODY_DIR/pr.md <<'EOF2'
don't forget
EOF2
gh pr create --title t --body-file $BODY_DIR/pr.md"
    assert_success
    [ "$(decision "$output")" = deny ]
}

@test "heredoc が書いたのとは別の本文ファイルを渡す pr create は、ファイルを読んで判定する" {
    printf 'body\n' >"$BODY_DIR/other.md"
    run hook "cat > $BODY_DIR/pr.md <<'EOF2'
$MARKER
EOF2
gh pr create --title t --body-file $BODY_DIR/other.md"
    assert_success
    [ "$(decision "$output")" = deny ]
}

@test "heredoc の後の gh pr create が --fill でも deny" {
    run hook "cat > $BODY_DIR/pr.md <<'EOF2'
$MARKER
EOF2
gh pr create --fill"
    assert_success
    [ "$(decision "$output")" = deny ]
}

@test "heredoc の本文の行にある gh pr create は、後ろに別のコマンドがあっても対象外" {
    run hook "cat > $BODY_DIR/pr.md <<'EOF2'
gh pr create --title t
EOF2
echo done"
    assert_success
    assert_output ''
}

# --- heredoc の終端行の読み方(対) ---

@test "<< の本文にあるタブ付きの区切り語は終端行ではないので、その後ろの本文の行は対象外" {
    run hook "cat > $BODY_DIR/pr.md <<'EOF2'
line
${TAB}EOF2
gh pr create --title t
EOF2
echo done"
    assert_success
    assert_output ''
}

@test "<<- ではタブ付きの区切り語が終端行なので、その後ろの pr create は判定する" {
    run hook "cat > $BODY_DIR/pr.md <<-'EOF2'
${TAB}line
${TAB}EOF2
gh pr create --fill"
    assert_success
    [ "$(decision "$output")" = deny ]
}

@test "区切り語に - を含む heredoc の後ろの pr create も判定する" {
    run hook "cat > $BODY_DIR/pr.md <<'EOF-2'
body
EOF-2
gh pr create --fill"
    assert_success
    [ "$(decision "$output")" = deny ]
}

@test "区切り語に - を含む heredoc の本文の行にある gh pr create は対象外" {
    run hook "cat > $BODY_DIR/pr.md <<'EOF-2'
gh pr create --fill
EOF-2
echo done"
    assert_success
    assert_output ''
}

@test "--body の heredoc の本文にあるタブ付きの区切り語は終端行とみなさず、その後ろのマーカーも読む" {
    # 空白を含む二重引用符で、マーカーを --body の値の token から外し、生の COMMAND から本文を読ませる
    run hook "gh pr create --title t --body \"\$(cat <<'EOF'
See \"foo bar\" here
${TAB}EOF
$MARKER
EOF
)\""
    assert_success
    assert_output ''
}

# --- heredoc の本文を本文ファイルとみなす条件(対) ---

@test "1 行に heredoc が 2 つあるとき、本文ファイルを書く方の heredoc の本文を読む" {
    run hook "cat <<X >/dev/null; cat > $BODY_DIR/pr.md <<'EOF2'
x
X
$MARKER
EOF2
gh pr create --title t --body-file $BODY_DIR/pr.md"
    assert_success
    assert_output ''
}

@test "1 行に heredoc が 2 つあり、本文ファイルを書く方の本文にマーカーが無ければ deny" {
    run hook "cat <<X >/dev/null; cat > $BODY_DIR/pr.md <<'EOF2'
$MARKER
X
body
EOF2
gh pr create --title t --body-file $BODY_DIR/pr.md"
    assert_success
    [ "$(decision "$output")" = deny ]
}

@test "heredoc を tee で本文ファイルに書いたときも、その本文を読む" {
    run hook "cat <<'EOF2' | tee $BODY_DIR/pr.md >/dev/null
$MARKER
EOF2
gh pr create --title t --body-file $BODY_DIR/pr.md"
    assert_success
    assert_output ''
}

@test "heredoc が本文ファイルを > で上書きするなら、ディスクにマーカーがあっても heredoc の本文で判定する" {
    printf '%s\n' "$MARKER" >"$BODY_DIR/pr.md"
    run hook "cat > $BODY_DIR/pr.md <<'EOF2'
body
EOF2
gh pr create --title t --body-file $BODY_DIR/pr.md"
    assert_success
    [ "$(decision "$output")" = deny ]
}

@test "heredoc が本文ファイルに >> で追記するなら、ディスクのファイルを読む" {
    printf '%s\n' "$MARKER" >"$BODY_DIR/pr.md"
    run hook "cat >> $BODY_DIR/pr.md <<'EOF2'
body
EOF2
gh pr create --title t --body-file $BODY_DIR/pr.md"
    assert_success
    assert_output ''
}

@test "heredoc の行で本文ファイルを読むだけなら、ディスクのファイルを読む" {
    printf '%s\n' "$MARKER" >"$BODY_DIR/pr.md"
    run hook "cat $BODY_DIR/pr.md - <<'EOF2'
body
EOF2
gh pr create --title t --body-file $BODY_DIR/pr.md"
    assert_success
    assert_output ''
}

@test "pr create の後で heredoc が本文ファイルを書くなら、ディスクのファイルを読む" {
    printf '%s\n' "$MARKER" >"$BODY_DIR/pr.md"
    run hook "gh pr create --title t --body-file $BODY_DIR/pr.md && cat > $BODY_DIR/pr.md <<'EOF2'
body
EOF2"
    assert_success
    assert_output ''
}

# --- 全体を読み切れないとき(対) ---

@test "全体が長すぎても、heredoc の終端行の後ろの pr create は判定する" {
    run hook "cat > $BODY_DIR/pr.md <<'EOF2'
$LONG_BODY
EOF2
gh pr create --fill"
    assert_success
    [ "$(decision "$output")" = deny ]
}

@test "全体が長すぎても、heredoc で書いた本文ファイルにマーカーがあれば通す" {
    run hook "cat > $BODY_DIR/pr.md <<'EOF2'
$LONG_BODY
$MARKER
EOF2
gh pr create --title t --body-file $BODY_DIR/pr.md"
    assert_success
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
