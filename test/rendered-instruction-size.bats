#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# 描画してから測るテンプレートのサイズ上限(ADR 0011 の肥大の歯止め)。対象は 2 種類で、どちらも
# scripts/check-instruction-size.sh が列挙し、上限もそちらが決める(ここには書かない):
# - --list-rendered: 合成後のグローバル指示(~/.codex/AGENTS.md など)。scripts/instruction-size-limits.txt の
#   render: の行が正本
# - --list-templates: 配置先が判定の対象のテンプレート(SKILL.md.tmpl など)
# このファイルは描画だけを受け持つ: 各テンプレートを test/fixtures/chezmoi-*.toml のすべての profile で描画し、
# scripts/check-instruction-size.sh --rendered で測る。
#
# render: の行の描画の失敗は「描画が exit 0 で終わり、出力が空でない」ことで捕まえる。サイズの下限で捕まえないのは、
# 目安の下限が実際の出力の縮小と区別できないため。--list-templates のテンプレートは出力が空でも落とさない
# (その profile では配置されない。chezmoi は空の配置先を作らない)。描画の失敗はどちらも落ちる。
# chezmoi が無いときは test/helpers/render.bash の読み込みで失敗する(skip しない)。

setup() {
    load 'helpers/setup'
    load 'helpers/render'
    SCRIPT="$RENDER_REPO/scripts/check-instruction-size.sh"
}

# measure_rendered NAME PROFILE TEMPLATE: TEMPLATE を PROFILE で描画し、NAME の上限で測る
measure_rendered() {
    local out="$BATS_TEST_TMPDIR/rendered-$2.out"
    render_template "$2" "$3" >"$out" || {
        echo "$3 を profile $2 で描画できない" >&2
        return 1
    }
    [ -s "$out" ] || {
        echo "$3 を profile $2 で描画した出力が空" >&2
        return 1
    }
    (cd "$RENDER_REPO" && bash "$SCRIPT" --rendered "$1" "$out")
}

