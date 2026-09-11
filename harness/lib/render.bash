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

# file_mode PATH: パーミッションを 3 桁 8 進数で出力する(macOS の stat -f / GNU の stat -c 両対応)
file_mode() {
    stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

# replace_all STAGING_DIR: staging を live に反映する。内容が同じなら mv せず mtime も変えない。
# 事前パスで live が symlink の target が 1 つでもあれば、何も置換せず return 1(#309 では
# symlink Target 未対応。cmp は symlink を辿るため内容一致時だけ黙ってトポロジが壊れる)。
# 個々の置換失敗は report_fail して他の target は続け、最後に
# "harness sync: N updated, M unchanged" を出力し、失敗が 1 件でもあれば return 1。
# モードは既存 live に合わせ、新規は 0644
replace_all() {
    local staging=$1 count i target path owner live symlink_found=0

    count=$(manifest_target_count)
    for ((i = 0; i < count; i++)); do
        target=$(manifest_target "$i")
        path=$(jq -r .path <<<"$target")
        owner=$(jq -r .owner <<<"$target")
        live="$HARNESS_ROOT/$path"
        if [ -L "$live" ]; then
            report_fail "target $path: symlink の Target は #309 では未対応です (owner: $owner)"
            symlink_found=1
        fi
    done
    [ "$symlink_found" -eq 0 ] || return 1

    local mode tmp updated=0 unchanged=0 failed=0
    for ((i = 0; i < count; i++)); do
        target=$(manifest_target "$i")
        path=$(jq -r .path <<<"$target")
        owner=$(jq -r .owner <<<"$target")
        live="$HARNESS_ROOT/$path"
        if [ -f "$live" ] && cmp -s "$staging/$i" "$live"; then
            printf 'unchanged %s\n' "$path"
            unchanged=$((unchanged + 1))
            continue
        fi
        mkdir -p "$(dirname "$live")"
        if [ -f "$live" ]; then
            mode=$(file_mode "$live")
        else
            mode=0644
        fi
        # 一時ファイルは live と同じディレクトリに mktemp で作る(別ファイルシステムの mv は
        # copy+unlink で原子的でない。$$ ではなく mktemp なので同時実行でも名前が衝突しない)
        tmp=$(mktemp "$(dirname "$live")/.$(basename "$live").harness-tmp.XXXXXX") || {
            report_fail "target $path: 置換に失敗しました (owner: $owner)"
            failed=1
            continue
        }
        if ! cat "$staging/$i" >"$tmp" || ! chmod "$mode" "$tmp" || ! mv -f "$tmp" "$live"; then
            rm -f "$tmp"
            report_fail "target $path: 置換に失敗しました (owner: $owner)"
            failed=1
            continue
        fi
        printf 'updated   %s\n' "$path"
        updated=$((updated + 1))
    done
    printf 'harness sync: %d updated, %d unchanged\n' "$updated" "$unchanged"
    [ "$failed" -eq 0 ]
}

# compare_all STAGING_DIR [RUNTIME_FILTER]: staging と live を比較して drift を報告する。live は変更しない。
# render に失敗した target(staging が無い)は render_all が FAIL 済みなので飛ばす
compare_all() {
    local staging=$1 filter=${2:-} count i target path owner live
    count=$(manifest_target_count)
    for ((i = 0; i < count; i++)); do
        target=$(manifest_target "$i")
        target_selected "$target" "$filter" || continue
        [ -f "$staging/$i" ] || continue
        path=$(jq -r .path <<<"$target")
        owner=$(jq -r .owner <<<"$target")
        live="$HARNESS_ROOT/$path"
        if [ -L "$live" ]; then
            report_fail "target $path: symlink の Target は #309 では未対応です (owner: $owner)"
        elif [ ! -f "$live" ]; then
            report_drift "target $path: 存在しません (owner: $owner)"
        elif ! cmp -s "$staging/$i" "$live"; then
            report_drift "target $path: 内容が Source と異なります (owner: $owner)"
        else
            report_ok "target $path"
        fi
    done
}
