#!/usr/bin/env bats
# justfile の `lint:` と .github/workflows/lint.yml が同じ suite 集合を回していることの検査。
#
# 正本は justfile の `lint:` の依存列。CI で回せないレシピは `[group('local-only')]` で
# 印を付ける。lint.yml の job は static なまま残すので(ADR 0011)、その写しが正本と
# 双方向に一致することをここで確かめる: CI への入れ忘れも、CI にだけある recipe も落とす。
# job 名は見ない(1 job が複数のレシピを回してよい)。
#
# lint.yml の各 step の `run` は「`just <recipe>` の 1 行」か「`just` という語を含まない」の
# どちらかに限る。それ以外(`run: |` の中の `just a && just b` など)は読み切れないので
# fail にする — 読めない形を通すと、検査が黙って空振りする。
#
# yq は mikefarah 版の v4 を要求する。python 版の yq は構文が違い、誤読が黙って
# 空集合になりうる。yq が無いときも skip せず fail する(CI で空振りさせないため)。

setup() {
    load 'helpers/setup'
    REPO="${BATS_TEST_DIRNAME}/.."
}

require_yq() {
    if ! command -v yq >/dev/null 2>&1; then
        echo "yq が見つからない(mikefarah 版の v4 が必要。macOS は darwin/Brewfile で入る)" >&2
        return 1
    fi
    local version
    version=$(yq --version 2>&1)
    case "$version" in
        *mikefarah*" version v4."*) ;;
        *)
            echo "mikefarah 版の yq v4 ではない: $version" >&2
            return 1
            ;;
    esac
}

# justfile の `lint:` の依存から local-only を除いた集合(1 行 1 recipe、ソート済み)。
expected_recipes() {
    just --justfile "$1" --dump --dump-format json |
        jq -r '.recipes as $r
            | .recipes.lint.dependencies[].recipe
            | select([$r[.].attributes[]? | objects | .group?] | index("local-only") | not)' |
        sort -u
}

# workflow の各 step の run が呼ぶ recipe の集合。読み切れない run があれば非ゼロで返る。
ci_recipes() {
    local runs
    runs=$(yq -o=json '[.jobs[].steps[] | select(has("run")) | .run]' "$1") || return 1
    local unreadable
    unreadable=$(jq -r '.[] | select((test("^just [a-z0-9-]+$") | not) and test("\\bjust\\b")) | @json' <<<"$runs")
    if [ -n "$unreadable" ]; then
        echo "読み切れない run(\`just <recipe>\` の 1 行にすること):" >&2
        echo "$unreadable" >&2
        return 1
    fi
    jq -r '.[] | select(test("^just [a-z0-9-]+$")) | sub("^just "; "")' <<<"$runs" | sort -u
}

check_parity() {
    local justfile="$1" workflow="$2" expected actual
    require_yq || return 1
    expected=$(expected_recipes "$justfile") || return 1
    actual=$(ci_recipes "$workflow") || return 1
    if [ -z "$expected" ]; then
        echo "lint: の依存が空(justfile の読み取りに失敗した可能性)" >&2
        return 1
    fi
    local missing extra
    missing=$(comm -23 <(echo "$expected") <(echo "$actual"))
    extra=$(comm -13 <(echo "$expected") <(echo "$actual"))
    if [ -n "$missing" ] || [ -n "$extra" ]; then
        [ -z "$missing" ] || printf 'CI が回していない lint: のレシピ:\n%s\n' "$missing" >&2
        [ -z "$extra" ] || printf 'lint: に無い(または local-only の)レシピを CI が回している:\n%s\n' "$extra" >&2
        return 1
    fi
}

# --- fixture ---------------------------------------------------------------

write_justfile() {
    cat >"$BATS_TEST_TMPDIR/justfile" <<'EOF'
lint: alpha beta gamma

alpha:
    true

beta:
    true

[group('local-only')]
gamma:
    true
EOF
}

write_workflow() {
    cat >"$BATS_TEST_TMPDIR/lint.yml"
}

# --- 実ファイル ------------------------------------------------------------

@test "実際の justfile と lint.yml は一致する" {
    run check_parity "$REPO/justfile" "$REPO/.github/workflows/lint.yml"
    assert_success
}

# --- 検査そのものの挙動(fixture) ------------------------------------------

@test "fixture: local-only を除いた集合が一致すれば通る" {
    write_justfile
    write_workflow <<'EOF'
jobs:
  a:
    steps:
      - uses: actions/checkout@v4
      - run: just alpha
      - run: just beta
EOF
    run check_parity "$BATS_TEST_TMPDIR/justfile" "$BATS_TEST_TMPDIR/lint.yml"
    assert_success
}

@test "fixture: CI への入れ忘れは落ちる" {
    write_justfile
    write_workflow <<'EOF'
jobs:
  a:
    steps:
      - run: just alpha
EOF
    run check_parity "$BATS_TEST_TMPDIR/justfile" "$BATS_TEST_TMPDIR/lint.yml"
    assert_failure
    assert_output --partial "CI が回していない"
    assert_output --partial "beta"
}

@test "fixture: local-only のレシピを CI が回すと落ちる" {
    write_justfile
    write_workflow <<'EOF'
jobs:
  a:
    steps:
      - run: just alpha
      - run: just beta
      - run: just gamma
EOF
    run check_parity "$BATS_TEST_TMPDIR/justfile" "$BATS_TEST_TMPDIR/lint.yml"
    assert_failure
    assert_output --partial "gamma"
}

@test "fixture: lint: に無いレシピを CI が回すと落ちる" {
    write_justfile
    write_workflow <<'EOF'
jobs:
  a:
    steps:
      - run: just alpha
      - run: just beta
      - run: just delta
EOF
    run check_parity "$BATS_TEST_TMPDIR/justfile" "$BATS_TEST_TMPDIR/lint.yml"
    assert_failure
    assert_output --partial "delta"
}

@test "fixture: 複数行の run の中の just は読み切れないので落ちる" {
    write_justfile
    write_workflow <<'EOF'
jobs:
  a:
    steps:
      - run: |
          just alpha
          just beta
EOF
    run check_parity "$BATS_TEST_TMPDIR/justfile" "$BATS_TEST_TMPDIR/lint.yml"
    assert_failure
    assert_output --partial "読み切れない"
}

@test "fixture: just を含まない run は無視する" {
    write_justfile
    write_workflow <<'EOF'
jobs:
  a:
    steps:
      - run: pnpm install --frozen-lockfile
      - run: just alpha
      - run: just beta
EOF
    run check_parity "$BATS_TEST_TMPDIR/justfile" "$BATS_TEST_TMPDIR/lint.yml"
    assert_success
}

@test "fixture: mikefarah 版でない yq は落ちる" {
    write_justfile
    write_workflow <<'EOF'
jobs:
  a:
    steps:
      - run: just alpha
      - run: just beta
EOF
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '#!/bin/sh\necho "yq 3.4.3"\n' >"$BATS_TEST_TMPDIR/bin/yq"
    chmod +x "$BATS_TEST_TMPDIR/bin/yq"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH" run check_parity "$BATS_TEST_TMPDIR/justfile" "$BATS_TEST_TMPDIR/lint.yml"
    assert_failure
    assert_output --partial "mikefarah"
}
