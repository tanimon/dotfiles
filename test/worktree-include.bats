setup() {
    load 'helpers/setup'
    SCRIPT="$BATS_TEST_DIRNAME/../dot_claude/scripts/executable_worktree-include.sh"
    export HOME="$BATS_TEST_TMPDIR"
    # Isolate git from the developer's real config: this repo's global gitconfig
    # turns on ssh commit signing via the 1Password agent, which would make the
    # fixture commits below fail (or hang) inside a sandbox.
    export GIT_CONFIG_GLOBAL=/dev/null
    export GIT_CONFIG_SYSTEM=/dev/null
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
    export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

    MAIN="$BATS_TEST_TMPDIR/main"
    WT="$BATS_TEST_TMPDIR/wt"
    mkdir -p "$MAIN"
    git -C "$MAIN" init -q -b main
    printf 'tracked\n' >"$MAIN/README.md"
    git -C "$MAIN" add README.md
    git -C "$MAIN" commit -q -m init
    git -C "$MAIN" worktree add -q -b feature "$WT"
}

# Run the hook as Claude Code would: the payload's cwd is the only input.
hook() {
    printf '{"cwd":"%s"}' "$1" | bash "$SCRIPT"
}

@test "listed file is copied into the linked worktree" {
    printf 'CLAUDE.local.md\n' >"$MAIN/.worktreeinclude"
    printf 'local notes\n' >"$MAIN/CLAUDE.local.md"

    run hook "$WT"
    assert_success
    assert [ -f "$WT/CLAUDE.local.md" ]
    assert_equal "$(cat "$WT/CLAUDE.local.md")" 'local notes'
    assert_output --partial 'CLAUDE.local.md'
}

@test "root-anchored pattern is honored instead of rejected as unsafe" {
    # gtr treats a leading slash as an absolute path and silently drops the
    # line; this hook reads it as gitignore does — anchored at the repo root.
    printf '/.claude/settings.local.json\n' >"$MAIN/.worktreeinclude"
    mkdir -p "$MAIN/.claude"
    printf '{"permissions":{}}\n' >"$MAIN/.claude/settings.local.json"

    run hook "$WT"
    assert_success
    assert [ -f "$WT/.claude/settings.local.json" ]
}

@test "an existing file in the worktree is never overwritten" {
    printf 'CLAUDE.local.md\n' >"$MAIN/.worktreeinclude"
    printf 'from main\n' >"$MAIN/CLAUDE.local.md"
    printf 'edited in worktree\n' >"$WT/CLAUDE.local.md"

    run hook "$WT"
    assert_success
    assert_equal "$(cat "$WT/CLAUDE.local.md")" 'edited in worktree'
    refute_output --partial 'CLAUDE.local.md'
}

@test "running in the main worktree copies nothing" {
    printf 'CLAUDE.local.md\n' >"$MAIN/.worktreeinclude"
    printf 'local notes\n' >"$MAIN/CLAUDE.local.md"

    run hook "$MAIN"
    assert_success
    assert_output ''
}

@test "comments and blank lines are ignored" {
    printf '# a comment\n\n   \nCLAUDE.local.md\n' >"$MAIN/.worktreeinclude"
    printf 'local notes\n' >"$MAIN/CLAUDE.local.md"

    run hook "$WT"
    assert_success
    assert [ -f "$WT/CLAUDE.local.md" ]
    refute [ -e "$WT/# a comment" ]
}

@test "a pattern with a .. segment is refused" {
    printf '../escape.txt\n' >"$MAIN/.worktreeinclude"
    printf 'secret\n' >"$BATS_TEST_TMPDIR/escape.txt"

    run hook "$WT"
    assert_success
    # Without the stderr assertion this case would also pass if the hook had
    # never read the file at all.
    assert_output --partial 'refusing pattern'
    refute [ -e "$WT/escape.txt" ]
}

@test "a symlinked file is refused instead of having its target copied" {
    # The ".." check only sees what the pattern spells; a symlink reaches
    # outside the main worktree without spelling anything.
    printf 'OUTSIDE\n' >"$BATS_TEST_TMPDIR/secret.txt"
    ln -s "$BATS_TEST_TMPDIR/secret.txt" "$MAIN/leak.txt"
    printf 'leak.txt\n' >"$MAIN/.worktreeinclude"

    run hook "$WT"
    assert_success
    assert_output --partial 'resolves outside the main worktree'
    refute [ -e "$WT/leak.txt" ]
}

