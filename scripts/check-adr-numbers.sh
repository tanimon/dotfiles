#!/usr/bin/env bash
# docs/adr/ に同じ番号(ファイル名の先頭 4 桁)の ADR が 2 つ以上あれば落とす。
#
# 採番は「docs/adr/ の最大番号 +1」(docs/adr/README.md)なので、並行する PR はそれぞれ
# 単独では通る同じ番号を取りうる。この検査が落とすのは、後からマージする PR を main に
# 追従させたときと、両方がマージされた後の main の CI になる。
#
# 使い方: check-adr-numbers.sh [dir]
#   dir を省くと docs/adr を検査する。
set -euo pipefail

dir=${1:-docs/adr}

if [ ! -d "$dir" ]; then
    echo "ERROR: $dir is not a directory" >&2
    exit 1
fi

# 番号ごとの「番号<TAB>ファイル名」。配列に取らないのは、bash 3.2 の set -u が空配列の展開で落ちるため。
shopt -s nullglob
listing=""
for file in "$dir"/[0-9][0-9][0-9][0-9]-*.md; do
    name=${file##*/}
    listing+="${name:0:4}"$'\t'"${name}"$'\n'
done
shopt -u nullglob

count=$(printf '%s' "$listing" | grep -c . || true)

# 2 つ以上のファイルを持つ番号だけを出す。
duplicates=$(
    printf '%s' "$listing" | sort | awk -F'\t' '
        { names[$1] = names[$1] " " $2; count[$1]++ }
        END { for (number in count) if (count[number] > 1) print number ":" names[number] }
    ' | sort
)

if [ -n "$duplicates" ]; then
    echo "FAIL: ADR numbers are duplicated in $dir (renumber the later-merged ADR to the next free number):"
    printf '%s\n' "$duplicates" | sed 's/^/  /'
    exit 1
fi

echo "PASS: ${count} ADRs in $dir have unique numbers"
