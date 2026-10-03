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
# シェルのキーワードとコマンド前置詞は binary の前に立つ普通の token で、1 行のループや
# 条件はエージェントが日常的に書く。

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

# `` x=`git status` `` 単独では `push` を含まず早期終了で終わるので、reader に届く形にする。
# バッククォートの後ろに git を見つけ、push ではないので何も返さない経路を通る。
@test "a backtick assignment running git status before a plain push produces no decision" {
    run hook 'x=`git status` && git push origin feature'
    assert_success
    assert_output ''
}

@test "a backtick substitution in an assignment running a plain push produces no decision" {
    run hook 'x=`git push origin main`'
    assert_success
    assert_output ''
}

# strict=0(git がコマンド位置に無い)でも、push の引数の `$` / バッククォートは ask にする。
# 変数が --force を運ぶ場合、バッククォートで包むだけで素通りしていた。
@test "a backtick assignment pushing a variable asks" {
    run hook 'x=`git push origin $r`'
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "a backtick substitution inside another command pushing a variable asks" {
    run hook 'echo `git push origin $r`'
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "a quoted string naming git push with a variable produces no decision" {
    run hook 'echo "git push origin $r"'
    assert_success
    assert_output ''
}

@test "a PR body in a quoted heredoc naming git push produces no decision" {
    run hook "gh pr create --body \"\$(cat <<'EOF'
- git push の手順を直す
EOF
)\""
    assert_success
    assert_output ''
}

@test "a harmless backtick assignment before a plain push produces no decision" {
    run hook 'x=`date` && git push origin main'
    assert_success
    assert_output ''
}

# --- shared reader: quotes are read the way bash reads them ------------------

# 引用符の中の区切り(`;`)は segment を切らない。
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

@test "a brace expansion that produces a force spelling asks" {
    local command
    for command in \
        'git push origin {main,--force}' \
        'git push origin main{,\ --force}' \
        'git push origin -{f..f} main'; do
        run hook "$command"
        assert_success
        assert_equal "$(decision "$output")" ask
    done
}

@test "a brace group around a plain push produces no decision" {
    run hook '{ git push origin main; }'
    assert_success
    assert_output ''
}

@test "a brace expansion in another segment does not affect a plain push" {
    run hook 'mkdir -p build/{a,b} && git push origin main'
    assert_success
    assert_output ''
}

# reader の segment 区切りの番兵と同じ byte。bash には普通の文字なので、redirect 先の
# ファイル名になって `--force` は git の引数のまま残る。
@test "the separator byte in the input asks instead of splitting the push" {
    run hook "git push origin main 2>"$'\x01'" --force"
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "an abbreviated destructive long option is denied" {
    local option
    for option in --dele --mirr --pru --force-w --force-w=origin/main --force-i; do
        run hook "git push $option origin victim"
        assert_success
        assert_equal "$(decision "$output")" deny
    done
}

@test "long options that are not prefixes of a destructive one produce no decision" {
    local option
    for option in --progress --porcelain --follow-tags --no-force-with-lease --no-verify; do
        run hook "git push $option origin main"
        assert_success
        assert_output ''
    done
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

# `--config-env alias.p=VAR` の値は環境変数の名前で、展開先の `push --force` はコマンド文字列に現れない。
@test "git --config-env alias asks because its value is read from the environment" {
    run hook "A='push --force' git --config-env=alias.p=A p origin main"
    assert_success
    assert_equal "$(decision "$output")" ask
    run hook "A='push --force' git --config-env alias.p=A p origin main"
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "git --config-env with a non-alias, non-push key before a plain push produces no decision" {
    run hook 'git --config-env=core.editor=EDITOR push origin main'
    assert_success
    assert_output ''
}

# include.path は読めないファイルの設定(remote.<name>.mirror=true など)を取り込む。
@test "git -c include.path before a push asks" {
    run hook 'git -c include.path=/tmp/extra.cfg push origin main'
    assert_success
    assert_equal "$(decision "$output")" ask
}

# push の segment ごとにコマンド全体の token を走査していたので、segment の多い 8 KB 近い入力で
# 5 秒(フックの timeout)を越え、判定なし = フェイルオープンになっていた。
@test "a force push followed by many push segments is denied well within the hook timeout" {
    local command='git push origin main --force' start elapsed
    while [[ ${#command} -lt 8180 ]]; do command+=';git push'; done
    start=$SECONDS
    run hook "$command"
    elapsed=$((SECONDS - start))
    assert_success
    assert_equal "$(decision "$output")" deny
    [[ $elapsed -lt 3 ]]
}

# `>|` は noclobber を無視する redirect で、パイプではない。`--force` は git の引数のまま。
@test "a force flag after a >| redirect is denied" {
    run hook 'git push origin main >| out --force'
    assert_success
    assert_equal "$(decision "$output")" deny
}

# プロセス置換の `)` の後ろは git の引数の続き。
@test "a force flag after a process substitution asks" {
    run hook 'git push origin <(echo) --force'
    assert_success
    assert_equal "$(decision "$output")" ask
}

# 走査とシェルの引用符の状態がずれる綴り。ANSI-C は reader が正しく読むので deny、
# heredoc / コメントは reader が知らないので字面の床で ask。
@test "a force push hidden by ANSI-C quoting is denied" {
    run hook "echo \$'\\''; git push origin main --force; echo \\'"
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "a force push between two comments with a quote asks" {
    run hook $'echo x #"\ngit push origin main --force\n#"'
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "a force push between two heredocs with a lone quote asks" {
    run hook "cat <<'EOF' > a.txt
it\"s
EOF
git push origin main --force
cat <<'EOF' > b.txt
it\"s
EOF"
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "a multi-line commit message before a plain push produces no decision" {
    run hook $'git commit -m "multi\nline" && git push origin main'
    assert_success
    assert_output ''
}

@test "\$\$ before a quoted word and a plain push produces no decision" {
    run hook "echo \$\$'x'; git push origin main"
    assert_success
    assert_output ''
}

# zsh の EQUALS: `=git` は PATH 上の git に展開される(Bash ツールが zsh で動く環境)。
@test "a force push through zsh =git is denied" {
    run hook '=git push origin main --force'
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "a plain push through zsh =git produces no decision" {
    run hook '=git push origin main'
    assert_success
    assert_output ''
}

# 展開の結果としてだけ binary やサブコマンドが現れる綴り。
@test "a brace expansion that builds the push subcommand asks" {
    run hook 'git {push,origin,main,--force}'
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "a brace expansion that builds the git binary asks" {
    run hook '{git,push,origin,main,--force}'
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "a glob that builds the git binary asks" {
    run hook '/usr/bin/gi? push origin main --force'
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "a glob in the push arguments asks" {
    run hook 'git push origin main -?'
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "a brace or glob in another segment than a plain push produces no decision" {
    run hook 'echo {a,b} && ls *.md && git push origin main'
    assert_success
    assert_output ''
}

# 印を見るのはコマンドの位置とサブコマンドだけ。引数の glob と push という語の組み合わせは巻き込まない。
@test "a glob argument next to the word push outside git produces no decision" {
    run hook 'grep -n push dot_claude/scripts/*.sh'
    assert_success
    assert_output ''
    run hook "rg 'git push' docs/*.md"
    assert_success
    assert_output ''
    run hook 'pnpm exec bats test/git-push-*.bats'
    assert_success
    assert_output ''
}

@test "a brace expansion that builds git behind env asks" {
    run hook 'env {git,push,origin,main,--force}'
    assert_success
    assert_equal "$(decision "$output")" ask
}

# git の設定キーは大文字小文字を区別しない。
@test "git -c push or mirror config in upper case asks" {
    run hook 'git -c remote.origin.MIRROR=true push origin'
    assert_success
    assert_equal "$(decision "$output")" ask
    run hook 'git -cREMOTE.origin.PUSH=+refs/heads/main push origin'
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "git -c unrelated config before a plain push produces no decision" {
    run hook 'git -c core.editor=vim push origin main'
    assert_success
    assert_output ''
}

# GIT_CONFIG_* の環境変数は -c と同じ設定を運ぶ。
@test "GIT_CONFIG environment assignments before a push ask" {
    run hook 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.mirror GIT_CONFIG_VALUE_0=true git push origin'
    assert_success
    assert_equal "$(decision "$output")" ask
    run hook 'export GIT_CONFIG_COUNT=1; git push origin'
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "an unrelated GIT_ environment assignment before a plain push produces no decision" {
    run hook 'GIT_TRACE=1 git push origin main'
    assert_success
    assert_output ''
}

# --attr-source は値を別の token に取る。
@test "a force push after --attr-source <tree> is denied" {
    run hook 'git --attr-source HEAD push origin main --force'
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "a plain push after --attr-source <tree> produces no decision" {
    run hook 'git --attr-source HEAD push origin main'
    assert_success
    assert_output ''
}

# 読み切れない別の segment(プロセス置換)があっても、読み切れた force push は deny のまま。
@test "a force push next to an unrelated process substitution is denied" {
    run hook 'git push origin main --force; cat <(true)'
    assert_success
    assert_equal "$(decision "$output")" deny
}

# 字面の床は引用符と backslash を外してから見る。
@test "a force push in a substitution with a quote-split verb asks" {
    run hook "echo \"\$(git'' push origin main --force)\""
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "a plain push in a substitution with a quote-split verb produces no decision" {
    run hook "echo \"\$(git'' push origin main)\""
    assert_success
    assert_output ''
}

@test "an over-long command with a quoted git verb and a force flag asks" {
    local body
    body=$(printf 'x%.0s' $(seq 1 8200))
    run hook "gh pr create --body \"${body}\" && 'git' push origin main --force"
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "an over-long command with a force flag on a continuation line asks" {
    local body
    body=$(printf 'x%.0s' $(seq 1 8200))
    run hook "gh pr create --body \"${body}\" && git push origin main \\
--force"
    assert_success
    assert_equal "$(decision "$output")" ask
}

# 床の行継続は何も足さずにつなぐ(シェルと同じ)。空白を足すと `-- force` になって一致しない
# (`--for\⏎ce` は空白を足しても `--for` の前方一致で一致するので、この区別を確かめられない)。
@test "an over-long command with a force flag split by a continuation asks" {
    local body
    body=$(printf 'x%.0s' $(seq 1 8200))
    run hook "gh pr create --body \"${body}\" && git push origin main --\\
force"
    assert_success
    assert_equal "$(decision "$output")" ask
}

# 行末の `\\` はシェルには `\` 1 文字で、行継続ではない。次の行の push は別のコマンドとして
# 実行されるので、床が 2 行をつないで `echo agit push …` にしてしまっても見落とさない。
# heredoc 本文の `"` で reader が二重引用符に入る形と、`'` で一重引用符に入る形の両方を見る
# (二重引用符の中では reader が `\\` を `\` 1 つにする)。
@test "a force push after a line ending in an escaped backslash asks" {
    run hook "cat <<'EOF'
it\"s
EOF
echo a\\\\
git push origin main --force
echo x # \""
    assert_success
    assert_equal "$(decision "$output")" ask
    run hook "cat <<'EOF'
it's
EOF
echo a\\\\
git push origin main --force
echo x # '"
    assert_success
    assert_equal "$(decision "$output")" ask
}

# 引用符の中の置換に入れ子の引用符があると、reader は入れ子の `"` で閉じたと読んで同期がずれ、
# 後ろで bash が実行する push が改行も `$` も無い 1 token に飲み込まれる。
@test "a force push swallowed by a nested quote in a quoted substitution asks" {
    run hook "echo \"\$(echo \"a it's\")\" ; git push origin main --force ; echo ' x'"
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "a plain push after a nested quote in a quoted substitution produces no decision" {
    run hook "echo \"\$(echo \"a it's\")\" ; git push origin main ; echo ' x'"
    assert_success
    assert_output ''
}

# コマンドの位置の語が置換や変数だと git と読める token が無い。引用符の外の `$(which git)` は
# reader が `)` で segment を切るので、push の segment は `push` か git の全体オプション・リダイレクト
# から始まる。引用符の外の `${G}` は reader が `{` で切るので、コマンドの位置の token が `$` だけになる。
@test "a push whose git binary comes from a substitution or a variable asks" {
    local command
    for command in \
        '$(which git) push origin main --force' \
        '$(which git) -C . push origin main --force' \
        '$(which git) --no-pager push origin main --force' \
        '$(which git) -c x=y push origin main --force' \
        '$(which git) 2>/dev/null push origin main --force' \
        '`which git` push origin main --force' \
        '"$(command -v git)" push origin main --force' \
        'G=git; $G push origin main --force' \
        'G=git; ${G} push origin main --force' \
        '${GIT:-git} push origin main --force'; do
        run hook "$command"
        assert_success
        assert_equal "$(decision "$output")" ask
    done
}

# 単独の `$` は文字のまま(heredoc 本文のプロンプト表記)。
@test "a prompt-style plain push line in a heredoc body produces no decision" {
    run hook "gh pr create --body-file - <<'EOF'
手順:
\$ git push origin main
EOF"
    assert_success
    assert_output ''
}

# 行頭が push の散文は、引用符の外の `$(` より後ろに無ければコマンド語の続きとは読まない。
@test "a heredoc line starting with push in a command with a variable produces no decision" {
    run hook "gh pr create --body-file - <<'EOF'
push の前に \$HOME を確認する
EOF"
    assert_success
    assert_output ''
}

@test "a substitution elsewhere before a plain push produces no decision" {
    run hook 'git commit -m "$(date)" && git push origin x'
    assert_success
    assert_output ''
    run hook 'cd "$HOME/x" && git push origin main'
    assert_success
    assert_output ''
}

# 床も token の判定と同じく、長オプションの前方一致と -c の push / mirror の設定を見る。
@test "an abbreviated force flag or a mirror config inside a quoted substitution asks" {
    run hook 'echo "$(git push origin main --forc)"'
    assert_success
    assert_equal "$(decision "$output")" ask
    run hook 'echo "$(git -c remote.origin.mirror=true push origin main)"'
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "a safe long option inside a quoted substitution produces no decision" {
    run hook 'echo "$(git push origin main --follow-tags)"'
    assert_success
    assert_output ''
    run hook 'echo "$(git push --dry-run origin main)"'
    assert_success
    assert_output ''
}

# 前置詞の一覧に無いコマンド(`nice -n 0` / `timeout` / `sudo -n` / `xargs`)の後ろの git は strict=0 で
# 読むが、push を壊す -c と GIT_CONFIG_* は見る。床は ask 止まりなので deny は増えない。
@test "a push or mirror config after an unrecognized prefix asks" {
    run hook 'nice -n 0 git -c remote.origin.mirror=true push origin'
    assert_success
    assert_equal "$(decision "$output")" ask
    run hook 'timeout 60 git -c remote.origin.push=+HEAD:refs/heads/main push origin'
    assert_success
    assert_equal "$(decision "$output")" ask
    run hook 'sudo -n git -c remote.origin.mirror=true push origin'
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "an include config or GIT_CONFIG environment after an unrecognized prefix asks" {
    run hook 'timeout 60 git -c include.path=/tmp/x push origin'
    assert_success
    assert_equal "$(decision "$output")" ask
    run hook 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.mirror GIT_CONFIG_VALUE_0=true timeout 60 git push origin'
    assert_success
    assert_equal "$(decision "$output")" ask
}

# 絞り込みの対照: push / mirror / include 以外の -c は、前置きの後ろでも無出力のまま。
@test "an unrelated config after an unrecognized prefix produces no decision" {
    run hook 'timeout 60 git -c user.name=x push origin feature'
    assert_success
    assert_output ''
    run hook 'timeout 60 git -c push.autoSetupRemote=true push origin feature'
    assert_success
    assert_output ''
}

# `{` を 1 byte ごとに並べると、同じ index の印が 1 件ずつ増え、push の segment ごとに全件を
# 走査していたので二乗になった(8 KB で 8 秒。フックの timeout は 5 秒 = 判定なし)。
@test "a force push followed by push segments and a brace flood is denied within the timeout" {
    local command='git push origin main --force;' start elapsed
    local index
    for ((index = 0; index < 450; index++)); do command+='git push;'; done
    command+='echo '
    while [[ ${#command} -lt 8190 ]]; do command+='{{{{{{{{{{'; done
    command=${command:0:8192}
    start=$SECONDS
    run hook "$command"
    elapsed=$((SECONDS - start))
    assert_success
    assert_equal "$(decision "$output")" deny
    [[ $elapsed -lt 3 ]]
}

@test "a force push followed by push segments and a glob flood is denied within the timeout" {
    local command='git push origin main --force;' start elapsed
    local index
    for ((index = 0; index < 450; index++)); do command+='git push;'; done
    command+='echo'
    while [[ ${#command} -lt 8190 ]]; do command+=' *'; done
    command=${command:0:8192}
    start=$SECONDS
    run hook "$command"
    elapsed=$((SECONDS - start))
    assert_success
    assert_equal "$(decision "$output")" deny
    [[ $elapsed -lt 3 ]]
}

# 床の短オプションは、token の判定(`-*` のうち f か d を含むもの)と同じ綴りに一致させる。
# 数字を含む束(`-4f` は --ipv4 + --force)は parse-options が受け付ける。
@test "every short option bundle the token check denies also asks through the floor" {
    local bundle
    for bundle in -f -d -uf -4f -f4 -6d -fd; do
        run hook "git push $bundle origin main"
        assert_success
        assert_equal "$(decision "$output")" deny
        run hook "echo \"\$(git push $bundle origin main)\""
        assert_success
        assert_equal "$(decision "$output")" ask
    done
}

@test "a numeric short option without f or d inside a quoted substitution produces no decision" {
    run hook 'echo "$(git push -4 origin main)"'
    assert_success
    assert_output ''
}

# reader は heredoc とコメントを知らない。heredoc の本文やコメントの中の `git push --force` は、
# 承認しても実行できない deny ではなく ask 止まりにする。
@test "a commit message heredoc naming git push --force asks rather than denies" {
    run hook $'git commit -F - <<\'EOF\'\nfix: guard\n\ngit push --force を deny する\nEOF'
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "a trailing comment naming --force after a plain push asks rather than denies" {
    run hook 'git push origin main # do not --force'
    assert_success
    assert_equal "$(decision "$output")" ask
}

# 対照: heredoc もコメントも無い force push は deny のまま。heredoc の後ろの行の force push は
# 本文と区別できないので ask に下がる(受容した格下げ)。
@test "a force push before a heredoc is still denied" {
    run hook $'git push origin main --force && cat <<\'EOF\'\nbody\nEOF'
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "a heredoc body naming git push without a dangerous spelling produces no decision" {
    run hook $'git commit -F - <<\'EOF\'\nfix: guard\n\ngit push origin main は通す\nEOF'
    assert_success
    assert_output ''
}

# heredoc の格下げと -c mirror の組み合わせ: heredoc 本文の行の -c mirror は ask(deny にはならない)。
@test "a heredoc body naming a mirror config push asks" {
    run hook $'git commit -F - <<\'EOF\'\ndocs\n\ngit -c remote.origin.mirror=true push は ask\nEOF'
    assert_success
    assert_equal "$(decision "$output")" ask
}

# here-string と `< <(…)` は本文を持たないので、その後ろの force push は deny のまま。
# 対照は上の "a commit message heredoc naming git push --force asks rather than denies"。
@test "a force push after a here-string is still denied" {
    run hook 'cat <<< x; git push origin main --force'
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "a force push after a process substitution input is still denied" {
    run hook 'cat < <(echo x); git push origin main --force'
    assert_success
    assert_equal "$(decision "$output")" deny
}
