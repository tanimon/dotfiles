setup() {
    load 'helpers/setup'
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/scan-sensitive-info.sh"
    # Hermetic defaults: without these the scanner would resolve this machine's
    # real work org (`chezmoi data`) and account name (`id -un`), and read the
    # developer's real local patterns file, so results would differ per machine
    # — and a fixture would silently match the runner's own username. Tests that
    # exercise those inputs re-export them explicitly.
    export SENSITIVE_WORK_ORG=
    export SENSITIVE_LOCAL_USER=
    export SENSITIVE_PATTERNS_LOCAL="$BATS_TEST_TMPDIR/no-such-local-patterns.txt"
}

scan() {
    bash "$SCRIPT" "$@"
}

# The fixtures below are deliberately PII-shaped strings (that's what a PII
# scanner test needs). The '' splits are harmless bash string concatenation
# (adjacent quoted literals join with no separator, so the printf output is
# byte-identical) placed so that the *source line* no longer matches the
# pattern while the *written fixture* still does.
#
# These splits are load-bearing: scan-sensitive-info.sh scans every file in
# the repo, not just *.md, so without them this file would flag itself and
# `just scan-sensitive` would never go green. Each split goes immediately
# before the character a pattern requires to be alphanumeric, which is why
# the quote breaks the match. Do not "tidy" them away.

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

# --- guard A: hardcoded org path where a chezmoi template variable belongs ---

@test "hardcoded ghq org path exits 1" {
    printf 'Read(~/ghq/github.com/''someorg/**)\n' > "$BATS_TEST_TMPDIR/orgpath.md"
    run scan "$BATS_TEST_TMPDIR/orgpath.md"
    assert_failure
}

# The org name is the secret here, so reporting must not copy it into the log
# (this job runs in CI on a public repo). file:line is already actionable:
# any literal org in that position is wrong regardless of which one it is.
@test "hardcoded ghq org path is reported without echoing the org" {
    printf 'Read(~/ghq/github.com/''someorg/**)\n' > "$BATS_TEST_TMPDIR/orgpath.md"
    run scan "$BATS_TEST_TMPDIR/orgpath.md"
    assert_failure
    refute_output --partial 'someorg'
    assert_output --partial 'orgpath.md:1'
}

# The positive example the guard exists to enforce (see dot_claude/settings.json.tmpl).
@test "ghq path written as a chezmoi template variable exits 0" {
    printf 'Read(~/ghq/github.com/{{ .ghOrg }}/**)\n' > "$BATS_TEST_TMPDIR/tmplpath.md"
    run scan "$BATS_TEST_TMPDIR/tmplpath.md"
    assert_success
}

@test "placeholder org name exits 0" {
    printf 'see ~/ghq/github.com/<work-org>/** for the work checkout\n' > "$BATS_TEST_TMPDIR/placeholder.md"
    run scan "$BATS_TEST_TMPDIR/placeholder.md"
    assert_success
}

# --- allowlist: intentionally-public information ---

@test "allowlist entry suppresses a match" {
    printf 'orgpath.md:ghq/github\\.com/someorg\n' > "$BATS_TEST_TMPDIR/allow.txt"
    printf 'Read(~/ghq/github.com/''someorg/**)\n' > "$BATS_TEST_TMPDIR/orgpath.md"
    export SENSITIVE_ALLOWLIST="$BATS_TEST_TMPDIR/allow.txt"
    run scan "$BATS_TEST_TMPDIR/orgpath.md"
    assert_success
}

@test "allowlist entry scoped to another path does not suppress" {
    printf 'other.md:ghq/github\\.com/someorg\n' > "$BATS_TEST_TMPDIR/allow.txt"
    printf 'Read(~/ghq/github.com/''someorg/**)\n' > "$BATS_TEST_TMPDIR/orgpath.md"
    export SENSITIVE_ALLOWLIST="$BATS_TEST_TMPDIR/allow.txt"
    run scan "$BATS_TEST_TMPDIR/orgpath.md"
    assert_failure
}

# --- guard B: the work org name itself, resolved at scan time ---
#
# This is the contrast pair the guard lives or dies on: with the org known the
# prose mention must fail the scan, and with the org explicitly unset the scan
# must SAY it skipped the check rather than pass vacuously.

@test "work org name in prose exits 1" {
    export SENSITIVE_WORK_ORG=acmecorp
    printf 'the acmecorp worktree needs the shared DB\n' > "$BATS_TEST_TMPDIR/prose.md"
    run scan "$BATS_TEST_TMPDIR/prose.md"
    assert_failure
}

@test "work org match is case-insensitive" {
    export SENSITIVE_WORK_ORG=acmecorp
    printf 'the AcmeCorp worktree needs the shared DB\n' > "$BATS_TEST_TMPDIR/prose.md"
    run scan "$BATS_TEST_TMPDIR/prose.md"
    assert_failure
}

# The scanner runs in CI on a public repo, so a match must not echo the string
# it is guarding into the log — file:line only, and no pattern text either.
@test "work org match never echoes the org name into output" {
    export SENSITIVE_WORK_ORG=acmecorp
    printf 'the acmecorp worktree needs the shared DB\n' > "$BATS_TEST_TMPDIR/prose.md"
    run scan "$BATS_TEST_TMPDIR/prose.md"
    assert_failure
    refute_output --partial 'acmecorp'
    assert_output --partial 'prose.md:1'
}

