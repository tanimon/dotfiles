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
#                 (読み切れない綴り・curlrc・未知の flag やパイプ先・ループバック以外の宛先)
#   (no output) — curl を実行しうる token が無いか、ループバック宛だけの curl。classifier が判定する
#   このフックは allow を返さない。
#
# フックが死ぬ(未配置・クラッシュ)と curl は classifier の判定だけになる(git-push-guard と同じ向き)。
# 8192 byte を超えるコマンドは安く読めないので無出力にする(ADR 0009)。
#
# Recognition is therefore an allowlist at every level — flags, pipe targets,
# URL schemes, hosts. An unrecognized token is not "probably fine", it is a
# prompt.
#
# Residual, accepted: a listener on a loopback port can relay to anywhere, so
# "loopback" bounds the destination address, not the ultimate destination. The
# same bound is the reason `-o` / `--dump-header` / `>` are not restricted here:
# the *content* written comes from that listener and the *path* is arbitrary, so
# this hook bounds the destination address and not the side effects. Both grant
# no new reach — `Bash(python3:*)` is already in `allow` and can open the same
# socket and write the same files — and the relay channel is documented for the
# nono sandbox as well (`open_port: [0]`, dot_config/nono/CLAUDE.md).
#
# `?` and `[` outside quotes are pathname expansion exactly as `*` is, and the
# tempting reading — "an expansion still starts with the literal text around it,
# so it is still loopback" — is FALSE: a bracket expression or a `?` matches
# several files at once, so one token becomes several WORDS, and every extra
# word lands in curl's argument list as a second, unchecked URL. `curl -H
# [ab]evil.example http://localhost:3000/` with `aevil.example` and
# `bevil.example` planted in the working directory passes `-H aevil.example` and
# then fetches `http://bevil.example/` (scheme-less, so curl assumes http).
# They are therefore refused on the same footing as `*`, with one carve-out that
# keeps `…/api?a=1` and the `[::1]` authority usable: a token is still read when
# it is itself a loopback URL whose authority carries no metacharacter of its
# own (`glob_token_is_loopback_safe` below). There the literal text really does
# pin the destination — every word an expansion can produce still begins with
# `http://localhost:3000/`. Unlike the two residuals above, which bound side
# effects beyond the destination check, a glob breaks the destination check
# itself, so it gets no residual.
# classify_segment とその呼び先は shell_reader_each_segment が名前で間接的に呼ぶ。
# shellcheck disable=SC2329
set -euo pipefail

# 理由の文言に変数を入れない固定文(jq が無くても出せる)。
emit_ask() {
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"curl-localhost-guard: 宛先がループバック(localhost / 127.0.0.0/8 / [::1])だけだと確認できないため、承認が必要です。"}}'
}

# stdin・jq・command の取り出しに失敗したら curl の有無を確かめられない。
# 生の入力に curl があれば ask、無ければ無出力。
STDIN_JSON=$(cat) || {
    emit_ask
    exit 0
}
if ! command -v jq >/dev/null 2>&1; then
    case "$STDIN_JSON" in *curl*) emit_ask ;; esac
    exit 0
fi
COMMAND=$(printf '%s' "$STDIN_JSON" | jq -r '.tool_input.command // empty' 2>/dev/null) || {
    case "$STDIN_JSON" in *curl*) emit_ask ;; esac
    exit 0
}
[[ -z "$COMMAND" ]] && exit 0

# Cheap bail-out before any parsing.
case "$COMMAND" in
*curl*) ;;
*) exit 0 ;;
esac

# curl は引数を見る前に curlrc を読み、`proxy = …` の 1 行でループバック URL が任意のホストへ
# 振り替わる。`--resolve` / `--connect-to` / `-x` を綴りで落としても、コマンド文字列に痕跡を
# 残さないファイル 1 つで無効になるため、存在自体を「読み切れない」として扱う。
# ここでは記録だけして、判定は curl を実行しうる token があるか確かめた後(末尾)で行う。
# curl は次のうち最初に存在するものを読む。このリポジトリは curlrc を管理していない。
# (環境変数の `http_proxy` も同じクラスだが、フックの環境は Bash ツールの環境と別なので検査不能。)
CURLRC_PRESENT=0
for rc in "${CURL_HOME:-}/.curlrc" "${XDG_CONFIG_HOME:-}/curlrc" "${HOME:-}/.curlrc"; do
    case "$rc" in /.curlrc | /curlrc) continue ;; esac
    if [[ -e "$rc" || -L "$rc" ]]; then
        CURLRC_PRESENT=1
        break
    fi
done

# --- reader ------------------------------------------------------------------

