setup() {
    load 'helpers/setup'
    SCRIPT="$BATS_TEST_DIRNAME/../dot_claude/scripts/executable_git-push-guard.sh"
    # The script opens an error log under $HOME. Point it at the per-test
    # directory so a run never writes into the real home.
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
}

# Run the hook the way Claude Code does: the whole decision comes from the
# PreToolUse payload on stdin.
hook() {
    jq -n --arg c "$1" \
        '{tool_name:"Bash",tool_input:{command:$c}}' | bash "$SCRIPT"
}

decision() {
    printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // empty'
}

# --- the contrast half: everyday pushes must stay prompt-free -----------------
# Without these, a guard that denies unconditionally would pass every test
# below and still make the setting unusable.

@test "bare git push produces no decision" {
    run hook 'git push'
    assert_success
    assert_output ''
}

@test "git push -u origin feature produces no decision" {
    run hook 'git push -u origin feature'
    assert_success
    assert_output ''
}

@test "git push --dry-run produces no decision" {
    run hook 'git push --dry-run origin main'
    assert_success
    assert_output ''
}

@test "explicit non-empty refspec produces no decision" {
    run hook 'git push origin HEAD:refs/heads/main'
    assert_success
    assert_output ''
}

@test "--no-force-with-lease is not matched as a force flag" {
    run hook 'git push --no-force-with-lease origin main'
    assert_success
    assert_output ''
}

@test "a non-git command is ignored even when it carries -f" {
    run hook 'rm -f build/artifact'
    assert_success
    assert_output ''
}

@test "a read-only git subcommand is ignored" {
    run hook 'git log --oneline -n 5'
    assert_success
    assert_output ''
}

@test "the string git push inside another command is not a push" {
    run hook 'echo "git push --force"'
    assert_success
    assert_output ''
}

@test "a safe push in a compound command produces no decision" {
    run hook 'git commit -m wip && git push origin feature'
    assert_success
    assert_output ''
}

# --- deny: the spellings prefix rules cannot reach ----------------------------

