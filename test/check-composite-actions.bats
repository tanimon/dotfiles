#!/usr/bin/env bats
# scripts/check-composite-actions.sh のスモークテスト。
#
# 「壊れた action を落とす」ケースと「正しい action を通す」ケースを対で持つ。
# 片方だけだと、何でも通す(または何でも落とす)検査でも緑になる。

setup() {
    load 'helpers/setup'
    SCRIPT="${BATS_TEST_DIRNAME}/../scripts/check-composite-actions.sh"
}

write_action() {
    cat >"$BATS_TEST_TMPDIR/action.yml"
}

@test "正しい composite action は通る" {
    write_action <<'EOF'
name: ok
runs:
  using: composite
  steps:
    - name: Greet
      shell: bash
      env:
        WHO: world
      run: |
        echo "hello ${WHO}"
EOF
    run bash "$SCRIPT" "$BATS_TEST_TMPDIR/action.yml"
    assert_success
    assert_output --partial "ok   $BATS_TEST_TMPDIR/action.yml (Greet)"
}

@test "run ブロックのインデントより左に出た行で閉じ引用符が失われると落ちる(#411 の壊れ方)" {
    write_action <<'EOF'
name: broken
runs:
  using: composite
  steps:
    - name: Create issue
      shell: bash
      run: |
        gh issue create --body "${BODY}

Latest run: ${RUN_URL}"
EOF
    run bash "$SCRIPT" "$BATS_TEST_TMPDIR/action.yml"
    assert_failure
    assert_output --partial "FAIL $BATS_TEST_TMPDIR/action.yml (Create issue): bash -n"
}

# 置換しないと shellcheck が SC2296 で落とす。bash -n は通るので shellcheck が無いと空振りする。
@test "GitHub Actions の式展開はシェル構文として扱わない" {
    command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
    write_action <<'EOF'
name: expr
runs:
  using: composite
  steps:
    - name: Uses expression
      shell: bash
      run: |
        echo "${{ github.action_path }}"
EOF
    run bash "$SCRIPT" "$BATS_TEST_TMPDIR/action.yml"
    assert_success
}

@test "shellcheck の警告で落ちる" {
    command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
    write_action <<'EOF'
name: unquoted
runs:
  using: composite
  steps:
    - name: Unquoted
      shell: bash
      run: |
        rm $TARGET
EOF
    run bash "$SCRIPT" "$BATS_TEST_TMPDIR/action.yml"
    assert_failure
    assert_output --partial "(Unquoted): shellcheck"
}

@test "composite でない action は検査対象にしない" {
    write_action <<'EOF'
name: node
runs:
  using: node20
  main: index.js
EOF
    run bash "$SCRIPT" "$BATS_TEST_TMPDIR/action.yml"
    assert_success
    refute_output --partial "ok   "
}

@test "shell の無い run step は落ちる" {
    write_action <<'EOF'
name: noshell
runs:
  using: composite
  steps:
    - name: No shell
      run: echo hi
EOF
    run bash "$SCRIPT" "$BATS_TEST_TMPDIR/action.yml"
    assert_failure
    assert_output --partial "FAIL $BATS_TEST_TMPDIR/action.yml (No shell): shell is required"
}

@test "bash 以外の shell の step は検査せず skip と出す" {
    write_action <<'EOF'
name: sh
runs:
  using: composite
  steps:
    - name: Posix
      shell: sh
      run: echo "unterminated
EOF
    run bash "$SCRIPT" "$BATS_TEST_TMPDIR/action.yml"
    assert_success
    assert_output --partial "skip $BATS_TEST_TMPDIR/action.yml (Posix): shell=sh"
}

@test "一部の step だけ壊れていると、その step だけが FAIL になり残りも検査される" {
    write_action <<'EOF'
name: mixed
runs:
  using: composite
  steps:
    - name: Broken
      shell: bash
      run: echo "unterminated
    - name: Fine
      shell: bash
      run: echo ok
EOF
    run bash "$SCRIPT" "$BATS_TEST_TMPDIR/action.yml"
    assert_failure
    assert_output --partial "FAIL $BATS_TEST_TMPDIR/action.yml (Broken): bash -n"
    assert_output --partial "ok   $BATS_TEST_TMPDIR/action.yml (Fine)"
}

@test "YAML として読めない action は落ちる" {
    write_action <<'EOF'
name: [unterminated
EOF
    run bash "$SCRIPT" "$BATS_TEST_TMPDIR/action.yml"
    assert_failure
    assert_output --partial "could not parse"
}

@test "リポジトリの composite action はすべて通る" {
    cd "${BATS_TEST_DIRNAME}/.."
    run bash "$SCRIPT"
    assert_success
    assert_output --partial "ok   .github/actions/harness-issue-alert/action.yml"
    refute_output --partial "FAIL"
}
