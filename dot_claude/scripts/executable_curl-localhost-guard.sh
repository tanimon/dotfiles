#!/usr/bin/env bash
# PreToolUse hook: let `curl` to loopback through without an approval prompt.
#
# `Bash(curl:*)` sits in `permissions.ask` so that a one-off download or a
# `curl … | sh` goes past a human. That gate is right for the network but wrong
# for the everyday `curl http://localhost:3000/api` against a dev server started
# in this very session — a prompt per request, for a request that never leaves
# the machine.
#
# `permissions` cannot express the distinction: rules are prefix matches, and
# the URL sits after however many flags the caller wrote (`curl -sS -H … URL`),
# so no `Bash(curl http://localhost:*)` entry can reach it. This hook reads the
# whole command string instead, exactly as git-push-guard.sh does for `git push`.
#
# Decision contract (docs: PreToolUse hookSpecificOutput):
#   allow       — every segment is provably inert or a loopback-only curl
#   (no output) — anything else; falls through to the `Bash(curl:*)` ask rule
#
# This hook ONLY ever widens, so its failure direction is the safe one: an
# unreadable command, a crash, a missing jq, an unwired script — all produce no
# output, and the ask rule then prompts exactly as it does today. That is the
# mirror image of git-push-guard, where silence is the frictionless default and
# the fail-closed path has to be built by hand. Nothing here needs an error log
# for that reason: there is no fail-open state to diagnose after the fact.
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

emit_allow() {
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"curl-localhost-guard: 宛先がすべてループバック(localhost / 127.0.0.0/8 / [::1])なので承認不要で実行します。"}}'
}

# Every bail-out below is a plain `exit 0` with no output: the ask rule decides.
STDIN_JSON=$(cat) || exit 0
command -v jq >/dev/null 2>&1 || exit 0
COMMAND=$(printf '%s' "$STDIN_JSON" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[[ -z "$COMMAND" ]] && exit 0

# Cheap bail-out before any parsing.
case "$COMMAND" in
*curl*) ;;
*) exit 0 ;;
esac

# curl reads a curlrc before it looks at any argument, and one `proxy = …` line
# in it sends a loopback URL to an arbitrary host — the same capability
# `--resolve` / `--connect-to` / `-x` are refused for below, with no spelling in
# the command for this hook to see. curl takes the first of these that exists.
# Nothing in this repository manages a curlrc, so bailing costs nothing in
# practice. (`http_proxy` in the environment is the same class and is not
# checkable at all: the hook's environment is not the Bash tool's.)
# An `if` rather than `[[ … ]] && exit 0` for legibility only. (`set -e` does not
# end the loop on a false test: the test is part of an `&&` list and so is
# exempt — verified on bash 3.2. A bare `false` in the body would abort.)
for rc in "${CURL_HOME:-}/.curlrc" "${XDG_CONFIG_HOME:-}/curlrc" "${HOME:-}/.curlrc"; do
    case "$rc" in /.curlrc | /curlrc) continue ;; esac
    if [[ -e "$rc" || -L "$rc" ]]; then
        exit 0
    fi
done

# --- reader ------------------------------------------------------------------

# 引用符を解釈して token に分ける reader は他のフックと共有している。読めなかった
# 理由は flag で返るだけで、扱いはここ(下の segment walk の直前)で決める。
# 読み込みに失敗したら判定なしで抜ける(ask ルールが決める)。
# `source` は存在しないファイルで `|| exit 0` に届く前に bash 自身が終了する
# (bash 3.2 で実測、終了コード 1)ので、先に読めることを確かめる。
reader_library="$(dirname "${BASH_SOURCE[0]}")/lib/shell-reader.bash"
[[ -r "$reader_library" ]] || exit 0
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/shell-reader.bash
source "$reader_library" || exit 0

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
        # rather than on `<` anywhere in the token: the tokenizer has already
        # split every real redirection into its own token, so a `<` left inside
        # a token can only have come from quotes, and refusing those made
        # `curl --data='<ping/>' http://localhost/` prompt for nothing.
        if [[ "$token" =~ ^[0-9]*\< ]]; then
            return 1
        fi

        # Output redirections are not curl's arguments. The tokenizer kept any
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
# 変数・置換は宛先を運べる(代入の前置は `http_proxy` で URL を外へ振り替えられる)、
# 番兵は偽の segment 境界を作れる、{ } * は単語数を変える、長すぎる入力は安く読めない。
# どれも読み切れないコマンドとして ask に任せる。詳細は lib/shell-reader.bash。
# 引用符の閉じ忘れはここでは見ない(元の走査も見ておらず、閉じていない token は
# URL として読めずにプロンプトへ落ちる)。
if [[ $SHELL_READER_TOO_LONG -eq 1 || $SHELL_READER_EXPANSION -eq 1 ||
    $SHELL_READER_SEP_IN_INPUT -eq 1 || $SHELL_READER_WORD_MULTIPLIER -eq 1 ]]; then
    exit 0
fi
[[ ${#SHELL_READER_TOKENS[@]} -eq 0 ]] && exit 0

shell_reader_each_segment classify_segment || exit 0
[[ $SAW_CURL -eq 1 ]] || exit 0

emit_allow
exit 0
