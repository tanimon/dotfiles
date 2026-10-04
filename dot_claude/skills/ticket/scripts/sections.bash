#!/usr/bin/env bash
# issue 本文の節を読む関数。audit.sh と create-issue.sh が source する。
# 見出しは `#` で始まり空白が続く行で、小文字にした行を pattern(awk の正規表現)と比べる。
# 節は、同じかより上位(`#` が同数以下)の見出しで閉じる。下位の見出し(AC 節の中の `### 補足` など)では閉じない。
# コードブロック(``` か ~~~ で囲んだ範囲)の中の `# …` はシェルのコメントでありうるので見出しとみなさない。
# 呼び出し側は LC_ALL=C で動かす(tolower と日本語の見出しをバイト単位で扱うため)。

# 両関数が共有する awk の前置き。heading(line) は見出しなら `#` の数、そうでなければ 0 を返し、フェンスの開閉を追う。
# enter_or_leave(line, pattern) は見出し行で節の出入りを更新し、入ったときは見出しの一致位置を RSTART / RLENGTH に残す。
_SECTIONS_AWK_PRELUDE='
    function heading(line) {
        if (line ~ /^[ \t]*(```|~~~)/) { in_fence = !in_fence; return 0 }
        if (in_fence || line !~ /^#+[ \t]/) return 0
        match(line, /^#+/)
        return RLENGTH
    }
    function enter_or_leave(line, pattern, level) {
        if (in_section && level > section_level) return 0
        in_section = match(tolower(line), pattern)
        if (in_section) section_level = level
        return in_section
    }'

# section_refs <pattern>: stdin の本文のうち、見出しが pattern に一致する節で、行頭に置いた #N の N を 1 行 1 番号で出す。
# 読むのは行頭(箇条書きの `-` / `*` / `+` / `1.` の後ろも行頭とみなす)から `,` / `、` / 空白で続く #N だけ。
# 「なし。#402 がこの issue に依存する。」のような文中の #N は関係ではなく説明なので読まない。
# 見出しと同じ行に書いた参照(`## Blocked by #401`)は、見出し語より後ろを行頭とみなして読む。
# 別リポジトリの参照(`owner/repo#5`)は行頭が # ではないので読まない。
section_refs() {
    awk -v pattern="$1" "$_SECTIONS_AWK_PRELUDE"'
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
        (level = heading($0)) > 0 {
            if (enter_or_leave($0, pattern, level)) leading_refs(substr($0, RSTART + RLENGTH))
            next
        }
        in_section && !in_fence { leading_refs($0) }'
}

# unchecked_items <pattern>: 見出しが pattern に一致する節の中の未チェック項目の文を 1 行 1 項目で出す。
# 箇条書きの記号は section_refs と揃える(`-` / `*` / `+` / `1.` / `1)`)。
unchecked_items() {
    awk -v pattern="$1" "$_SECTIONS_AWK_PRELUDE"'
        (level = heading($0)) > 0 { enter_or_leave($0, pattern, level); next }
        in_section && !in_fence && /^[ \t]*([-*+]|[0-9]+[.)]) \[ \] / { sub(/^[ \t]*([-*+]|[0-9]+[.)]) \[ \] /, ""); print }'
}
