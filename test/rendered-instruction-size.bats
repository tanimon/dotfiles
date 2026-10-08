#!/usr/bin/env bats
# 合成後のグローバル指示(~/.codex/AGENTS.md など)のサイズ上限(ADR 0011 の肥大の歯止め)。
# 測る対象と上限は scripts/instruction-size-limits.txt の render: の行が正本で、ここには書かない。
# このファイルは描画だけを受け持つ: --list-rendered の各テンプレートを test/fixtures/chezmoi-*.toml の
# すべての profile で描画し、scripts/check-instruction-size.sh --rendered で測る。
#
# 描画の失敗は「描画が exit 0 で終わり、出力が空でない」ことで捕まえる。サイズの下限で捕まえないのは、
# 目安の下限が実際の出力の縮小と区別できないため。
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

@test "合成後の出力はすべての profile で上限に収まる" {
    local templates profiles=() config template profile count=0
    templates=$(cd "$RENDER_REPO" && bash "$SCRIPT" --list-rendered)
    [ -n "$templates" ] || fail "render: の行が 1 件も無い"
    for config in "$RENDER_REPO"/test/fixtures/chezmoi-*.toml; do
        [ -f "$config" ] || continue
        profile=${config##*/chezmoi-}
        profiles+=("${profile%.toml}")
    done
    [ "${#profiles[@]}" -gt 0 ] || fail "profile の fixture が 1 件も無い"
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
    local template="$BATS_TEST_TMPDIR/big.tmpl" limit
    # 上限の値は一覧から読む(一覧の上限を変えてもこのテストが追従するように)
    limit=$(awk '$1 == "render:dot_codex/AGENTS.md.tmpl" { print $3 }' "$RENDER_REPO/scripts/instruction-size-limits.txt")
    [[ "$limit" =~ ^[0-9]+$ ]] || fail "render:dot_codex/AGENTS.md.tmpl の上限が一覧から読めない: '$limit'"
    printf '{{ repeat %d "x" }}' "$((limit + 1))" >"$template"
    run measure_rendered dot_codex/AGENTS.md.tmpl personal "$template"
    assert_failure 1
    assert_output --partial "render:dot_codex/AGENTS.md.tmpl: $((limit + 1)) バイト"
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