@test "a symlinked directory component is refused" {
    # Non-symlink leaf, symlinked parent — the leaf-only check misses this.
    mkdir -p "$BATS_TEST_TMPDIR/outside"
    printf 'OUTSIDE\n' >"$BATS_TEST_TMPDIR/outside/hosts"
    ln -s "$BATS_TEST_TMPDIR/outside" "$MAIN/sub"
    printf 'sub/hosts\n' >"$MAIN/.worktreeinclude"

    run hook "$WT"
    assert_success
    assert_output --partial 'resolves outside the main worktree'
    refute [ -e "$WT/sub/hosts" ]
}

@test "a symlinked destination directory is refused before mkdir runs" {
    mkdir -p "$BATS_TEST_TMPDIR/outside2" "$MAIN/dst"
    printf 'LANDED\n' >"$MAIN/dst/settings.local.json"
    ln -s "$BATS_TEST_TMPDIR/outside2" "$WT/dst"
    printf 'dst/settings.local.json\n' >"$MAIN/.worktreeinclude"

    run hook "$WT"
    assert_success
    assert_output --partial 'destination resolves outside'
    refute [ -e "$BATS_TEST_TMPDIR/outside2/settings.local.json" ]
}

@test "a dangling symlink in the worktree is not written through" {
    printf 'CLAUDE.local.md\n' >"$MAIN/.worktreeinclude"
    printf 'from main\n' >"$MAIN/CLAUDE.local.md"
    # Not -e, so an -e-only guard would let cp follow it out of the worktree.
    ln -s "$BATS_TEST_TMPDIR/pwned.txt" "$WT/CLAUDE.local.md"

    run hook "$WT"
    assert_success
    assert_output ''
    refute [ -e "$BATS_TEST_TMPDIR/pwned.txt" ]
}

@test "a listed name containing a space is copied" {
    printf 'my file.local\n' >"$MAIN/.worktreeinclude"
    printf 'spaced\n' >"$MAIN/my file.local"

    run hook "$WT"
    assert_success
    assert [ -f "$WT/my file.local" ]
}

@test "trailing whitespace and a CR are not part of the pattern" {
    printf 'CLAUDE.local.md  \r\n' >"$MAIN/.worktreeinclude"
    printf 'local notes\n' >"$MAIN/CLAUDE.local.md"

    run hook "$WT"
    assert_success
    assert [ -f "$WT/CLAUDE.local.md" ]
}

@test "a glob pattern copies every match" {
    printf 'env/*.local\n' >"$MAIN/.worktreeinclude"
    mkdir -p "$MAIN/env"
    printf 'a\n' >"$MAIN/env/a.local"
    printf 'b\n' >"$MAIN/env/b.local"
    printf 'c\n' >"$MAIN/env/c.other"

    run hook "$WT"
    assert_success
    assert [ -f "$WT/env/a.local" ]
    assert [ -f "$WT/env/b.local" ]
    refute [ -e "$WT/env/c.other" ]
}

@test "a pattern matching nothing is silent and succeeds" {
    printf 'nope/*.missing\n' >"$MAIN/.worktreeinclude"

    run hook "$WT"
    assert_success
    assert_output ''
}

@test "directories listed as patterns are skipped, not copied" {
    printf 'somedir\n' >"$MAIN/.worktreeinclude"
    mkdir -p "$MAIN/somedir"
    printf 'x\n' >"$MAIN/somedir/x.txt"

    run hook "$WT"
    assert_success
    refute [ -e "$WT/somedir" ]
}

@test "missing .worktreeinclude exits 0 silently" {
    run hook "$WT"
    assert_success
    assert_output ''
}

@test "a cwd outside any git repository exits 0" {
    outside="$BATS_TEST_TMPDIR/outside"
    mkdir -p "$outside"

    run hook "$outside"
    assert_success
    assert_output ''
}

@test "malformed stdin exits 0" {
    run bash -c "printf 'not json' | bash '$SCRIPT'"
    assert_success
    assert_output ''
}

@test "a nonexistent cwd exits 0" {
    run hook "$BATS_TEST_TMPDIR/gone"
    assert_success
    assert_output ''
}