# 引用符を解釈して token に分ける reader は他のフックと共有している。読めなかった
# 理由は flag で返るだけで、扱いはここ(下の segment walk の直前)で決める。
# 読み込みに失敗したら curl の有無を確かめられない(この時点で COMMAND は `*curl*` に一致)ので ask。
# `source` は存在しないファイルで `||` に届く前に bash 自身が終了する
# (bash 3.2 で実測、終了コード 1)ので、先に読めることを確かめる。
reader_library="$(dirname "${BASH_SOURCE[0]}")/lib/shell-reader.bash"
[[ -r "$reader_library" ]] || {
    emit_ask
    exit 0
}
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/shell-reader.bash
source "$reader_library" || {
    emit_ask
    exit 0
}

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

# Every token of a bundled short flag must be a known no-value short flag; a
# bundle whose LAST letter takes a value (`-sSo out.json`) is also accepted.
# Returns 0 = no value consumed, 1 = value token consumed, 2 = unrecognized.
classify_short_bundle() {
    local bundle=${1#-} index letter last
    [[ -z "$bundle" ]] && return 2
    last=${bundle: -1}
    for ((index = 0; index < ${#bundle} - 1; index++)); do
        letter=${bundle:index:1}
        [[ "$SAFE_SHORT_FLAGS" == *"$letter"* ]] || return 2
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
        if [[ "$token" =~ ^[0-9]*\>\>?$ ]]; then
            index=$((index + 2))
            continue
        elif [[ "$token" =~ ^[0-9]*\>\>?. ]]; then
            index=$((index + 1))
            continue
        fi

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
            case "${token#*=}" in @* | -) return 1 ;; esac
            # `--data-urlencode` takes the file form as `name@file`, so for it
            # the `@` is not only a prefix.
            if [[ "${token%%=*}" == --data-urlencode ]]; then
                case "${token#*=}" in *@*) return 1 ;; esac
            fi
            index=$((index + 1))
            ;;
        --*)
            if in_list "$token" "$SAFE_LONG_FLAGS"; then
                index=$((index + 1))
            elif in_list "$token" "$SAFE_VALUE_LONG_FLAGS"; then
                value=${tokens[$((index + 1))]:-}
                [[ -z "$value" ]] && return 1
                case "$value" in @* | -) return 1 ;; esac
                if [[ "$token" == --data-urlencode ]]; then
                    case "$value" in *@*) return 1 ;; esac
                fi
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
                case "$value" in @* | -) return 1 ;; esac
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

    # No URL means this is not the request shape this hook is widening for
    # (`curl --version`, a bare `curl`), so it keeps its prompt.
    [[ $urls -gt 0 ]]
}

# Commands allowed to sit beside curl in a pipeline or a compound command.
# Read-only text filters only: the point is to keep `curl … | sh` out while
# `curl … | jq .` stays frictionless.
INERT_COMMANDS='jq head tail cat wc grep egrep fgrep sort uniq tr cut column echo printf true rev cd sleep'

# --- segment walk ------------------------------------------------------------

SAW_CURL=0

# 1 segment を分類する。コマンド全体をプロンプトに残すべきときは非 0。
# reader が segment ごとに呼ぶ(引数が segment の token)。
classify_segment() {
    local segment=("$@") binary=$1 index

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
        SAW_CURL=1
        return 0
    fi

    in_list "$binary" "$INERT_COMMANDS" || return 1
    return 0
}

shell_reader_read "$COMMAND"
# 長すぎる入力は安く読めない。curl を実行するかも確かめられないので、何も返さず classifier に任せる(ADR 0009)。
[[ $SHELL_READER_TOO_LONG -eq 1 ]] && exit 0
[[ ${#SHELL_READER_TOKENS[@]} -eq 0 ]] && exit 0

# curl を実行しうる token があるか。引用符の中の文字列は reader が 1 token にまとめるので、
# `echo "curl …"` の `curl …` はここで一致しない。バッククォートで始まる token は実行されるので外して見る。
CURL_PRESENT=0
for token in "${SHELL_READER_TOKENS[@]}"; do
    token=${token#\`}
    if [[ "${token##*/}" == "curl" ]]; then
        CURL_PRESENT=1
        break
    fi
done
[[ $CURL_PRESENT -eq 1 ]] || exit 0

# 変数・置換は宛先を運べる(代入の前置は `http_proxy` で URL を外へ振り替えられる)、
# 番兵は偽の segment 境界を作れる、{ } * は単語数を変える。読み切れないコマンドとして ask。
# 詳細は lib/shell-reader.bash。引用符の閉じ忘れはここでは見ない(閉じていない token は
# URL として読めずに ask へ落ちる)。
if [[ $CURLRC_PRESENT -eq 1 || $SHELL_READER_EXPANSION -eq 1 ||
    $SHELL_READER_SEP_IN_INPUT -eq 1 || $SHELL_READER_WORD_MULTIPLIER -eq 1 ]]; then
    emit_ask
    exit 0
fi

# すべての segment がループバック宛の curl か INERT_COMMANDS なら無出力(classifier が判定する)。
# SAW_CURL が 0 になるのは curl を実行しうる token がコマンド位置に無いとき(`xargs curl` など)。
if ! shell_reader_each_segment classify_segment || [[ $SAW_CURL -ne 1 ]]; then
    emit_ask
fi
exit 0