@test "leading --force is denied" {
    run hook 'git push --force origin main'
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "trailing --force is denied (evades the prefix deny rule)" {
    run hook 'git push origin main --force'
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "trailing -f is denied" {
    run hook 'git push origin main -f'
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "bundled short options containing f are denied" {
    run hook 'git push -fu origin main'
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "trailing --force-with-lease is denied" {
    run hook 'git push origin main --force-with-lease'
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "--force-with-lease with a value is denied" {
    run hook 'git push origin main --force-with-lease=main:abc123'
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "a plus-prefixed refspec is denied" {
    run hook 'git push origin +main'
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "a quoted plus-prefixed refspec is denied" {
    run hook 'git push origin "+main"'
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "--delete is denied" {
    run hook 'git push --delete origin feature'
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "the colon form of remote branch deletion is denied" {
    run hook 'git push origin :feature'
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "--mirror is denied" {
    run hook 'git push --mirror origin'
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "--prune is denied" {
    run hook 'git push --prune origin main'
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "a force push hidden in the second half of a compound command is denied" {
    run hook 'git commit -m wip && git push origin main --force'
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "a force push after a semicolon is denied" {
    run hook 'git status; git push origin main --force'
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "git -C <dir> push --force is denied" {
    run hook 'git -C /tmp/repo push origin main --force'
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "the deny reason names the offending token" {
    run hook 'git push origin main --force'
    assert_success
    assert_output --partial -- '--force'
}

# Shell punctuation that glues onto a token or splits a segment used to make the
# scan fail open — `(cd dir && git push … --force)` is a routine agent idiom, so
# these are the realistic evasions rather than exotic ones.

@test "a force push inside a subshell group is denied" {
    run hook '(cd /tmp/repo && git push origin main --force)'
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "a force push in a bare subshell is denied" {
    run hook '(git push --force)'
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "a force push in a brace group is denied" {
    run hook '{ git push --force; }'
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "a redirect before the force flag does not split the segment" {
    run hook 'git push origin main 2>&1 --force'
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "a backslash-newline continuation does not split the segment" {
    run hook 'git push origin main \
  --force'
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "a subshell group around a safe push still produces no decision" {
    run hook '(cd /tmp/repo && git push origin feature)'
    assert_success
    assert_output ''
}

# --- ask: fail-closed on what the token scan cannot read ----------------------

@test "a variable in the push segment falls back to ask" {
    run hook 'git push origin $BRANCH'
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "command substitution in the push segment falls back to ask" {
    run hook 'git push origin $(git branch --show-current)'
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "a variable outside the push segment does not trigger ask" {
    run hook 'git commit -m "$(date)" && git push origin feature'
    assert_success
    assert_output ''
}

@test "a -c override mentioning push falls back to ask" {
    run hook 'git -c remote.origin.push=+refs/heads/main push origin'
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "the inline -c form mentioning push falls back to ask" {
    run hook 'git -cremote.origin.push=+refs/heads/main push origin'
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "a -c override unrelated to push does not trigger ask" {
    run hook 'git -c core.pager=cat push origin feature'
    assert_success
    assert_output ''
}

@test "unparseable stdin falls back to ask" {
    run bash -c 'printf "not json" | bash "$1"' _ "$SCRIPT"
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "deny wins over ask when both are present" {
    run hook 'git push origin $BRANCH --force'
    assert_success
    assert_equal "$(decision "$output")" deny
}

# --- shape of the output ------------------------------------------------------

@test "the emitted JSON carries the PreToolUse event name" {
    run hook 'git push origin main --force'
    assert_success
    assert_equal "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')" PreToolUse
}

@test "a non-Bash payload produces no decision" {
    run bash -c 'printf "%s" "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/x\"}}" | bash "$1"' _ "$SCRIPT"
    assert_success
    assert_output ''
}

# --- the segment must be recognized wherever `git` sits in it -----------------
# `eb8ffc5` closed three ways a segment stops starting with `git` (grouping
# punctuation, redirect operators, line continuations). Shell keywords and
# command prefixes are a fourth: they are ordinary tokens that simply precede
# the binary, and a one-line loop or condition is something an agent writes
# routinely.

@test "a one-line for loop body is not a hiding place" {
    run hook 'for r in a b; do git push $r main --force; done'
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "a one-line while loop body is not a hiding place" {
    run hook 'while true; do git push origin main --force; done'
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "a one-line if body is not a hiding place" {
    run hook 'if true; then git push origin main --force; fi'
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "an if condition is not a hiding place" {
    run hook 'if git push origin main --force; then echo done; fi'
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "an environment assignment prefix is not a hiding place" {
    run hook 'GIT_SSH_COMMAND=ssh git push origin main --force'
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "the env wrapper is not a hiding place" {
    run hook 'env GIT_TRACE=1 git push origin main --force'
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "the command wrapper is not a hiding place" {
    run hook 'command git push origin main --force'
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "the time wrapper is not a hiding place" {
    run hook 'time git push origin main --force'
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "the nohup wrapper is not a hiding place" {
    run hook 'nohup git push origin main --force'
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "the sudo wrapper is not a hiding place" {
    run hook 'sudo git push origin main --force'
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "a safe push inside a one-line loop produces no decision" {
    run hook 'for r in a b; do git push origin feature; done'
    assert_success
    assert_output ''
}

# --- the fail-closed floor for an unrecognized command position ---------------
# When `git` is neither in command position nor behind a known prefix, this scan
# cannot tell whether it will execute. A dangerous spelling there becomes `ask`
# rather than silence — and, deliberately, not `deny`: prose in a PR body parses
# the same way.

@test "an unrecognized wrapper carrying a force flag falls back to ask" {
    run hook 'xargs -n1 git push origin main --force'
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "prose naming git push without a dangerous flag produces no decision" {
    run hook 'gh pr create --body "$(cat <<EOF
- git push の ask を外す
EOF
)"'
    assert_success
    assert_output ''
}

@test "prose naming a force push falls back to ask rather than deny" {
    run hook 'gh pr create --body "$(cat <<EOF
- git push --force を deny する
EOF
)"'
    assert_success
    assert_equal "$(decision "$output")" ask
}

# --- config that makes a plain push destructive -------------------------------

@test "a -c mirror override falls back to ask" {
    run hook 'git -c remote.origin.mirror=true push origin'
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "the inline -c mirror form falls back to ask" {
    run hook 'git -cremote.origin.mirror=true push origin'
    assert_success
    assert_equal "$(decision "$output")" ask
}

# --- spellings the scan implements but nothing pinned -------------------------

@test "--force-if-includes is denied" {
    run hook 'git push origin main --force-if-includes'
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "the short -d delete form is denied" {
    run hook 'git push -d origin feature'
    assert_success
    assert_equal "$(decision "$output")" deny
}

# --- logging must never be able to suppress the decision ----------------------

@test "an unwritable HOME does not suppress the decision" {
    [[ $EUID -eq 0 ]] && skip "root ignores the directory mode"
    export HOME="$BATS_TEST_TMPDIR/readonly-home"
    mkdir -p "$HOME"
    chmod 500 "$HOME"
    run hook 'git push origin main --force'
    assert_success
    assert_equal "$(decision "$output")" deny
}

# --- backtick substitution runs, so it is a command and not text --------------

@test "a backtick substitution carrying a force flag is denied" {
    run hook '`git push origin main --force`'
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "a backtick substitution inside another command falls back to ask" {
    run hook 'echo `git push origin main --force`'
    assert_success
    assert_equal "$(decision "$output")" ask
}

# 引用符の外の代入では reader が空白で割るので、`git` は `` x=`git `` の token の途中にある。
@test "a backtick substitution in an assignment carrying a force flag asks" {
    run hook 'x=`git push origin main --force`'
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "a backtick substitution in an assignment running git status produces no decision" {
    run hook 'x=`git status`'
    assert_success
    assert_output ''
}

@test "a harmless backtick assignment before a plain push produces no decision" {
    run hook 'x=`date` && git push origin main'
    assert_success
    assert_output ''
}

# --- shared reader: quotes are read the way bash reads them ------------------

# 2026-09-30 に、この計画を書いている最中のツール呼び出し(heredoc の中の
# "git push and a +N")が現行の guard に deny された。同じ形の誤判定。
@test "separators inside a quoted commit message are not a force push" {
    run hook 'git commit -m "fix; git push --force"'
    assert_success
    assert_output ''
}

@test "a force flag still denies inside a brace expansion" {
    run hook 'git push origin {a,b} --force'
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "a force push inside a quoted substitution asks" {
    run hook 'echo "$(git push origin main --force)"'
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "a short force flag inside a quoted substitution asks" {
    run hook 'echo "$(git push origin main -f)"'
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "a force push swallowed by an unclosed quote asks" {
    run hook $'cat <<EOF\ndon\'t\nEOF\ngit push origin main --force'
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "a quoted substitution without a dangerous spelling produces no decision" {
    run hook 'git commit -m "$(cat <<EOF
- git push の手順を直す
EOF
)" && git push origin feature'
    assert_success
    assert_output ''
}

@test "git push and a +N on different lines of a PR body produce no decision" {
    run hook 'gh pr create --body "$(cat <<EOF
- git push の手順を直す
- +12 行、-3 行
EOF
)"'
    assert_success
    assert_output ''
}

@test "git push with --force on one line of a PR body asks" {
    run hook 'gh pr create --body "$(cat <<EOF
- 誤って git push origin main --force しないようにする
EOF
)"'
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "a missing reader library asks" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cp "$SCRIPT" "$BATS_TEST_TMPDIR/bin/guard.sh"
    run bash -c 'jq -n --arg c "$1" "{tool_name:\"Bash\",tool_input:{command:\$c}}" | bash "$2"' \
        _ 'git push origin feature' "$BATS_TEST_TMPDIR/bin/guard.sh"
    assert_success
    assert_equal "$(decision "$output")" ask
}

# lib が壊れているとき: 空の lib は関数が無いまま exit 127(フェイルオープン)、構文エラーの lib は
# source が exit 2(理由なしのブロック)になっていた。どちらも ask にそろえる。
@test "an empty reader library asks" {
    mkdir -p "$BATS_TEST_TMPDIR/bin/lib"
    cp "$SCRIPT" "$BATS_TEST_TMPDIR/bin/guard.sh"
    : >"$BATS_TEST_TMPDIR/bin/lib/shell-reader.bash"
    run bash -c 'jq -n --arg c "$1" "{tool_name:\"Bash\",tool_input:{command:\$c}}" | bash "$2"' \
        _ 'git push origin feature' "$BATS_TEST_TMPDIR/bin/guard.sh"
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "a reader library with a syntax error asks" {
    mkdir -p "$BATS_TEST_TMPDIR/bin/lib"
    cp "$SCRIPT" "$BATS_TEST_TMPDIR/bin/guard.sh"
    printf '%s\n' 'shell_reader_read() {' >"$BATS_TEST_TMPDIR/bin/lib/shell-reader.bash"
    run bash -c 'jq -n --arg c "$1" "{tool_name:\"Bash\",tool_input:{command:\$c}}" | bash "$2"' \
        _ 'git push origin feature' "$BATS_TEST_TMPDIR/bin/guard.sh"
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "a copy with an intact reader library stays silent for a plain push" {
    mkdir -p "$BATS_TEST_TMPDIR/bin/lib"
    cp "$SCRIPT" "$BATS_TEST_TMPDIR/bin/guard.sh"
    cp "$BATS_TEST_DIRNAME/../dot_claude/scripts/lib/shell-reader.bash" "$BATS_TEST_TMPDIR/bin/lib/"
    run bash -c 'jq -n --arg c "$1" "{tool_name:\"Bash\",tool_input:{command:\$c}}" | bash "$2"' \
        _ 'git push origin feature' "$BATS_TEST_TMPDIR/bin/guard.sh"
    assert_success
    assert_output ''
}

# 長さ超過(8192 byte 超)では reader が token を作らない。字面の床だけを生のコマンドに当てる。
@test "an over-long command with an embedded force push asks" {
    local body
    body=$(printf 'x%.0s' $(seq 1 9000))
    run hook "git commit -m \"${body}\" && git push origin HEAD --force"
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "an over-long PR body mentioning git push --force asks (accepted prose false ask)" {
    local body
    body=$(printf 'x%.0s' $(seq 1 8200))
    run hook "gh pr create --body \"${body} git push --force\""
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "an over-long command with a plain push produces no decision" {
    local body
    body=$(printf 'x%.0s' $(seq 1 8200))
    run hook "gh pr create --body \"${body}\" && git push origin feature"
    assert_success
    assert_output ''
}

@test "an over-long command with the danger flag on a different line produces no decision" {
    local body
    body=$(printf 'x%.0s' $(seq 1 8200))
    run hook "gh pr create --body \"git push の手順
${body} --force は使わない\""
    assert_success
    assert_output ''
}

# -c alias.<name>=… に push を入れると、サブコマンドが push でなくても push になる。
@test "git -c alias carrying push asks even when the subcommand is not push" {
    run hook "git -c alias.p='push --force' p origin main"
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "git -c alias carrying push asks in the joined -c form and in upper case" {
    run hook "git -cALIAS.p='push --force' p origin main"
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "git -c alias without push produces no decision" {
    run hook 'git -c alias.st=status st'
    assert_success
    assert_output ''
}

@test "git -c alias without push next to a plain push produces no decision" {
    run hook 'git -c alias.st=status st && git push origin main'
    assert_success
    assert_output ''
}
