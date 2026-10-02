#!/usr/bin/env bats

setup() {
    load 'helpers/setup'
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/check-comment-noise.sh"
    REPO="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$REPO"
    git -C "$REPO" init -q
    export COMMENT_NOISE_ALLOWLIST="$BATS_TEST_TMPDIR/allowlist.txt"
    : >"$COMMENT_NOISE_ALLOWLIST"
}

# 一時リポジトリに 1 ファイル置いて git に登録する
put() {
    mkdir -p "$REPO/$(dirname "$1")"
    printf '%s\n' "$2" >"$REPO/$1"
    git -C "$REPO" add -- "$1"
}

scan() {
    (cd "$REPO" && bash "$SCRIPT")
}

@test "違反が無ければ出力は空で exit 0" {
    put a.sh '# ふつうのコメント'
    run scan
    assert_success
    assert_output ''
}

@test "plan-step: 計画の内部番号を止め、ルールファイルを案内する" {
    put a.sh '# Task 2 で追加した分岐'
    run scan
    assert_failure 1
    assert_output --partial 'a.sh:1: [plan-step]'
    assert_output --partial 'dot_claude/rules/common/code-comments.md'
}

@test "plan-step: // コメントの Step も止める" {
    put a.js '  // Step 3 の後始末'
    run scan
    assert_failure 1
    assert_output --partial 'a.js:1: [plan-step]'
}

@test "plan-step: 単語の一部や数字の無い Task は止めない" {
    put a.sh $'# Taskfile を読む\n# MultiTask 3 は製品名\n# Task の数を数える'
    run scan
    assert_success
}

@test "issue-origin: 番号の後に経緯の動詞が続くものを止める" {
    put a.sh '# SC1091 が誤って出るため(#309 で発覚)。'
    run scan
    assert_failure 1
    assert_output --partial 'a.sh:1: [issue-origin]'
}

@test "issue-origin: 英語の fixed in #N を止める" {
    put a.js '// fixed in #12'
    run scan
    assert_failure 1
    assert_output --partial '[issue-origin]'
}

@test "issue-origin: 未解決 issue への参照は止めない" {
    put a.sh '# #382(未解決)が直るまでの暫定の手順'
    run scan
    assert_success
}

@test "コードの行と行末コメントは見ない" {
    put a.sh $'echo "Task 2"\nfoo # Task 2 で追加'
    run scan
    assert_success
}

@test "1 行目の shebang は見ない" {
    put a.sh $'#!/usr/bin/env bash Task 1\n: '
    run scan
    assert_success
}

@test "対象外のファイル(md / docs / json)は見ない" {
    put a.md '# Task 2'
    put docs/b.sh '# Task 2'
    put c.json '# Task 2'
    run scan
    assert_success
}

@test "git に登録されていないファイルは見ない" {
    printf '# Task 2\n' >"$REPO/untracked.sh"
    run scan
    assert_success
}

@test "空白を含むファイル名も読む" {
    put 'dir with space/a b.sh' '# Task 2'
    run scan
    assert_failure 1
    assert_output --partial 'dir with space/a b.sh:1: [plan-step]'
}

@test "許可リストに書いた違反は止まらず、外すと止まる" {
    put a.sh '# Task 2 は外部の手順書の番号'
    printf 'a.sh:外部の手順書\n' >"$COMMENT_NOISE_ALLOWLIST"
    run scan
    assert_success
    : >"$COMMENT_NOISE_ALLOWLIST"
    run scan
    assert_failure 1
}

@test "許可リストの * は全ファイルに効き、別ファイルの suffix は効かない" {
    put a.sh '# Task 2 は外部の手順書の番号'
    printf 'b.sh:外部の手順書\n' >"$COMMENT_NOISE_ALLOWLIST"
    run scan
    assert_failure 1
    printf '*:外部の手順書\n' >"$COMMENT_NOISE_ALLOWLIST"
    run scan
    assert_success
}

@test "許可リストのファイルが無くても動く" {
    rm -f "$COMMENT_NOISE_ALLOWLIST"
    put a.sh '# Task 2'
    run scan
    assert_failure 1
}

@test "許可リストの正規表現が不正なら exit 2" {
    put a.sh '# Task 2'
    printf 'a.sh:([\n' >"$COMMENT_NOISE_ALLOWLIST"
    run scan
    assert_failure 2
    assert_output --partial 'invalid regex'
}
