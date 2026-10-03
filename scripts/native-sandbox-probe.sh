#!/usr/bin/env bash
# ネイティブ Bash サンドボックスの内側で実行されるプローブ。起動するのは
# scripts/native-sandbox-smoke.sh が `claude -p` に実行させる Bash ツールで、cwd は
# driver が用意した一時ディレクトリ。引数は取らない。
#
# 入力は cwd の targets.tsv(1 行 1 項目、タブ区切り: 操作・期待・パス・省略可のラベル)。
# ラベルがあれば結果にはパスの代わりにラベルを書く(ファイル名を結果に出さないため)。
#   read-file / read-dir   ファイルを読む / ディレクトリを列挙する
#   read-absent            driver(サンドボックスの外)から見て存在しなかったパス。SKIP にする
#   read-empty             拒否側のディレクトリで、直下に allowRead 以外の通常ファイルが無かった。SKIP にする
#   read-unscoped          denyRead と重ならない allowRead。元から読めるので SKIP にする
#   write                  ファイルを作る。結果にかかわらず消す
# 期待は deny(失敗するはず)か allow(成功するはず)。存在の判定を driver に任せるのは、
# サンドボックスの内側では拒否されたパスの stat も失敗することがあり、「無い」と「読めない」を
# 区別できないため。
#
# 出力は cwd の results.tsv(タブ区切り: 項目・期待・終了コード・PASS/FAIL/SKIP)。
# 末尾に読み取りの拒否側・許可側それぞれの coverage 行(SKIP でない項目の数)を足し、
# 片側が 0 件なら FAIL にする。存在しないファイルの読み取り失敗を「拒否」と数えて
# 空振りで通るのを防ぐため。
#
# 判定は終了コードだけで行う。読み取った内容と stderr は /dev/null に捨て、
# 認証情報ファイルの内容をどこにも残さない。
set -euo pipefail

TARGETS=targets.tsv
RESULTS=results.tsv

[[ -f "$TARGETS" ]] || {
    printf 'native-sandbox-probe: %s not found in %s\n' "$TARGETS" "$PWD" >&2
    exit 1
}

: >"$RESULTS"
failed=0
deny_checked=0
allow_checked=0

# 結果には $HOME を ~ に置き換えたパスを書く。置換文字列に ~ を直書きすると
# チルダ展開で $HOME に戻るので、変数に入れて渡す
TILDE='~'
record() {
    local op=$1 target=$2 expect=$3 code=$4 verdict=$5
    printf '%s:%s\t%s\t%s\t%s\n' "$op" "${target/#"$HOME"/$TILDE}" "$expect" "$code" "$verdict" >>"$RESULTS"
    [[ "$verdict" != FAIL ]] || failed=1
}

verdict_for() {
    local expect=$1 code=$2
    if [[ "$expect" == deny && "$code" -ne 0 ]] || [[ "$expect" == allow && "$code" -eq 0 ]]; then
        printf 'PASS'
    else
        printf 'FAIL'
    fi
}

while IFS=$'\t' read -r op expect target label; do
    [[ -n "$op" ]] || continue
    code=0
    shown=${label:-$target}
    case "$op" in
    read-absent | read-empty | read-unscoped)
        record "$op" "$shown" "$expect" - SKIP
        continue
        ;;
    read-file) cat -- "$target" >/dev/null 2>&1 || code=$? ;;
    read-dir) ls -- "$target" >/dev/null 2>&1 || code=$? ;;
    write)
        (printf 'probe\n' >"$target") 2>/dev/null || code=$?
        rm -f -- "$target" 2>/dev/null || true
        ;;
    *)
        record "$op" "$shown" "$expect" - FAIL
        continue
        ;;
    esac
    record "$op" "$shown" "$expect" "$code" "$(verdict_for "$expect" "$code")"
    if [[ "$op" == read-* ]]; then
        if [[ "$expect" == deny ]]; then
            deny_checked=$((deny_checked + 1))
        else
            allow_checked=$((allow_checked + 1))
        fi
    fi
done <"$TARGETS"

for side in deny allow; do
    if [[ "$side" == deny ]]; then count=$deny_checked; else count=$allow_checked; fi
    if [[ "$count" -gt 0 ]]; then verdict=PASS; else verdict=FAIL; fi
    record coverage "$side" "$side" "$count" "$verdict"
done

exit "$failed"
