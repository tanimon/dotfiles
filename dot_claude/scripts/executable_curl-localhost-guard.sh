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
# "loopback" bounds the destination address, not the ultimate destination. This
# grants no new reach — `Bash(python3:*)` is already in `allow` and can open the
# same socket — and the same relay channel is documented for the nono sandbox
# (`open_port: [0]`, dot_config/nono/CLAUDE.md).
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

# A variable or a command substitution can carry the real target, and an
# assignment prefix can set `http_proxy` and redirect an otherwise-loopback URL
# off the machine. Neither is readable here, so neither is allowed.
case "$COMMAND" in
*'$'* | *'`'*) exit 0 ;;
esac

# --- tokenizer ---------------------------------------------------------------

# `read -ra` splits on whitespace only, which is wrong here in both directions:
# `-H "Accept: application/json"` becomes two tokens (and the second is then read
# as a URL), while `-d '{"a":"x|y"}'` would have its `|` treated as a pipe. The
# argument that matters — the URL — sits among quoted neighbours, so the scan
# needs real quote handling.
#
# Substitutions were already refused above, so a quote-aware walk is a faithful
# reading of the command here: nothing inside the quotes can still expand.
#
# Emits into the TOKENS array. Command separators (`;` `&` `|` newline, and the
# subshell parentheses) become the SEP sentinel; redirections become one
# operator token with any file-descriptor digit attached, so `2>&1` cannot leave
# a stray `1` behind for the argument walk to read as a URL.
SEP=$'\x01'
TOKENS=()

tokenize() {
    local s=$1
    local length=${#s}
    local index character quote='' current='' started=0 operator

    flush() {
        if [[ $started -eq 1 ]]; then
            TOKENS+=("$current")
            current=''
            started=0
        fi
    }

    for ((index = 0; index < length; index++)); do
        character=${s:index:1}

        if [[ -n "$quote" ]]; then
            if [[ "$character" == "$quote" ]]; then
                quote=''
            else
                current+=$character
                started=1
            fi
            continue
        fi

        case "$character" in
        "'" | '"')
            # An empty quoted string is still a token (`-d ''`).
            quote=$character
            started=1
            ;;
        \\)
            index=$((index + 1))
            # A backslash-newline is a line continuation, not an escaped
            # character: it joins the two halves and contributes nothing.
            if [[ "${s:index:1}" != $'\n' ]]; then
                current+=${s:index:1}
                started=1
            fi
            ;;
        ' ' | $'\t')
            flush
            ;;
        ';' | '|' | $'\n' | '(' | ')')
            flush
            TOKENS+=("$SEP")
            ;;
        '&')
            # `&>file` is a redirection, not a separator.
            if [[ "${s:index+1:1}" == '>' ]]; then
                flush
                operator='>'
                index=$((index + 1))
                while [[ $((index + 1)) -lt $length && "${s:index+1:1}" =~ [\>\&0-9-] ]]; do
                    index=$((index + 1))
                    operator+=${s:index:1}
                done
                TOKENS+=("$operator")
            else
                flush
                TOKENS+=("$SEP")
            fi
            ;;
        '>' | '<')
            # A bare file-descriptor number in front of the operator belongs to
            # it rather than being an argument of its own.
            if [[ "$current" =~ ^[0-9]+$ ]]; then
                operator=$current
                current=''
                started=0
            else
                flush
                operator=''
            fi
            operator+=$character
            while [[ $((index + 1)) -lt $length && "${s:index+1:1}" =~ [\>\&0-9-] ]]; do
                index=$((index + 1))
                operator+=${s:index:1}
            done
            TOKENS+=("$operator")
            ;;
        *)
            current+=$character
            started=1
            ;;
        esac
    done

    flush
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

# --- curl segment classification ---------------------------------------------

# Flags that take no value. Short flags may be bundled (`-fsSL`), so the bundle
# is checked letter by letter against SAFE_SHORT_FLAGS.
SAFE_LONG_FLAGS='--silent --show-error --verbose --include --head --location --location-trusted --insecure --fail --fail-with-body --fail-early --globoff --compressed --no-buffer --ipv4 --ipv6 --progress-bar --no-progress-meter --http1.1 --http2 --path-as-is --raw --tcp-nodelay --disable --no-keepalive --remote-name --create-dirs --get'
SAFE_SHORT_FLAGS='sSvIiLkfgN46O#'

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
        if [[ "$token" == *'<'* ]]; then
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
            index=$((index + 1))
            ;;
        --*)
            if in_list "$token" "$SAFE_LONG_FLAGS"; then
                index=$((index + 1))
            elif in_list "$token" "$SAFE_VALUE_LONG_FLAGS"; then
                value=${tokens[$((index + 1))]:-}
                [[ -z "$value" ]] && return 1
                case "$value" in @* | -) return 1 ;; esac
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
SEGMENT=()

# Classify the segment accumulated so far. Returns non-zero when the whole
# command must keep its prompt.
classify_segment() {
    local binary
    # bash 3.2 rejects expanding an empty array under `set -u`, so the count is
    # checked before the array is touched.
    [[ ${#SEGMENT[@]} -eq 0 ]] && return 0
    binary=${SEGMENT[0]}

    # No prefix skipping. `VAR=value curl …` can set http_proxy, and `env` /
    # `sudo` can do the same, so an unrecognized leading word is a prompt rather
    # than something to look past.
    # The bare name only. git-push-guard accepts `/usr/bin/git` because there a
    # wider match is the conservative direction; here it is the widening one,
    # and `./tools/curl` would otherwise let any script the agent just wrote
    # claim to be curl.
    if [[ "$binary" == "curl" ]]; then
        classify_curl "${SEGMENT[@]}" || return 1
        SAW_CURL=1
        return 0
    fi

    in_list "$binary" "$INERT_COMMANDS" || return 1
    return 0
}

tokenize "$COMMAND"
[[ ${#TOKENS[@]} -eq 0 ]] && exit 0

position=0
while [[ $position -lt ${#TOKENS[@]} ]]; do
    if [[ "${TOKENS[$position]}" == "$SEP" ]]; then
        classify_segment || exit 0
        SEGMENT=()
    else
        SEGMENT+=("${TOKENS[$position]}")
    fi
    position=$((position + 1))
done
classify_segment || exit 0

[[ $SAW_CURL -eq 1 ]] || exit 0

emit_allow
exit 0
