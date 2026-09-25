#!/usr/bin/env bats
#
# .chezmoiscripts/run_onchange_after_pull-nono-packs.sh.tmpl の描画と実行を覆う(#363)。
#
# 実物の nono は呼ばない。PATH の先頭に偽 nono を置いて、テンプレートの描画(バージョンの
# 取り込み)と、描画後のスクリプトが pull → update の順に呼ぶことだけを見る。
# テンプレートは `{{ if eq .chezmoi.os "darwin" }}` で囲まれているので、darwin 以外では
# 描画結果が空になり何も検証できない。そのため CI では走らせず(CI は ubuntu)、
# darwin 以外では skip する(skip の理由は bats が出力するので、空振りの緑にはならない)。

setup() {
    load 'helpers/setup'
    if [ "$(uname -s)" != "Darwin" ]; then
        skip "template is darwin-only"
    fi
    REPO="${BATS_TEST_DIRNAME}/.."
    TMPL="${REPO}/.chezmoiscripts/run_onchange_after_pull-nono-packs.sh.tmpl"
    CONFIG="${BATS_TEST_TMPDIR}/chezmoi-test.toml"
    printf '[data]\n  profile = "personal"\n  ghOrg = "test-org"\n' >"${CONFIG}"
    FAKE_BIN="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${FAKE_BIN}"
    CALLS="${BATS_TEST_TMPDIR}/calls"
    export CALLS
    CHEZMOI="$(command -v chezmoi)"
}

# $1 に書いた本体を持つ偽 nono を FAKE_BIN に作る。呼ばれた引数は $CALLS に追記する
make_fake_nono() {
    local body="$1"
    cat >"${FAKE_BIN}/nono" <<EOF
#!/bin/bash
echo "\$*" >>"\${CALLS}"
${body}
EOF
    chmod +x "${FAKE_BIN}/nono"
}

# 偽 nono だけが見える PATH でテンプレートを描画する
render() {
    PATH="${FAKE_BIN}:/usr/bin:/bin" "${CHEZMOI}" execute-template \
        --config "${CONFIG}" --source "${REPO}" <"${TMPL}"
}

@test "chezmoi が使える" {
    run command -v chezmoi
    assert_success
}

@test "nono のバージョンが描画結果に入る" {
    make_fake_nono 'echo "nono 0.78.0"'
    run render
    assert_success
    assert_output --partial '# nono version: nono 0.78.0'
}

@test "nono --version が失敗しても描画は成功し unknown になる" {
    # 対になる検証: `output "nono" "--version"` のままだとこのケースで描画が失敗する
    make_fake_nono 'exit 3'
    run render
    assert_success
    assert_output --partial '# nono version: unknown'
}

@test "nono --version が複数行を出しても、描画後のスクリプトはコメント 1 行に収まり実行できる" {
    # 2 行目以降がコメントの外に出ると、そのままシェルのコマンドとして実行される
    make_fake_nono '[ "$1" = --version ] && { echo "nono 0.79.0"; echo "extra-line"; exit 0; }
exit 0'
    render >"${BATS_TEST_TMPDIR}/script.sh"
    run grep -c '^extra-line' "${BATS_TEST_TMPDIR}/script.sh"
    assert_output '0'
    run env PATH="${FAKE_BIN}:/usr/bin:/bin" bash "${BATS_TEST_TMPDIR}/script.sh"
    assert_success
}

@test "nono が無いときは not-installed になる" {
    run render
    assert_success
    assert_output --partial '# nono version: not-installed'
}

@test "描画後のスクリプトは pull の後に update を呼ぶ" {
    make_fake_nono 'exit 0'
    render >"${BATS_TEST_TMPDIR}/script.sh"
    run env PATH="${FAKE_BIN}:/usr/bin:/bin" bash "${BATS_TEST_TMPDIR}/script.sh"
    assert_success
    # 1 行目は描画時の --version。以降が実行時の呼び出し
    run tail -n 2 "${CALLS}"
    assert_line --index 0 --regexp '^pull '
    assert_line --index 1 'update'
}

@test "update が失敗しても exit 0 で、手動実行を促す WARNING を出す" {
    make_fake_nono '[ "$1" = update ] && exit 1
exit 0'
    render >"${BATS_TEST_TMPDIR}/script.sh"
    run env PATH="${FAKE_BIN}:/usr/bin:/bin" bash "${BATS_TEST_TMPDIR}/script.sh"
    assert_success
    assert_output --partial "WARNING: nono update failed; run 'nono update' manually"
}