@test "explicitly empty work org skips the check and names it" {
    export SENSITIVE_WORK_ORG=
    export SENSITIVE_LOCAL_USER=someuser
    printf 'the acmecorp worktree needs the shared DB\n' > "$BATS_TEST_TMPDIR/prose.md"
    run scan "$BATS_TEST_TMPDIR/prose.md"
    assert_success
    assert_output --partial 'work org'
    # The username DID resolve, so the NOTE must not claim it was skipped.
    refute_output --partial 'local username'
}

# --- guard B, second resolver: the local account name ---

@test "local username in prose exits 1 without echoing it" {
    export SENSITIVE_LOCAL_USER=jdoe
    printf 'see the jdoe memory directory\n' > "$BATS_TEST_TMPDIR/user.md"
    run scan "$BATS_TEST_TMPDIR/user.md"
    assert_failure
    refute_output --partial 'jdoe'
    assert_output --partial 'user.md:1'
}

@test "explicitly empty local user skips the check and names it" {
    export SENSITIVE_LOCAL_USER=
    export SENSITIVE_WORK_ORG=acmecorp
    printf 'nothing to see\n' > "$BATS_TEST_TMPDIR/clean.md"
    run scan "$BATS_TEST_TMPDIR/clean.md"
    assert_success
    assert_output --partial 'local username'
    refute_output --partial 'work org'
}

# A CI runner or container image reports an account name that is also an
# ordinary word appearing all over this repo ("runner" in .github/ and docs/,
# "node" in .node-version). Hunting for it turns the scan red for a bogus
# reason, so the auto-resolved path filters those names out. The pair below is
# what proves the filter is doing the work: same shimmed mechanism, different
# name, opposite outcome.

fake_id() {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat > "$BATS_TEST_TMPDIR/bin/id" <<EOF
#!/bin/sh
if [ "\$1" = "-un" ]; then echo $1; else exec /usr/bin/id "\$@"; fi
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/id"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "generic CI account name is ignored rather than hunted" {
    unset SENSITIVE_LOCAL_USER
    fake_id runner
    printf 'the CI runner uploads artifacts\n' > "$BATS_TEST_TMPDIR/ci.md"
    run scan "$BATS_TEST_TMPDIR/ci.md"
    assert_success
    assert_output --partial 'generic account name'
}

@test "auto-resolved real account name is hunted" {
    unset SENSITIVE_LOCAL_USER
    fake_id jdoe
    printf 'the jdoe home directory\n' > "$BATS_TEST_TMPDIR/real.md"
    run scan "$BATS_TEST_TMPDIR/real.md"
    assert_failure
    refute_output --partial 'jdoe'
}

# An explicit override must win even for a generic-looking name: the filter
# guards the guess, not the instruction.
@test "explicit local user override beats the generic-name filter" {
    export SENSITIVE_LOCAL_USER=runner
    printf 'the CI runner uploads artifacts\n' > "$BATS_TEST_TMPDIR/ci.md"
    run scan "$BATS_TEST_TMPDIR/ci.md"
    assert_failure
}

# --- Claude Code project slug: the form /Users/... cannot see ---
#
# A flattened path keeps the account name but loses every `/`, so the
# path-shaped patterns miss it entirely. This is how real account names
# survived in docs/ that the scanner already covered.

@test "project slug with an account name exits 1 without echoing it" {
    printf 'see ~/.claude/projects/-Users-''jdoe--local-share-chezmoi/memory/x.md\n' \
        > "$BATS_TEST_TMPDIR/slug.md"
    run scan "$BATS_TEST_TMPDIR/slug.md"
    assert_failure
    refute_output --partial 'jdoe'
    assert_output --partial 'slug.md:1'
}

@test "multi-token project slug (renamed account) exits 1" {
    printf 'see ~/.claude/projects/-Users-''jane-doe--local-share-chezmoi/memory/x.md\n' \
        > "$BATS_TEST_TMPDIR/slug.md"
    run scan "$BATS_TEST_TMPDIR/slug.md"
    assert_failure
}

@test "project slug written with the placeholder exits 0" {
    printf 'see ~/.claude/projects/-Users-<user>--local-share-chezmoi/memory/x.md\n' \
        > "$BATS_TEST_TMPDIR/slug.md"
    run scan "$BATS_TEST_TMPDIR/slug.md"
    assert_success
}

@test "local patterns file is honored and its matches are redacted" {
    printf 'internal-codename\n' > "$BATS_TEST_TMPDIR/local-patterns.txt"
    printf 'we ship internal-codename next week\n' > "$BATS_TEST_TMPDIR/local.md"
    export SENSITIVE_PATTERNS_LOCAL="$BATS_TEST_TMPDIR/local-patterns.txt"
    export SENSITIVE_WORK_ORG=
    run scan "$BATS_TEST_TMPDIR/local.md"
    assert_failure
    refute_output --partial 'internal-codename'
}

# The pattern/allowlist files contain guarded-looking text by construction, so
# widening the scan to every file must not make them flag themselves.
@test "pattern and allowlist files are excluded from scanning" {
    run scan "$BATS_TEST_DIRNAME/../scripts/sensitive-patterns.txt" \
        "$BATS_TEST_DIRNAME/../scripts/sensitive-allowlist.txt"
    assert_success
}
