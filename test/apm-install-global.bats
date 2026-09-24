#!/usr/bin/env bats
#
# scripts/apm-install-global.sh — de-link / install / re-link の判断を覆う。
#
# 実物の apm も nono も呼ばない。APM_BIN に偽バイナリを差し込み、APM_INSTALL_HOME に
# 偽のホームを与えて、トポロジの遷移だけを見る。偽 apm はヒアドキュメントで作る
# (printf だと外側のコマンド置換と衝突する — .claude/rules/shell-scripts.md)。

setup() {
    load 'helpers/setup'
    SCRIPT="${BATS_TEST_DIRNAME}/../scripts/apm-install-global.sh"
    FAKE_HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${FAKE_HOME}/.claude"
    export APM_INSTALL_HOME="${FAKE_HOME}"
    export APM_TARGETS='claude,codex'
    # 呼び出し側のシェルから漏れてくる可能性のあるものを落とす
    unset APM_BIN
}

# 実体 + symlink の、通常のトポロジを作る
make_linked_topology() {
    printf '{"mcpServers":{"deepwiki":{}}}\n' >"${FAKE_HOME}/.claude/claude.json"
    ln -s .claude/claude.json "${FAKE_HOME}/.claude.json"
}

# $1 に書いた本体を持つ偽 apm を作り、APM_BIN に設定する
make_fake_apm() {
    local body="$1"
    local path="${BATS_TEST_TMPDIR}/fake-apm"
    cat >"${path}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
${body}
EOF
    chmod +x "${path}"
    export APM_BIN="${path}"
}

@test "linked topology: de-links before apm runs and re-links afterwards" {
    make_linked_topology
    make_fake_apm 'test -f "${APM_INSTALL_HOME}/.claude.json" || exit 1
test -L "${APM_INSTALL_HOME}/.claude.json" && exit 1
test -e "${APM_INSTALL_HOME}/.claude/claude.json" && exit 1
echo "apm saw a regular file"'

    run bash "${SCRIPT}"
    assert_success
    assert_output --partial 'apm saw a regular file'

    # トポロジが元に戻っていること
    [ -L "${FAKE_HOME}/.claude.json" ]
    [ -f "${FAKE_HOME}/.claude/claude.json" ]
    [ ! -L "${FAKE_HOME}/.claude/claude.json" ]
    [ "$(readlink "${FAKE_HOME}/.claude.json")" = '.claude/claude.json' ]
    assert_equal "$(cat "${FAKE_HOME}/.claude.json")" '{"mcpServers":{"deepwiki":{}}}'
}

@test "already de-linked: leaves the regular file alone" {
    printf '{"mcpServers":{}}\n' >"${FAKE_HOME}/.claude.json"
    make_fake_apm 'test -f "${APM_INSTALL_HOME}/.claude.json" || exit 1
test -L "${APM_INSTALL_HOME}/.claude.json" && exit 1
true'

    run bash "${SCRIPT}"
    assert_success

    [ -f "${FAKE_HOME}/.claude.json" ]
    [ ! -L "${FAKE_HOME}/.claude.json" ]
    [ ! -e "${FAKE_HOME}/.claude/claude.json" ]
}

@test "nono re-links during the window: leaves it as is, no clobber" {
    make_linked_topology
    # 偽 apm が nono のふるまい(実体を戻して symlink を張る)を再現する
    make_fake_apm 'mv "${APM_INSTALL_HOME}/.claude.json" "${APM_INSTALL_HOME}/.claude/claude.json"
ln -s .claude/claude.json "${APM_INSTALL_HOME}/.claude.json"'

    run bash "${SCRIPT}"
    assert_success
    assert_output --partial 're-linked by nono during the window'

    [ -L "${FAKE_HOME}/.claude.json" ]
    assert_equal "$(cat "${FAKE_HOME}/.claude.json")" '{"mcpServers":{"deepwiki":{}}}'
}

# 2026-09-24 の事故の回帰テスト。de-link 中に ~/.claude/claude.json が(中身を持って)
# 再出現したとき、素の `mv` はその実体を symlink で上書きして設定を丸ごと失う。
@test "real path reappears during the window: aborts instead of clobbering it" {
    make_linked_topology
    make_fake_apm 'printf "{\"other\":true}\n" > "${APM_INSTALL_HOME}/.claude/claude.json"'

    run bash "${SCRIPT}"
    # 70 は「人間が見るまで apply を止める」専用コード。run_onchange 側はこれだけを
    # 伝播させ、apm 自身の失敗(上のケースの 3)は警告で流す。
    assert_equal "$status" 70
    assert_output --partial 'refusing to move'

    # 呼び出し前の中身がどちらのパスからも失われていないこと
    [ ! -L "${FAKE_HOME}/.claude.json" ]
    assert_equal "$(cat "${FAKE_HOME}/.claude.json")" '{"mcpServers":{"deepwiki":{}}}'
    assert_equal "$(cat "${FAKE_HOME}/.claude/claude.json")" '{"other":true}'
}

@test "apm failure: still re-links, and propagates the exit status" {
    make_linked_topology
    make_fake_apm 'echo "boom" >&2
exit 3'

    run bash "${SCRIPT}"
    assert_equal "$status" 3
    assert_output --partial 'apm install --global --target claude,codex failed'

    [ -L "${FAKE_HOME}/.claude.json" ]
    assert_equal "$(cat "${FAKE_HOME}/.claude.json")" '{"mcpServers":{"deepwiki":{}}}'
}

@test "apm missing: skips without touching the topology" {
    make_linked_topology
    export APM_BIN="${BATS_TEST_TMPDIR}/no-such-apm"

    run bash "${SCRIPT}"
    assert_success
    assert_output --partial 'apm CLI not found'

    [ -L "${FAKE_HOME}/.claude.json" ]
    [ -f "${FAKE_HOME}/.claude/claude.json" ]
}

@test "unexpected topology: does not move anything, still runs apm" {
    # symlink はあるが実体が無い(壊れた形)
    ln -s .claude/claude.json "${FAKE_HOME}/.claude.json"
    make_fake_apm 'echo "apm ran"'

    run bash "${SCRIPT}"
    assert_success
    assert_output --partial 'leaving the topology alone'
    assert_output --partial 'apm ran'

    [ -L "${FAKE_HOME}/.claude.json" ]
}
