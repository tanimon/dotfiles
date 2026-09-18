#!/usr/bin/env bats
# scripts/pr-context.sh のスモークテスト。
#
# 各ケースは $BATS_TEST_TMPDIR に使い捨ての git リポジトリを組む。GIT_CONFIG_GLOBAL /
# GIT_CONFIG_SYSTEM を潰すのは hermeticity のため: このマシンの ~/.gitconfig は
# 1Password / ai-agent 鍵での commit 署名を有効にしており、それを引き継ぐと
# テストが「スクリプトの挙動」ではなく「署名鍵が使えるか」で通ったり落ちたりする。

setup() {
    load 'helpers/setup'

    SCRIPT="${BATS_TEST_DIRNAME}/../scripts/pr-context.sh"

    # スクリプトが読む環境変数はすべて落とす。呼び出し元のシェルに残っていると
    # ケースが意図と別の理由で通る。
    unset PR_CONTEXT_BASE PR_CONTEXT_SKIP_FETCH

    export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
    export GIT_CONFIG_SYSTEM=/dev/null
    : >"$GIT_CONFIG_GLOBAL"

    REPO="$BATS_TEST_TMPDIR/repo"
}

# origin/main に 1 コミット、その先のブランチに 1 コミットを持つリポジトリを作る。
# origin は同じディスク上のベアリポジトリなので、ネットワークには一切出ない。
make_repo() {
    git init -q -b main "$BATS_TEST_TMPDIR/upstream"
    git -C "$BATS_TEST_TMPDIR/upstream" config user.email t@example.com
    git -C "$BATS_TEST_TMPDIR/upstream" config user.name tester
    git -C "$BATS_TEST_TMPDIR/upstream" config commit.gpgsign false
    echo base >"$BATS_TEST_TMPDIR/upstream/README.md"
    git -C "$BATS_TEST_TMPDIR/upstream" add -A
    git -C "$BATS_TEST_TMPDIR/upstream" commit -q -m base

    git clone -q "$BATS_TEST_TMPDIR/upstream" "$REPO"
    git -C "$REPO" config user.email t@example.com
    git -C "$REPO" config user.name tester
    git -C "$REPO" config commit.gpgsign false
    git -C "$REPO" checkout -q -b feature
    echo added >"$REPO/new-file.txt"
    git -C "$REPO" add -A
    git -C "$REPO" commit -q -m feature
}

# gh を PATH から隠す(実物が入っているマシンでも「gh 不在」の枝を試せるように)。
# PATH を空にはしない — git も bash も見えなくなり、無関係な理由で落ちる。
hide_gh() {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat >"$BATS_TEST_TMPDIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "this fake must be overridden by each test" >&2
exit 127
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

@test "git worktree の外では exit 1 して理由を stderr に出す" {
    mkdir -p "$BATS_TEST_TMPDIR/not-a-repo"
    cd "$BATS_TEST_TMPDIR/not-a-repo"
    # GIT_CEILING_DIRECTORIES がないと、テスト用ディレクトリの祖先にある
    # 本物のリポジトリを掴んでしまい、このケースが空虚に通る。
    export GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR"
    run bash "$SCRIPT"
    assert_failure
    assert_output --partial "not inside a git worktree"
}

@test "ブランチ名・merge-base・変更ファイルを出す" {
    make_repo
    cd "$REPO"
    run env PR_CONTEXT_SKIP_FETCH=1 PATH="$BATS_TEST_TMPDIR/nonexistent-bin:$PATH" bash "$SCRIPT"
    assert_success
    assert_output --partial "feature"
    assert_output --partial "merge-base with origin/main"
    assert_output --partial "new-file.txt"

    # merge-base 行が実際の SHA であることを確認する。見出しだけ出て中身が空でも
    # --partial "merge-base with" は通ってしまうため。
    expected=$(git merge-base origin/main HEAD)
    assert_output --partial "$expected"
}

@test "PR_CONTEXT_SKIP_FETCH を立てると fetch を名指しでスキップする" {
    make_repo
    cd "$REPO"
    run env PR_CONTEXT_SKIP_FETCH=1 bash "$SCRIPT"
    assert_success
    assert_output --partial "skipped: PR_CONTEXT_SKIP_FETCH is set"
}

@test "到達できない remote の fetch 失敗では中断せず、警告して続行する" {
    make_repo
    cd "$REPO"
    git remote set-url origin "$BATS_TEST_TMPDIR/does-not-exist"
    # base ref はクローン時のものがローカルに残っているので、fetch だけが失敗する。
    run bash "$SCRIPT"
    assert_success
    assert_output --partial "fetch failed"
    assert_output --partial "merge-base with origin/main"
}

@test "base ref がローカルに無ければ exit 1" {
    make_repo
    cd "$REPO"
    run env PR_CONTEXT_SKIP_FETCH=1 bash "$SCRIPT" origin/no-such-branch
    assert_failure
    assert_output --partial "base ref not found locally: origin/no-such-branch"
}

@test "位置引数で base ref を差し替えられる" {
    make_repo
    cd "$REPO"
    # PR_CONTEXT_SKIP_FETCH は立てない。remote を含まない ref では fetch 自体が
    # 成立しないので、スクリプト側がその理由を名指しで出すこと自体を確認する
    # (SKIP_FETCH を立てるとそちらが先に効いて、この枝が試されない)。
    run bash "$SCRIPT" main
    assert_success
    assert_output --partial "merge-base with main"
    assert_output --partial "names no remote"
}

@test "gh が PATH に無ければ、黙って終わらず名指しでスキップする" {
    make_repo
    cd "$REPO"
    # gh だけを外した PATH を組む。git/bash は残す。
    mkdir -p "$BATS_TEST_TMPDIR/slim"
    for tool in git bash env sed grep; do
        resolved=$(command -v "$tool") || continue
        ln -sf "$resolved" "$BATS_TEST_TMPDIR/slim/$tool"
    done
    run env PR_CONTEXT_SKIP_FETCH=1 PATH="$BATS_TEST_TMPDIR/slim" bash "$SCRIPT"
    assert_success
    assert_output --partial "skipped: gh not on PATH"
}

@test "PR が無いブランチでは gh の非ゼロ終了を通常状態として扱う" {
    make_repo
    cd "$REPO"
    hide_gh
    cat >"$BATS_TEST_TMPDIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "no pull requests found for branch \"feature\"" >&2
exit 1
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/gh"
    run env PR_CONTEXT_SKIP_FETCH=1 PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash "$SCRIPT"
    assert_success
    assert_output --partial "no pull request for this branch"
}

@test "PR があれば view と checks の出力を両方出す" {
    make_repo
    cd "$REPO"
    hide_gh
    cat >"$BATS_TEST_TMPDIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$2" in
    view) echo '{"number":123,"title":"t","state":"OPEN","isDraft":false,"url":"u"}' ;;
    checks) echo "lint	pass	1s" ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/gh"
    run env PR_CONTEXT_SKIP_FETCH=1 PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash "$SCRIPT"
    assert_success
    assert_output --partial '"number":123'
    assert_output --partial "pull request checks"
    assert_output --partial "lint"
}

@test "checks が非ゼロで終了しても、その出力を捨てない" {
    make_repo
    cd "$REPO"
    hide_gh
    cat >"$BATS_TEST_TMPDIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$2" in
    view) echo '{"number":123,"title":"t","state":"OPEN","isDraft":false,"url":"u"}' ;;
    checks) echo "lint	fail	1s"; exit 1 ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/gh"
    run env PR_CONTEXT_SKIP_FETCH=1 PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash "$SCRIPT"
    assert_success
    assert_output --partial "fail"
}
