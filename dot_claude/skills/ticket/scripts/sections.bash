#!/usr/bin/env bash
# issue 本文の節を読む関数。audit.sh と create-issue.sh が source する。
# 見出しは `#` で始まり空白が続く行で、小文字にした行を pattern(awk の正規表現)と比べる。
# 呼び出し側は LC_ALL=C で動かす(tolower と日本語の見出しをバイト単位で扱うため)。

# section_refs <pattern>: stdin の本文のうち、見出しが pattern に一致する節の中の #N の N を 1 行 1 番号で出す。
section_refs() {
    awk -v pattern="$1" '
        /^#+[ \t]/ { in_section = (tolower($0) ~ pattern); next }
        in_section {
            line = $0
            while (match(line, /#[0-9]+/)) {
                print substr(line, RSTART + 1, RLENGTH - 1)
                line = substr(line, RSTART + RLENGTH)
            }
        }'
}

# unchecked_items <pattern>: 見出しが pattern に一致する節の中の未チェック項目の文を 1 行 1 項目で出す。
unchecked_items() {
    awk -v pattern="$1" '
        /^#+[ \t]/ { in_section = (tolower($0) ~ pattern); next }
        in_section && /^[ \t]*[-*] \[ \] / { sub(/^[ \t]*[-*] \[ \] /, ""); print }'
}
