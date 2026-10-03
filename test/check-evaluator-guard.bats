#!/usr/bin/env bats

setup() {
    load 'helpers/setup'
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/check-evaluator-guard.sh"
    REPO="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$REPO"
    git -C "$REPO" init -q -b main
    git -C "$REPO" config user.email t@example.com
    git -C "$REPO" config user.name t
    git -C "$REPO" config commit.gpgsign false
    put scripts/evaluator-paths.txt $'# コメント行\n\nscripts/evaluator-paths.txt\nevaluator/\nrules/fixed.md'
    put evaluator/detector.sh 'echo detect'
    put rules/fixed.md 'fixed'
    put rules/other.md 'other'
    commit base
    BASE="$(git -C "$REPO" rev-parse HEAD)"
    unset GITHUB_HEAD_REF
}

put() {
    mkdir -p "$REPO/$(dirname "$1")"
    printf '%s\n' "$2" >"$REPO/$1"
    git -C "$REPO" add -- "$1"
}

commit() {
    git -C "$REPO" commit -q -m "$1"
}

guard() {
    (cd "$REPO" && bash "$SCRIPT" "$@")
}

@test "ループの PR が Evaluator のファイルに触れたら落ち、触れたパスを表示する" {
    put evaluator/detector.sh 'echo changed'
    commit change
    run guard harness/review-2026-10-04 "$BASE"
    assert_failure 1
    assert_output --partial 'evaluator/detector.sh'
}

@test "一覧に完全一致で載ったファイルも Evaluator として扱う" {
    put rules/fixed.md 'changed'
    commit change
    run guard harness/review-2026-10-04 "$BASE"
    assert_failure 1
    assert_output --partial 'rules/fixed.md'
}

@test "人の PR は Evaluator に触れても通る" {
    put evaluator/detector.sh 'echo changed'
    commit change
    run guard feature-x "$BASE"
    assert_success
}

@test "ループの PR でも Evaluator に触れなければ通る" {
    put rules/other.md 'changed'
    put rules/fixed.md.bak 'prefix は完全一致の行に効かない'
    commit change
    run guard harness/review-2026-10-04 "$BASE"
    assert_success
}

@test "ループの PR が一覧から自分の行を消しても、base の一覧で判定して落ちる" {
    put scripts/evaluator-paths.txt 'rules/fixed.md'
    put evaluator/detector.sh 'echo changed'
    commit shrink
    run guard harness/review-2026-10-04 "$BASE"
    assert_failure 1
    assert_output --partial 'scripts/evaluator-paths.txt'
    assert_output --partial 'evaluator/detector.sh'
}

@test "ループの PR が Evaluator のファイルを外へ移しても、元のパスで落ちる" {
    git -C "$REPO" mv evaluator/detector.sh rules/detector.sh
    commit move
    run guard harness/review-2026-10-04 "$BASE"
    assert_failure 1
    assert_output --partial 'evaluator/detector.sh'
}

@test "ループの PR で base に一覧が無ければ落ちる" {
    git -C "$REPO" rm -q scripts/evaluator-paths.txt
    commit no-list
    NOLIST="$(git -C "$REPO" rev-parse HEAD)"
    put rules/other.md 'changed'
    commit change
    run guard harness/review-2026-10-04 "$NOLIST"
    assert_failure 2
    assert_output --partial 'scripts/evaluator-paths.txt'
}

@test "ループの PR で base を解決できなければ落ちる" {
    run guard harness/review-2026-10-04 no-such-rev
    assert_failure 2
    assert_output --partial 'no-such-rev'
}

@test "GITHUB_HEAD_REF が無いループのブランチでは origin/main との merge-base で判定する" {
    git -C "$REPO" update-ref refs/remotes/origin/main "$BASE"
    git -C "$REPO" switch -q -c harness/review-2026-10-04
    put evaluator/detector.sh 'echo changed'
    commit change
    run guard
    assert_failure 1
    assert_output --partial 'evaluator/detector.sh'
}

@test "GITHUB_HEAD_REF が無いループのブランチで origin/main が無ければ落ちる" {
    git -C "$REPO" switch -q -c harness/review-2026-10-04
    run guard
    assert_failure 2
    assert_output --partial 'origin/main'
}

@test "引数を省くと GITHUB_HEAD_REF と merge commit の第1親で判定する" {
    git -C "$REPO" switch -q -c harness/review-2026-10-04
    put evaluator/detector.sh 'echo changed'
    commit change
    git -C "$REPO" switch -q main
    git -C "$REPO" merge -q --no-ff -m merge harness/review-2026-10-04
    GITHUB_HEAD_REF=harness/review-2026-10-04 run guard
    assert_failure 1
    assert_output --partial 'evaluator/detector.sh'
}

@test "GITHUB_HEAD_REF が無ければ現在のブランチ名で判定する" {
    git -C "$REPO" switch -q -c feature-x
    put evaluator/detector.sh 'echo changed'
    commit change
    run guard
    assert_success
}

@test "日本語を含む Evaluator のパスも捕まえる" {
    put evaluator/失敗の類型.md 'changed'
    commit change
    run guard harness/review-2026-10-04 "$BASE"
    assert_failure 1
    assert_output --partial 'evaluator/失敗の類型.md'
}

@test "引用符やタブを含む Evaluator のパスも捕まえる" {
    put 'evaluator/a"b.md' 'changed'
    put $'evaluator/t\tab.md' 'changed'
    commit change
    run guard harness/review-2026-10-04 "$BASE"
    assert_failure 1
    assert_output --partial 'evaluator/a"b.md'
    assert_output --partial $'evaluator/t\tab.md'
}

# 一覧は完全一致・前方一致で照合し、行を正規化しない。書き損じた行は何にも一致せず
# 警告も出ないので、リポジトリの一覧の各行が実在するパスを指すことをここで確かめる
@test "リポジトリの一覧の各行は実在するファイルか、末尾 / 付きのディレクトリを指す" {
    local root="$BATS_TEST_DIRNAME/.." entry tracked bad=()
    while IFS= read -r entry; do
        [[ -z $entry || $entry == \#* ]] && continue
        if [[ $entry != "${entry#[[:space:]]}" || $entry != "${entry%[[:space:]]}" || $entry == ./* || $entry == /* ]]; then
            bad+=("$entry (前後の空白か先頭の ./ や /)")
            continue
        fi
        tracked="$(git -C "$root" -c core.quotePath=false ls-files -- ":(literal)$entry")"
        if [[ $entry == */ ]]; then
            [[ -n $tracked ]] || bad+=("$entry (追跡されたファイルを含むディレクトリではない)")
        else
            [[ $tracked == "$entry" ]] || bad+=("$entry (追跡されたファイルではない。ディレクトリなら末尾に / を付ける)")
        fi
    done <"$root/scripts/evaluator-paths.txt"
    run printf '%s\n' "${bad[@]}"
    assert_output ''
}
