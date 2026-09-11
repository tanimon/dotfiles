#!/usr/bin/env bash
# Runtime Adapter の実行・staging・全体検証・置換・drift 比較。harness.sh から source される。
# 依存: report.bash、manifest.bash、export 済みの HARNESS_ROOT / HARNESS_SOURCE_DIR / HARNESS_MANIFEST
#
# Atomic Sync(spec「sync の手順」): 全 target を staging に render し、全体検証に通ってから
# live と同じディレクトリに一時ファイルを書いて mv で置換する。
# 同一ファイルシステム内の rename なので Target は「旧内容」か「新内容」のどちらかしか観測されない。

# target_selected TARGET_JSON RUNTIME_FILTER: filter が空か runtime が一致すれば 0
target_selected() {
    local target=$1 filter=$2
    [ -z "$filter" ] || [ "$(jq -r .runtime <<<"$target")" = "$filter" ]
}

# render_all STAGING_DIR [RUNTIME_FILTER]: 対象 target を STAGING_DIR/<index> に render する。
# 失敗した target は report_fail し、1 件でもあれば最後に return 1(live には触れない)
render_all() {
    local staging=$1 filter=${2:-} count i target path owner adapter status failed=0
    count=$(manifest_target_count)
    for ((i = 0; i < count; i++)); do
        target=$(manifest_target "$i")
        target_selected "$target" "$filter" || continue
        path=$(jq -r .path <<<"$target")
        owner=$(jq -r .owner <<<"$target")
        adapter=$(adapter_path "$owner")
        status=0
        "$adapter" render "$staging/$i" "$target" || status=$?
        if [ "$status" -ne 0 ]; then
            report_fail "target $path: adapter $owner が exit $status"
            failed=1
        elif [ ! -f "$staging/$i" ]; then
            report_fail "target $path: adapter $owner が出力を生成しませんでした"
            failed=1
        fi
    done
    return "$failed"
}

# validate_staging STAGING_DIR [RUNTIME_FILTER]: 対象 target 全件の staging が通常ファイルなら 0
validate_staging() {
    local staging=$1 filter=${2:-} count i target
    count=$(manifest_target_count)
    for ((i = 0; i < count; i++)); do
        target=$(manifest_target "$i")
        target_selected "$target" "$filter" || continue
        [ -f "$staging/$i" ] || return 1
    done
    return 0
}

# replace_all STAGING_DIR: staging を live に反映する。内容が同じなら mv せず mtime も変えない。
# 最後に "harness sync: N updated, M unchanged" を出力する
replace_all() {
    local staging=$1 count i path live tmp updated=0 unchanged=0
    count=$(manifest_target_count)
    for ((i = 0; i < count; i++)); do
        path=$(manifest_target "$i" | jq -r .path)
        live="$HARNESS_ROOT/$path"
        if [ -f "$live" ] && cmp -s "$staging/$i" "$live"; then
            printf 'unchanged %s\n' "$path"
            unchanged=$((unchanged + 1))
            continue
        fi
        mkdir -p "$(dirname "$live")"
        # 一時ファイルは live と同じディレクトリに置く(別ファイルシステムの mv は copy+unlink で原子的でない)。
        # モードは staging(= adapter 出力)に従う
        tmp="$(dirname "$live")/.$(basename "$live").harness-tmp.$$"
        cp "$staging/$i" "$tmp"
        mv -f "$tmp" "$live"
        printf 'updated   %s\n' "$path"
        updated=$((updated + 1))
    done
    printf 'harness sync: %d updated, %d unchanged\n' "$updated" "$unchanged"
}