# load_profiles: test/fixtures/chezmoi-*.toml の profile の名前を profiles に入れる
load_profiles() {
    local config profile
    profiles=()
    for config in "$RENDER_REPO"/test/fixtures/chezmoi-*.toml; do
        [ -f "$config" ] || continue
        profile=${config##*/chezmoi-}
        profiles+=("${profile%.toml}")
    done
    [ "${#profiles[@]}" -gt 0 ] || fail "profile の fixture が 1 件も無い"
}

# measure_templates REPO: REPO の --list-templates の各テンプレートをすべての profile で描画し、REPO の上限の一覧で測る。
# 描画は RENDER_REPO を source にする(REPO のテンプレートが RENDER_REPO の .chezmoitemplates を取り込んでも描画できる)
measure_templates() {
    local repo=$1 templates template profile out profiles
    templates=$(cd "$repo" && bash "$SCRIPT" --list-templates) || return
    load_profiles
    while IFS= read -r template; do
        [ -n "$template" ] || continue
        for profile in "${profiles[@]}"; do
            out="$BATS_TEST_TMPDIR/template-$profile.out"
            render_template "$profile" "$repo/$template" >"$out" || {
                echo "$template を profile $profile で描画できない" >&2
                return 1
            }
            (cd "$repo" && bash "$SCRIPT" --rendered "$template" "$out") || return
        done
    done <<<"$templates"
}

@test "合成後の出力はすべての profile で上限に収まる" {
    local templates profiles template profile count=0
    templates=$(cd "$RENDER_REPO" && bash "$SCRIPT" --list-rendered)
    [ -n "$templates" ] || fail "render: の行が 1 件も無い"
    load_profiles
    while IFS= read -r template; do
        for profile in "${profiles[@]}"; do
            run measure_rendered "$template" "$profile" "$RENDER_REPO/$template"
            assert_success
            count=$((count + 1))
        done
    done <<<"$templates"
    [ "$count" -eq $(($(wc -l <<<"$templates") * ${#profiles[@]})) ]
}

# measure_rendered が本当に落ちることの確認。落ちない実装でも「合成後の出力はすべての profile で上限に収まる」は通るため
@test "上限を超える出力は落ちる" {
    local template="$BATS_TEST_TMPDIR/big.tmpl"
    # 1 MiB はどの上限よりも十分大きい。一覧を読むのは check-instruction-size.sh だけにするため、
    # 上限の値をここで一覧から読んだり直書きしたりしない
    printf '{{ repeat 1048576 "x" }}' >"$template"
    run measure_rendered dot_codex/AGENTS.md.tmpl personal "$template"
    assert_failure 1
    assert_output --partial "render:dot_codex/AGENTS.md.tmpl: 1048576 バイト"
}

@test "描画に失敗したテンプレートは落ちる" {
    local template="$BATS_TEST_TMPDIR/broken.tmpl"
    printf '{{ template "no-such-template" }}' >"$template"
    run measure_rendered dot_codex/AGENTS.md.tmpl personal "$template"
    assert_failure
    assert_output --partial '描画できない'
}

@test "出力が空のテンプレートは落ちる" {
    local template="$BATS_TEST_TMPDIR/empty.tmpl"
    : >"$template"
    run measure_rendered dot_codex/AGENTS.md.tmpl personal "$template"
    assert_failure
    assert_output --partial '出力が空'
}

# 配置先が判定の対象のテンプレート。実リポジトリには 1 件も無くてよい(0 件でも落とさない)ので、
# 同じ measure_templates を一時リポジトリに当てて、落ちるべきときに落ちることを確かめる
@test "配置先が判定の対象のテンプレートはすべての profile で上限に収まる" {
    run measure_templates "$RENDER_REPO"
    assert_success
}

# 既定値は 3 行 / 20 バイト、skill:* は 6 行 / 60 バイト
setup_template_repo() {
    REPO="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$REPO/scripts" "$REPO/dot_claude/skills/a"
    git -C "$REPO" init -q -b main
    printf '* 3 20\nskill:* 6 60\n' >"$REPO/scripts/instruction-size-limits.txt"
}

@test "SKILL.md のテンプレートは描画後の内容を skill:* で測る" {
    setup_template_repo
    printf '{{ repeat 6 "x\\n" }}' >"$REPO/dot_claude/skills/a/SKILL.md.tmpl"
    run measure_templates "$REPO"
    assert_success
    printf '{{ repeat 7 "x\\n" }}' >"$REPO/dot_claude/skills/a/SKILL.md.tmpl"
    run measure_templates "$REPO"
    assert_failure 1
    assert_output --partial 'dot_claude/skills/a/SKILL.md.tmpl: 7 行(上限 6、+1 行)'
}

@test "テンプレートの描画に失敗したら落ちる" {
    setup_template_repo
    printf '{{ template "no-such-template" }}' >"$REPO/dot_claude/skills/a/SKILL.md.tmpl"
    run measure_templates "$REPO"
    assert_failure
    assert_output --partial '描画できない'
}

@test "テンプレートは profile ごとに測り、出力が空の profile では通す" {
    setup_template_repo
    # personal では空(配置されない)、work では上限を超える
    printf '{{ if eq .profile "work" }}{{ repeat 7 "x\\n" }}{{ end }}' >"$REPO/dot_claude/skills/a/SKILL.md.tmpl"
    run render_template personal "$REPO/dot_claude/skills/a/SKILL.md.tmpl"
    assert_success
    assert_output ''
    # 判定の対象は profile に依存しない: personal で配置されないテンプレートも一覧に出る
    run --separate-stderr bash -c 'cd "$1" && bash "$2" --list-templates' _ "$REPO" "$SCRIPT"
    assert_success
    assert_output 'dot_claude/skills/a/SKILL.md.tmpl'
    run measure_templates "$REPO"
    assert_failure 1
    assert_output --partial 'dot_claude/skills/a/SKILL.md.tmpl: 7 行(上限 6、+1 行)'
}
