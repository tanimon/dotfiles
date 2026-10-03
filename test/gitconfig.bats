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
# 描画は test/helpers/render.bash を通す。chezmoi が無いときに skip せず失敗させるのも seam が担う。
#
# push の契約は personal だけで見る。work では SSH 形式の GitHub remote を HTTPS に寄せる契約を見る。

setup_file() {
    load 'helpers/render'
    export GITCONFIG_PERSONAL="$BATS_FILE_TMPDIR/gitconfig-personal"
    export GITCONFIG_WORK="$BATS_FILE_TMPDIR/gitconfig-work"
    render_template personal "$RENDER_REPO/dot_gitconfig.tmpl" >"$GITCONFIG_PERSONAL"
    render_template work "$RENDER_REPO/dot_gitconfig.tmpl" >"$GITCONFIG_WORK"
}

setup() {
    load 'helpers/setup'

    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME/.config/git"
    cp "$GITCONFIG_PERSONAL" "$HOME/.gitconfig"
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

# work では SSH 形式の GitHub remote を HTTPS に寄せる(dot_gitconfig.tmpl の work 分岐のコメントに理由)。
# 書き換えは git remote get-url の出力に現れるので、ネットワークなしで確かめられる
@test "work: scp 形式と ssh:// 形式の GitHub remote が https に書き換わる" {
    cp "$GITCONFIG_WORK" "$HOME/.gitconfig"
    git -C "$REPO" remote add scp git@github.com:o/r.git
    git -C "$REPO" remote add sshurl ssh://git@github.com/o/r.git

    run git -C "$REPO" remote get-url scp
    assert_success
    assert_output 'https://github.com/o/r.git'

    run git -C "$REPO" remote get-url sshurl
    assert_success
    assert_output 'https://github.com/o/r.git'
}

@test "対比: personal では GitHub の SSH remote は書き換わらない" {
    git -C "$REPO" remote add scp git@github.com:o/r.git

    run git -C "$REPO" remote get-url scp
    assert_success
    assert_output 'git@github.com:o/r.git'
}

# https→ssh の逆向きルールと共存させると ssh→https が効かなくなる(dot_gitconfig.tmpl の work 分岐のコメント)
@test "work: https から書き換える逆向きの insteadOf が無い" {
    run git config --file "$GITCONFIG_WORK" --get-regexp '^url\..*\.insteadof$'
    assert_success
    refute_line --regexp ' https://'
}

# profile ごとに描画して契約を見るのは .profile で分岐するテンプレートだけ(test/helpers/render.bash)。
# 分岐するテンプレートが増えたらこのテストが落ちる。そのテンプレートの profile ごとの
# 契約テストを書くかを判断してから、一覧を更新すること
@test ".profile で分岐するテンプレートは既知の一覧と一致する" {
    run bash -c 'cd "$1" && git ls-files -z -- "*.tmpl" ".chezmoitemplates/*" | xargs -0 grep -lwF ".profile" | LC_ALL=C sort' _ "$RENDER_REPO"
    assert_success
    assert_output 'dot_gitconfig.tmpl'
}

# 未知の profile を空の描画結果で成功させない(空の結果に対する後続の grep が空振りするため)
@test "render_template は存在しない profile と省略した profile で失敗する" {
    load 'helpers/render'

    run render_template staging "$RENDER_REPO/dot_gitconfig.tmpl"
    assert_failure
    assert_output --partial "profile 'staging'"

    run render_template '' "$RENDER_REPO/dot_gitconfig.tmpl"
    assert_failure
}
