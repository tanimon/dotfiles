#!/usr/bin/env bats
# scripts/pr-context.sh のスモークテスト。
#
# 各ケースは $BATS_TEST_TMPDIR に使い捨ての git リポジトリを組む。GIT_CONFIG_GLOBAL /
# GIT_CONFIG_SYSTEM を潰すのは hermeticity のため: このマシンの ~/.gitconfig は
# 1Password / ai-agent 鍵での commit 署名を有効にしており、それを引き継ぐと
# テストが「スクリプトの挙動」ではなく「署名鍵が使えるか」で通ったり落ちたりする。
#
# gh も同じ理由で必ずテストの支配下に置く。実物が入っているマシンでは、テスト用
# リポジトリのリモートが GitHub ではないために gh が非ゼロで落ち、ケースが
# 「意図した枝を通ったから」ではなく「無関係な理由で落ちたから」通ってしまう。

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

    # install_gh / hide_gh が PATH を組み直すための基準。
    ORIG_PATH="$PATH"

    # 既定は「PR がまだ無いブランチ」の gh。gh の枝を見ないケースでも実物には
    # 到達させない。gh を見るケースは install_gh / hide_gh で明示的に上書きする。
    install_gh <<'EOF'
#!/usr/bin/env bash
echo 'no pull requests found for branch "feature"' >&2
exit 1
EOF
}

# hide_gh が組む PATH は gh を隠すために意図的に痩せている。そのまま抜けると
# bats 自身の後片付け(rm)まで見えなくなり、全ケース ok のまま exit 1 する。
teardown() {
    if [[ -n ${ORIG_PATH:-} ]]; then
        export PATH="$ORIG_PATH"
    fi
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

# 標準入力で渡した中身の偽 gh を PATH の先頭に置く。
#
# 「存在しないディレクトリを PATH に前置する」形では実物は隠れない —
# command -v はそのディレクトリを飛ばして後ろの本物を見つける。基準の
# $ORIG_PATH から組み直すので、同じケース内で何度呼んでも重ならない。
install_gh() {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat >"$BATS_TEST_TMPDIR/bin/gh"
    chmod +x "$BATS_TEST_TMPDIR/bin/gh"
    export PATH="$BATS_TEST_TMPDIR/bin:$ORIG_PATH"
}

# gh だけを PATH から外す(実物が入っているマシンでも「gh 不在」の枝を試せるように)。
# PATH を空にはしない — git も bash も見えなくなり、無関係な理由で落ちる。
hide_gh() {
    local tool resolved
    mkdir -p "$BATS_TEST_TMPDIR/slim"
    for tool in git bash env sed grep; do
        resolved=$(command -v "$tool") || continue
        ln -sf "$resolved" "$BATS_TEST_TMPDIR/slim/$tool"
    done
    export PATH="$BATS_TEST_TMPDIR/slim"
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
    run env PR_CONTEXT_SKIP_FETCH=1 bash "$SCRIPT"
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

@test "PR_CONTEXT_SKIP_FETCH は値ではなく set されているかで効く" {
    make_repo
    cd "$REPO"
    # scripts/scan-sensitive-info.sh と同じ規約(set されていれば値は問わない)。
    # =0 が「スキップしない」に見える書き方だと、意図と逆に黙って fetch する。
    run env PR_CONTEXT_SKIP_FETCH=0 bash "$SCRIPT"
    assert_success
    assert_output --partial "skipped: PR_CONTEXT_SKIP_FETCH is set"
}

@test "到達できない remote の fetch 失敗では中断せず、原因ごと出して続行する" {
    make_repo
    cd "$REPO"
    git remote set-url origin "$BATS_TEST_TMPDIR/does-not-exist"
    # base ref はクローン時のものがローカルに残っているので、fetch だけが失敗する。
    run bash "$SCRIPT"
    assert_success
    assert_output --partial "fetch failed"
    # git 自身のメッセージが届いていること。「失敗した」だけでは、到達不能なのか
    # 認証が切れたのかリモート名の誤りなのかが読み手に分からない。
    assert_output --partial "does-not-exist"
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

@test "PR_CONTEXT_BASE でも差し替えられ、位置引数がそれに優先する" {
    make_repo
    cd "$REPO"
    run env PR_CONTEXT_SKIP_FETCH=1 PR_CONTEXT_BASE=main bash "$SCRIPT"
    assert_success
    assert_output --partial "merge-base with main"

    # 優先順位も対で確かめる。片側だけだと、env と位置引数のどちらか一方を
    # 無視する実装でも通ってしまう。
    run env PR_CONTEXT_SKIP_FETCH=1 PR_CONTEXT_BASE=no-such-ref bash "$SCRIPT" main
    assert_success
    assert_output --partial "merge-base with main"
    refute_output --partial "no-such-ref"
}

@test "スラッシュを含むローカルブランチを remote/branch と誤認しない" {
    make_repo
    cd "$REPO"
    git -C "$REPO" branch topic/slash main
    # 「スラッシュがあれば remote 指定」と決め打つと remote=topic branch=slash を
    # fetch しにいき、無関係な失敗として報告される。
    run bash "$SCRIPT" topic/slash
    assert_success
    assert_output --partial "names no remote"
    refute_output --partial "fetch failed"
}

@test "gh が PATH に無ければ、黙って終わらず名指しでスキップする" {
    make_repo
    cd "$REPO"
    hide_gh
    run env PR_CONTEXT_SKIP_FETCH=1 bash "$SCRIPT"
    assert_success
    assert_output --partial "skipped: gh not on PATH"
}

@test "PR が無いブランチでは gh 自身のメッセージをそのまま出す" {
    make_repo
    cd "$REPO"
    install_gh <<'EOF'
#!/usr/bin/env bash
echo 'no pull requests found for branch "feature"' >&2
exit 1
EOF
    run env PR_CONTEXT_SKIP_FETCH=1 bash "$SCRIPT"
    assert_success
    assert_output --partial "no pull requests found"
    refute_output --partial "gh auth login"
}

@test "gh が使えないときを、PR 無しと同じ文言に潰さない" {
    make_repo
    cd "$REPO"
    # 上のケースとの対。gh の非ゼロ終了を一律「no pull request for this branch」に
    # 潰す実装は両方を同じ出力にするので、片方だけのアサートでは通ってしまう。
    install_gh <<'EOF'
#!/usr/bin/env bash
echo 'To get started with GitHub CLI, please run: gh auth login' >&2
exit 4
EOF
    run env PR_CONTEXT_SKIP_FETCH=1 bash "$SCRIPT"
    assert_success
    assert_output --partial "gh auth login"
    refute_output --partial "no pull requests found"
}

@test "PR があれば view と checks の出力を両方出す" {
    make_repo
    cd "$REPO"
    install_gh <<'EOF'
#!/usr/bin/env bash
case "$2" in
    view) echo '{"number":123,"title":"t","state":"OPEN","isDraft":false,"url":"u"}' ;;
    checks) echo "lint	pass	1s" ;;
    *) exit 1 ;;
esac
EOF
    run env PR_CONTEXT_SKIP_FETCH=1 bash "$SCRIPT"
    assert_success
    assert_output --partial '"number":123'
    assert_output --partial "pull request checks"
    assert_output --partial "lint"
}

