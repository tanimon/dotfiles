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
