#!/usr/bin/env bash
# Runtime Adapter の実行・staging・置換・drift 比較。harness.sh から source される。
# 依存: report.bash、manifest.bash(HARNESS_TARGET_*)、export 済みの HARNESS_ROOT / HARNESS_SOURCE_DIR / HARNESS_MANIFEST
#
# Atomic Sync(spec「sync の手順」): 全 target を staging に render し、全体検証に通ってから
# live と同じディレクトリに一時ファイルを書いて mv で置換する。
# 同一ファイルシステム内の rename なので Target は「旧内容」か「新内容」のどちらかしか観測されない。

# target_selected RUNTIME RUNTIME_FILTER: filter が空か runtime が一致すれば 0
target_selected() {
    [ -z "$2" ] || [ "$1" = "$2" ]
}

# render_all STAGING_DIR [RUNTIME_FILTER]: 対象 target を STAGING_DIR/<index> に render する。
# 失敗した target は report_fail し、1 件でもあれば最後に return 1(live には触れない)。
# 戻り値 0 のとき「対象 target 全件の staging が通常ファイルとして存在する」(spec 手順 4 の全体検証はここで満たす)
render_all() {
    local staging=$1 filter=${2:-} i path owner adapter status failed=0
    for ((i = 0; i < ${#HARNESS_TARGET_PATHS[@]}; i++)); do
        target_selected "${HARNESS_TARGET_RUNTIMES[$i]}" "$filter" || continue
        path=${HARNESS_TARGET_PATHS[$i]}
        owner=${HARNESS_TARGET_OWNERS[$i]}
        if ! adapter=$(adapter_path "$owner"); then
            report_fail "target $path: adapter $owner が見つかりません"
            failed=1
            continue
        fi
        status=0
        "$adapter" render "$staging/$i" "$(manifest_target "$i")" </dev/null || status=$?
        if [ "$status" -ne 0 ]; then
            # 途中まで書かれた staging は消す: 「staging/<i> がある ⇔ render 成功」を成立させ、
            # compare_all が FAIL 済みの target に DRIFT / OK を重ねないようにする
            rm -f "$staging/$i"
            report_fail "target $path: adapter $owner が exit $status"
            failed=1
        elif [ ! -f "$staging/$i" ]; then
            report_fail "target $path: adapter $owner が出力を生成しませんでした"
            failed=1
        fi
    done
    return "$failed"
}

# file_mode PATH: パーミッションを 3 桁 8 進数で出力する。
# GNU(stat -c)を先に試す: macOS の stat は -c を「illegal option」として stdout に何も出さず exit 1 するが、
# 逆順にすると GNU の stat -f はファイルシステム情報を stdout に出してから失敗し、|| で 644 が連結された
# 複数行が mode になって chmod が拒否する(CI ubuntu で実際に起きた)
file_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

# live_not_regular LIVE: live が存在して通常ファイルでない(symlink / directory / fifo 等)なら 0。
# -f は symlink を辿るので -L を先に見る
live_not_regular() {
    [ -L "$1" ] || { [ -e "$1" ] && [ ! -f "$1" ]; }
}

# blocked_ancestor PATH: HARNESS_ROOT/PATH の祖先ディレクトリのうち、存在するのにディレクトリでない
# 最初の要素を(PATH からの相対で)出力して 0。無ければ 1。
# 置換フェーズの mkdir -p が失敗する条件のうち、manifest と live の形だけで事前に決まるもの
blocked_ancestor() {
    local rel=$1 ancestor
    while [ "${rel%/*}" != "$rel" ]; do
        rel=${rel%/*}
        ancestor="$HARNESS_ROOT/$rel"
        if [ -e "$ancestor" ] && [ ! -d "$ancestor" ]; then
            printf '%s\n' "$rel"
            return 0
        fi
    done
    return 1
}

# live_blocked PATH OWNER: 置換すると壊れる(または置換できない)ことが事前に分かる target を
# FAIL で報告して 0。symlink / 通常ファイル以外の live、および祖先が通常ファイルの場合。
# replace_all の事前パスと compare_all で同じ判定を使う
live_blocked() {
    local path=$1 owner=$2 live="$HARNESS_ROOT/$1" ancestor
    if [ -L "$live" ]; then
        report_fail "target $path: symlink の Target は #309 では未対応です (owner: $owner)"
    elif live_not_regular "$live"; then
        report_fail "target $path: 通常ファイルではありません (owner: $owner)"
    elif ancestor=$(blocked_ancestor "$path"); then
        report_fail "target $path: 親ディレクトリを作れません ($ancestor が通常ファイルです) (owner: $owner)"
    else
        return 1
    fi
}

# replace_all STAGING_DIR: staging を live に反映する。内容が同じなら mv せず mtime も変えない。
# 事前パスで live_blocked な target(live が「存在するが通常ファイルでない」、または祖先が通常ファイル)が
# 1 つでもあれば、何も置換せず return 1
# (symlink は #309 では未対応。cmp は symlink を辿るため内容一致時だけ黙ってトポロジが壊れる。
# directory だと mv -f が一時ファイルをその中へ移して「updated」と偽報告する。
# 祖先が通常ファイルだと mkdir -p が失敗し、先に処理した target だけ新版になる)。
# 事前に判定できない置換失敗(権限・disk full 等の環境要因)は report_fail して他の target は続け、最後に
# "harness sync: N updated, M unchanged" を出力し、失敗が 1 件でもあれば return 1(ADR 0002)。
# モードは既存 live に合わせ、新規は 0644
replace_all() {
    local staging=$1 i path owner live blocked=0

    for ((i = 0; i < ${#HARNESS_TARGET_PATHS[@]}; i++)); do
        if live_blocked "${HARNESS_TARGET_PATHS[$i]}" "${HARNESS_TARGET_OWNERS[$i]}"; then
            blocked=1
        fi
    done
    [ "$blocked" -eq 0 ] || return 1

    local mode tmp updated=0 unchanged=0 failed=0
    for ((i = 0; i < ${#HARNESS_TARGET_PATHS[@]}; i++)); do
        path=${HARNESS_TARGET_PATHS[$i]}
        owner=${HARNESS_TARGET_OWNERS[$i]}
        live="$HARNESS_ROOT/$path"
        if [ -f "$live" ] && cmp -s "$staging/$i" "$live"; then
            printf 'unchanged %s\n' "$path"
            unchanged=$((unchanged + 1))
            continue
        fi
        if [ -f "$live" ]; then
            mode=$(file_mode "$live")
        else
            mode=0644
        fi
        # 一時ファイルは live と同じディレクトリに mktemp で作る(別ファイルシステムの mv は
        # copy+unlink で原子的でない。$$ ではなく mktemp なので同時実行でも名前が衝突しない)。
        # 親ディレクトリが作れない(途中の要素が通常ファイル等)場合もこの target だけ FAIL にする
        if ! mkdir -p "$(dirname "$live")" ||
            ! tmp=$(mktemp "$(dirname "$live")/.$(basename "$live").harness-tmp.XXXXXX"); then
            report_fail "target $path: 置換に失敗しました (owner: $owner)"
            failed=1
            continue
        fi
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
# render に失敗した target(staging が無い。render_all が部分出力も消す)は FAIL 済みなので飛ばす
compare_all() {
    local staging=$1 filter=${2:-} i path owner live
    for ((i = 0; i < ${#HARNESS_TARGET_PATHS[@]}; i++)); do
        target_selected "${HARNESS_TARGET_RUNTIMES[$i]}" "$filter" || continue
        [ -f "$staging/$i" ] || continue
        path=${HARNESS_TARGET_PATHS[$i]}
        owner=${HARNESS_TARGET_OWNERS[$i]}
        live="$HARNESS_ROOT/$path"
        if live_blocked "$path" "$owner"; then
            :
        elif [ ! -f "$live" ]; then
            report_drift "target $path: 存在しません (owner: $owner)"
        elif ! cmp -s "$staging/$i" "$live"; then
            report_drift "target $path: 内容が Source と異なります (owner: $owner)"
        else
            report_ok "target $path"
        fi
    done
}
