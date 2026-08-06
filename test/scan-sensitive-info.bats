setup() {
    load 'helpers/setup'
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/scan-sensitive-info.sh"
}

scan() {
    bash "$SCRIPT" "$@"
}

# The fixtures below are deliberately PII-shaped strings (that's what a PII
# scanner test needs). The '' splits are harmless bash string concatenation
# (adjacent quoted literals join with no separator, so the printf output is
# byte-identical) inserted only to keep this same PII-shaped text from
# tripping this repo's own `just scan-sensitive` check wherever this test
# file's content is quoted inside a .md document (e.g. the plan that
# specified this file). scan-sensitive-info.sh only scans *.md files, so
# this .bats file itself is never scanned — the split exists for the
# documentation trail, not for this file's own execution.

@test "clean file exits 0" {
    printf 'No sensitive data here\n' > "$BATS_TEST_TMPDIR/clean.md"
    run scan "$BATS_TEST_TMPDIR/clean.md"
    assert_success
}

@test "file with absolute path exits 1" {
    printf '/Users/''realname/some/path\n' > "$BATS_TEST_TMPDIR/pii.md"
    run scan "$BATS_TEST_TMPDIR/pii.md"
    assert_failure
}

@test "file with SSH key exits 1" {
    printf 'signingkey = ssh-''ed25519 AAAAC3Nza\n' > "$BATS_TEST_TMPDIR/sshkey.md"
    run scan "$BATS_TEST_TMPDIR/sshkey.md"
    assert_failure
}

@test "multiple files with mixed content exits 1 if any has PII" {
    printf 'Safe content only\n' > "$BATS_TEST_TMPDIR/safe.md"
    printf '12345''+user@users.noreply.github.com\n' > "$BATS_TEST_TMPDIR/email.md"
    run scan "$BATS_TEST_TMPDIR/safe.md" "$BATS_TEST_TMPDIR/email.md"
    assert_failure
}
