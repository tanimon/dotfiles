#!/usr/bin/env bash
# issue 本文の節を読む関数。audit.sh と create-issue.sh が source する。
# 見出しは `#` で始まり空白が続く行で、小文字にした行を pattern(awk の正規表現)と比べる。
# 呼び出し側は LC_ALL=C で動かす(tolower と日本語の見出しをバイト単位で扱うため)。

# section_refs <pattern>: stdin の本文のうち、見出しが pattern に一致する節で、行頭に置いた #N の N を 1 行 1 番号で出す。
# 読むのは行頭(箇条書きの `-` / `*` / `+` / `1.` の後ろも行頭とみなす)から `,` / `、` / 空白で続く #N だけ。
# 「なし。#402 がこの issue に依存する。」のような文中の #N は関係ではなく説明なので読まない。
# 見出しと同じ行に書いた参照(`## Blocked by #401`)は、見出し語より後ろを行頭とみなして読む。
# 別リポジトリの参照(`owner/repo#5`)は行頭が # ではないので読まない。
section_refs() {
    awk -v pattern="$1" '
        function leading_refs(text) {
            sub(/^[ \t]*/, "", text)
            if (match(text, /^([-*+]|[0-9]+[.)])[ \t]+/)) text = substr(text, RLENGTH + 1)
            while (match(text, /^#[0-9]+/)) {
                print substr(text, 2, RLENGTH - 1)
                text = substr(text, RLENGTH + 1)
                if (!match(text, /^(,|、|[ \t])+/)) break
                text = substr(text, RLENGTH + 1)
            }
        }
        /^#+[ \t]/ {
            in_section = match(tolower($0), pattern)
            if (in_section) leading_refs(substr($0, RSTART + RLENGTH))
            next
        }
        in_section { leading_refs($0) }'
}

# unchecked_items <pattern>: 見出しが pattern に一致する節の中の未チェック項目の文を 1 行 1 項目で出す。
unchecked_items() {
    awk -v pattern="$1" '
        /^#+[ \t]/ { in_section = (tolower($0) ~ pattern); next }
        in_section && /^[ \t]*[-*] \[ \] / { sub(/^[ \t]*[-*] \[ \] /, ""); print }'
}