@test "checks が非ゼロで終了しても、その出力を捨てない" {
    make_repo
    cd "$REPO"
    install_gh <<'EOF'
#!/usr/bin/env bash
case "$2" in
    view) echo '{"number":123,"title":"t","state":"OPEN","isDraft":false,"url":"u"}' ;;
    checks) echo "lint	fail	1s"; exit 1 ;;
    *) exit 1 ;;
esac
EOF
    run env PR_CONTEXT_SKIP_FETCH=1 bash "$SCRIPT"
    assert_success
    assert_output --partial "fail"
}

@test "書き込み系の git サブコマンドを含まない" {
    # これは「git コマンドを bash scripts/*.sh に包む」このリポジトリで最初の例。
    # 包むと引数が dot_claude/scripts/executable_git-push-guard.sh からも
    # permission rule からも見えなくなるため、書き込み系をここに足してはいけない。
    # commit メッセージに書いた設計判断を、文書ではなくコードで固定する。
    # (git fetch はリモート追跡 ref のみを更新する既知の例外なので対象外)
    local pattern='(^|[^[:alnum:]_-])git +(push|commit|reset|rebase|merge|checkout|switch|restore|clean|stash|cherry-pick|am|apply|tag|gc|prune|update-ref|symbolic-ref|remote +(add|remove|rename|set-url))([^[:alnum:]_-]|$)'

    run grep -nE "$pattern" "$SCRIPT"
    [ "$status" -eq 1 ] || fail "grep が想定外の終了コード ${status} を返しました: ${output}"

    # 対照。regex が壊れていると上の assert は何も検査せずに通るので、
    # 同じ regex が実際に git push を捕まえることを確かめる。
    printf 'git push origin main\n' >"$BATS_TEST_TMPDIR/positive-control"
    run grep -nE "$pattern" "$BATS_TEST_TMPDIR/positive-control"
    assert_success
}
