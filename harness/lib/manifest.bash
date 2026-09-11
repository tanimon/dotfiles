#!/usr/bin/env bash
# Harness Manifest(JSON)の読み込み・検証・問い合わせ。harness.sh から source される。
# 依存: report.bash(die)、jq、HARNESS_HOME(harness/ の絶対パス)
#
# スキーマは docs/superpowers/specs/2026-09-11-harness-sync-seam-design.md
# 「Harness Manifest スキーマ(version 1)」。検証エラーはすべて "manifest: <理由>" で exit 2。
#
# shellcheck disable=SC2016
# ファイル全体: jq クエリ中の $var はシェル変数ではなく jq 自身の --arg/--argjson 変数なので、
# シングルクォートのまま展開させない(SC2016 は意図した挙動への誤検知)。

# manifest_load PATH: 読み込んで検証し、HARNESS_MANIFEST(絶対パス)と
# HARNESS_MANIFEST_JSON(compact JSON)を設定する
manifest_load() {
    local path=$1
    command -v jq >/dev/null 2>&1 || die 2 "manifest: jq が必要です (brew install jq)"
    [ -f "$path" ] || die 2 "manifest: ファイルがありません: $path"
    HARNESS_MANIFEST_JSON=$(jq -c . "$path" 2>/dev/null) || die 2 "manifest: JSON として解釈できません: $path"
    HARNESS_MANIFEST="$(cd "$(dirname "$path")" && pwd)/$(basename "$path")"
    export HARNESS_MANIFEST
    manifest_validate
}

# manifest_query JQ_ARGS...: HARNESS_MANIFEST_JSON に対して jq -r を実行する
manifest_query() {
    jq -r "$@" <<<"$HARNESS_MANIFEST_JSON"
}

# manifest_runtimes: runtime 名を 1 行ずつ出力
manifest_runtimes() {
    manifest_query '.runtimes | keys[]'
}

# manifest_runtime_field NAME FIELD: runtimes.NAME.FIELD(無ければ空)
manifest_runtime_field() {
    manifest_query --arg n "$1" --arg f "$2" '.runtimes[$n][$f] // empty'
}

manifest_target_count() {
    manifest_query '.targets | length'
}

# manifest_target INDEX: targets[INDEX] を compact JSON で出力
manifest_target() {
    manifest_query -c --argjson i "$1" '.targets[$i]'
}

# adapter_path OWNER: adapter 実行ファイルのパスを出力。
# 解決順は HARNESS_ADAPTER_DIR(設定時)→ $HARNESS_HOME/adapters。無ければ return 1
adapter_path() {
    local owner=$1 dir candidate dirs=()
    [ -z "${HARNESS_ADAPTER_DIR:-}" ] || dirs+=("$HARNESS_ADAPTER_DIR")
    dirs+=("$HARNESS_HOME/adapters")
    for dir in "${dirs[@]}"; do
        candidate="$dir/$owner.sh"
        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

manifest_validate() {
    local version
    version=$(manifest_query '.version // "missing"')
    [ "$version" = "1" ] || die 2 "manifest: version は 1 でなければなりません (現在: $version)"

    # runtime の暗黙検出は許さない: runtimes は非空オブジェクトで、"*" キーや bin:"auto" を含まない
    [ "$(manifest_query '.runtimes | type')" = "object" ] ||
        die 2 "manifest: runtimes を明示してください (runtime の暗黙検出はしません)"
    [ "$(manifest_query '.runtimes | length')" -gt 0 ] ||
        die 2 "manifest: runtimes が空です (runtime の暗黙検出はしません)"
    [ "$(manifest_query '.runtimes | has("*")')" = "false" ] ||
        die 2 'manifest: runtimes に "*" は使えません (runtime を明示してください)'

    local name bin min
    while IFS= read -r name; do
        bin=$(manifest_runtime_field "$name" bin)
        min=$(manifest_runtime_field "$name" minVersion)
        [ -n "$bin" ] || die 2 "manifest: runtimes.$name.bin が必要です"
        [ "$bin" != "auto" ] || die 2 "manifest: runtimes.$name.bin に \"auto\" は使えません (実行ファイル名を明示してください)"
        [ -n "$min" ] || die 2 "manifest: runtimes.$name.minVersion が必要です"
    done < <(manifest_runtimes)

    [ "$(manifest_query '.targets | type')" = "array" ] || die 2 "manifest: targets は配列でなければなりません"

    # Target Owner は 1 target につき 1 つ: 同じ path が 2 回出たら manifest 全体を reject
    local dup owners
    dup=$(manifest_query '[.targets[].path] | group_by(.) | map(select(length > 1) | .[0]) | .[0] // empty')
    if [ -n "$dup" ]; then
        owners=$(manifest_query --arg p "$dup" '[.targets[] | select(.path == $p) | .owner] | join(", ")')
        die 2 "manifest: target \"$dup\" の owner が重複しています ($owners)"
    fi

    local i count path runtime owner
    count=$(manifest_target_count)
    for ((i = 0; i < count; i++)); do
        path=$(manifest_query --argjson i "$i" '.targets[$i].path // empty')
        runtime=$(manifest_query --argjson i "$i" '.targets[$i].runtime // empty')
        owner=$(manifest_query --argjson i "$i" '.targets[$i].owner // empty')
        [ -n "$path" ] || die 2 "manifest: targets[$i].path が必要です"
        [ -n "$runtime" ] || die 2 "manifest: targets[$i].runtime が必要です"
        [ -n "$owner" ] || die 2 "manifest: targets[$i].owner が必要です"

        # path は正規化せず拒否する(realpath は macOS 標準に無い): 絶対パス・"."/".." セグメント・
        # 空セグメント(//)・改行を含む path は、"./AGENTS.md" のような別表記で重複検出(生パスの
        # 文字列一致)をすり抜け、1 Target に 2 owner を許してしまう(#309 レビュー Critical-1)
        local path_invalid
        path_invalid=$(manifest_query --argjson i "$i" '.targets[$i].path | test("^/|(^|/)\\.\\.?(/|$)|//|\n")')
        [ "$path_invalid" = "false" ] ||
            die 2 "manifest: target \"$path\" の path は正規化された相対パスでなければなりません (先頭の /、. や .. のセグメント、// は使えません)"

        [ "$(manifest_query --arg n "$runtime" '.runtimes | has($n)')" = "true" ] ||
            die 2 "manifest: target \"$path\" の runtime \"$runtime\" は runtimes に宣言されていません"
        adapter_path "$owner" >/dev/null ||
            die 2 "manifest: target \"$path\" の owner \"$owner\" に対応する adapter がありません"
    done
}
