#!/usr/bin/env bats
#
# 道具が無いと警告を出して飛ばす run_onchange_ スクリプトが、道具が PATH に現れた後の apply で
# 再実行されることを覆う。run_onchange_ は飛ばした回も実行済みと記録するので、描画結果が
# 変わらない限り二度と走らない。ここでは「道具の有無で描画結果が変わる」ことを見る。
#
# 対象のテンプレートには `{{ if eq .chezmoi.os "darwin" }}` で囲まれたものがあり、darwin 以外では
# 描画結果が空になって比較の意味が無いので、darwin 以外では skip する(CI は ubuntu)。

setup() {
    load 'helpers/setup'
    if [ "$(uname -s)" != "Darwin" ]; then
        skip "templates are darwin-only"
    fi
    load 'helpers/render'
    FAKE_BIN="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${FAKE_BIN}"
}

# TEMPLATE を、偽の TOOL を PATH に置いた場合と置かない場合で描画し、結果が異なることを確かめる
assert_rerenders_when_tool_appears() {
    local tool="$1" template="${RENDER_REPO}/.chezmoiscripts/$2"
    local without with
    without=$(PATH="${FAKE_BIN}:/usr/bin:/bin" render_template personal "${template}") || fail "描画に失敗: ${template}"
    cat >"${FAKE_BIN}/${tool}" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${FAKE_BIN}/${tool}"
    with=$(PATH="${FAKE_BIN}:/usr/bin:/bin" render_template personal "${template}") || fail "描画に失敗: ${template}"
    [ -n "${without}" ] || fail "描画結果が空: ${template}"
    [ "${without}" != "${with}" ] || fail "${tool} の有無で描画結果が変わらない: ${template}"
}

@test "gh が PATH に現れると gh extensions の導入スクリプトの描画結果が変わる" {
    assert_rerenders_when_tool_appears gh run_onchange_after_install-gh-extensions.sh.tmpl
}

@test "sheldon が PATH に現れると sheldon の lock スクリプトの描画結果が変わる" {
    assert_rerenders_when_tool_appears sheldon run_onchange_after_sheldon-lock.sh.tmpl
}

@test "apm が PATH に現れると apm の導入スクリプトの描画結果が変わる" {
    assert_rerenders_when_tool_appears apm run_onchange_after_apm-install.sh.tmpl
}

@test "pnpm が PATH に現れると pre-commit フックの導入スクリプトの描画結果が変わる" {
    assert_rerenders_when_tool_appears pnpm run_onchange_install-pre-commit-hooks.sh.tmpl
}

@test "prek が PATH に現れると pre-commit フックの導入スクリプトの描画結果が変わる" {
    assert_rerenders_when_tool_appears prek run_onchange_install-pre-commit-hooks.sh.tmpl
}
