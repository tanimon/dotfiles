#!/usr/bin/env bats
# Claude Code から実行される git(GIT_CONFIG_GLOBAL = ~/.config/git/claude-code.inc)が、
# upstream の無いブランチを push しても .git/config に書かないことの検査。
# .git/config はどちらのサンドボックスでも書けないので、書きにいくと push の末尾で
# `unable to write upstream branch configuration` が出る。
#
# HOME をテスト用の一時ディレクトリに差し替え、その下に chezmoi で描画した ~/.gitconfig と
# ~/.config/git/claude-code.inc(Source をそのまま複製)を置く。claude-code.inc は
# `[include] path = ~/.gitconfig` で ~/.gitconfig を読むので、include 先もこの HOME に閉じる。
# push の設定は ~/.gitconfig 側にあるので、描画した実物を使わないと検査にならない。
#
# commit は署名しない(-c commit.gpgsign=false)。描画した ~/.gitconfig は署名を有効にしており、
# テスト用の HOME には署名鍵が無い。
#
# chezmoi が無い場合は skip せず fail する(skip にすると CI で全検査が空振りする)。

setup_file() {
    command -v chezmoi >/dev/null || {
        echo "chezmoi が必要(この suite は skip しない)" >&2
        return 1
    }
    local repo="$BATS_TEST_DIRNAME/.."
    local config="$BATS_FILE_TMPDIR/chezmoi-test.toml"
    printf '[data]\n  profile = "personal"\n  ghOrg = "test-org"\n' >"$config"
    export GITCONFIG_RENDERED="$BATS_FILE_TMPDIR/gitconfig"
    chezmoi execute-template --config "$config" --source "$repo" \
        <"$repo/dot_gitconfig.tmpl" >"$GITCONFIG_RENDERED"
}

setup() {
    load 'helpers/setup'

    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME/.config/git"
    cp "$GITCONFIG_RENDERED" "$HOME/.gitconfig"
    cp "${BATS_TEST_DIRNAME}/../dot_config/git/claude-code.inc" "$HOME/.config/git/claude-code.inc"
    unset XDG_CONFIG_HOME
    export GIT_CONFIG_SYSTEM=/dev/null
    export GIT_CONFIG_GLOBAL="$HOME/.config/git/claude-code.inc"

    REMOTE="$BATS_TEST_TMPDIR/remote.git"
    REPO="$BATS_TEST_TMPDIR/repo"
    git init -q --bare "$REMOTE"
    git init -q "$REPO"
    git -C "$REPO" remote add origin "$REMOTE"
    git -C "$REPO" -c commit.gpgsign=false commit -q --allow-empty -m init
    git -C "$REPO" switch -q -c feature
}

@test "upstream の無いブランチへの素の git push が .git/config に書かずに成功する" {
    run git -C "$REPO" push
    assert_success

    run git -C "$REMOTE" rev-parse --verify -q refs/heads/feature
    assert_success

    run git -C "$REPO" config --get-regexp '^branch\.feature\.'
    assert_output ''
}

@test "upstream が無くても長形式の git status に ahead が出る" {
    git -C "$REPO" push -q
    git -C "$REPO" -c commit.gpgsign=false commit -q --allow-empty -m second

    # ahead が upstream 由来ではない(status.compareBranches の @{push} 由来である)ことの前提。
    run git -C "$REPO" config --get-regexp '^branch\.feature\.'
    assert_output ''

    run git -C "$REPO" status
    assert_success
    assert_output --partial "Your branch is ahead of 'origin/feature' by 1 commit"
}

@test "対話ターミナルの git(~/.gitconfig だけ)でも素の git push が upstream を書かずに成功する" {
    export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"

    run git -C "$REPO" push
    assert_success

    run git -C "$REPO" config --get-regexp '^branch\.feature\.'
    assert_output ''
}

# 対比: 検査が書き込みを捕まえられることと、claude-code.inc では push.autoSetupRemote = true を
# 打ち消せないこと(~/.gitconfig に書いてはいけない理由)を示す。
@test "対比: ~/.gitconfig に push.autoSetupRemote = true があると claude-code.inc 越しでも branch.<name>.* が書かれる" {
    printf '[push]\n  autoSetupRemote = true\n' >>"$HOME/.gitconfig"

    run git -C "$REPO" push
    assert_success

    run git -C "$REPO" config --get-regexp '^branch\.feature\.'
    assert_output --partial 'branch.feature.remote origin'
}
