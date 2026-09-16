#!/usr/bin/env bash
# PreToolUse hook: gate the destructive spellings of `git push`.
#
# `permissions` offers prefix matching only, so `Bash(git push --force:*)` in
# deny fires for `git push --force origin main` but not for
# `git push origin main --force` — the write intent lives in a flag whose
# position is free. That is why `Bash(git push:*)` sat in `ask` and prompted on
# every routine push. This hook replaces that blanket gate: it reads the whole
# command string, so it can find the dangerous flag wherever it sits, and stays
# silent for the everyday push that prompted nobody's attention.
#
# Decision contract (docs: PreToolUse hookSpecificOutput):
#   deny  — force / delete / mirror / prune spellings, at any argument position
#   ask   — the push segment contains something this scan cannot read through
#   (no output) — plain push; falls through to defaultMode: auto's classifier
#
# Fail-closed: anything unreadable becomes `ask`, never silence. `ask` prompts
# even under defaultMode: auto, so an unparseable payload cannot slip past.
#
# Residuals this scan does not cover (documented in the tier-model spec):
#   - a force refspec reached through an alias or a shell function
#   - `gh api` calls that perform the equivalent server-side operation
set -euo pipefail

emit() {
    # $1 = permissionDecision, $2 = reason shown to Claude
    if command -v jq >/dev/null 2>&1; then
        jq -n --arg d "$1" --arg r "$2" \
            '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
    else
        # No jq means no safe way to escape a reason, so the text is a literal.
        printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"git-push-guard: jq unavailable, cannot classify this push"}}\n' "$1"
    fi
}

ASK_REASON='git-push-guard: この push は引数を読み切れないため確認が必要です(変数・コマンド置換・push 関連の -c 上書きなど)。素の push なら無確認で通ります。'

STDIN_JSON=$(cat) || {
    emit ask "$ASK_REASON"
    exit 0
}

command -v jq >/dev/null 2>&1 || {
    emit ask "$ASK_REASON"
    exit 0
}

COMMAND=$(printf '%s' "$STDIN_JSON" | jq -r '.tool_input.command // empty' 2>/dev/null) || {
    emit ask "$ASK_REASON"
    exit 0
}

# An empty command means either a non-Bash tool or a malformed payload. A
# payload that is not JSON at all fails the jq call above, so reaching here with
# an empty string is the benign case.
[[ -z "$COMMAND" ]] && exit 0

# Cheap bail-out before any parsing: nothing to guard without the verb.
case "$COMMAND" in
*push*) ;;
*) exit 0 ;;
esac

# Strip one layer of surrounding quotes so `"+main"` is seen as `+main`. The
# token is never re-executed, only matched, so this is a read of intent rather
# than a shell-accurate unquote.
unquote() {
    local s=$1
    s=${s#[\"\']}
    s=${s%[\"\']}
    printf '%s' "$s"
}

DANGER_TOKEN=""
NEEDS_ASK=0

# Split into command segments. `git commit -m wip && git push --force` must not
# hide behind the first verb, and over-splitting only ever produces segments
# that fail the `git push` test below, which is the safe direction.
# Normalize before splitting. Each of these was a fail-open hole: shell
# punctuation either glues onto a flag (`--force)` no longer matches `--force`)
# or splits a segment so that the half carrying the flag no longer starts with
# `git`. `(cd dir && git push … --force)` is a routine agent idiom, so this is
# not a theoretical concern.
NORMALIZED=$COMMAND
# A backslash-newline continuation is not a separator.
NORMALIZED=${NORMALIZED//\\$'\n'/ }
# Redirect operators contain & but do not separate commands (2>&1, &>f, >&2).
NORMALIZED=$(printf '%s' "$NORMALIZED" | sed -E 's/[<>]&|&>/ /g')
# Grouping punctuation is noise for this scan. Spacing it out rather than
# deleting it keeps `$` intact, so the substitution check below still fires.
NORMALIZED=$(printf '%s' "$NORMALIZED" | tr '(){}' '    ')

# tr pads a short replacement set with its last character, so all three map to
# a newline; the command's own newlines are already separators.
SEGMENTS=$(printf '%s' "$NORMALIZED" | tr ';&|' '\n')

while IFS= read -r segment || [[ -n "$segment" ]]; do
    [[ -z "$segment" ]] && continue

    # bash 3.2 errors on expanding an empty array under `set -u`, so the count
    # is checked before `${tokens[...]}` is touched anywhere below.
    tokens=()
    read -ra tokens <<<"$segment" || true
    [[ ${#tokens[@]} -eq 0 ]] && continue

    binary=$(unquote "${tokens[0]}")
    # Accept an absolute or relative path to git as well as the bare name.
    [[ "${binary##*/}" == "git" ]] || continue

    # Walk git's own options to find the subcommand. `-c <cfg>` and friends take
    # a separate value token, so they advance by two.
    index=1
    count=${#tokens[@]}
    subcommand=""
    segment_ask=0
    while [[ $index -lt $count ]]; do
        token=$(unquote "${tokens[$index]}")
        case "$token" in
        -c | --config-env)
            value=$(unquote "${tokens[$((index + 1))]:-}")
            # A push refspec can be injected through config
            # (`-c remote.origin.push=+refs/...`), which the argument scan below
            # never sees. Unreadable rather than safe.
            case "$value" in *push*) segment_ask=1 ;; esac
            index=$((index + 2))
            ;;
        -C | --git-dir | --work-tree | --namespace | --exec-path)
            index=$((index + 2))
            ;;
        -c* | --config-env=*)
            case "$token" in *push*) segment_ask=1 ;; esac
            index=$((index + 1))
            ;;
        -*)
            index=$((index + 1))
            ;;
        *)
            subcommand=$token
            break
            ;;
        esac
    done
    [[ "$subcommand" == "push" ]] || continue

    [[ $segment_ask -eq 1 ]] && NEEDS_ASK=1

    # A variable or command substitution can carry `--force` or `+main` into the
    # argument list without either appearing here. Scoped to the push segment on
    # purpose: `git commit -m "$(date)" && git push origin x` stays frictionless.
    case "$segment" in
    *'$'* | *'`'*) NEEDS_ASK=1 ;;
    esac

    argument=$((index + 1))
    while [[ $argument -lt $count ]]; do
        token=$(unquote "${tokens[$argument]}")
        case "$token" in
        --force | --force-with-lease | --force-with-lease=* | --force-if-includes | --delete | --mirror | --prune)
            [[ -z "$DANGER_TOKEN" ]] && DANGER_TOKEN=$token
            ;;
        --*)
            # Every other long option is safe, and matching the exact spellings
            # above rather than a substring is what keeps `--no-force-with-lease`
            # out of the deny set.
            ;;
        -*)
            # Bundled short options: -f is --force, -d is --delete.
            case "$token" in
            *f* | *d*) [[ -z "$DANGER_TOKEN" ]] && DANGER_TOKEN=$token ;;
            esac
            ;;
        +*)
            # A leading + on a refspec forces the update.
            [[ -z "$DANGER_TOKEN" ]] && DANGER_TOKEN=$token
            ;;
        :*)
            # An empty source in `<src>:<dst>` deletes the remote ref.
            [[ -z "$DANGER_TOKEN" ]] && DANGER_TOKEN=$token
            ;;
        esac
        argument=$((argument + 1))
    done
done <<<"$SEGMENTS"

if [[ -n "$DANGER_TOKEN" ]]; then
    emit deny "git-push-guard: 破壊的な push の綴りを検出しました(${DANGER_TOKEN})。force push とリモートブランチ削除は人間が自分の端末で行う方針です。"
    exit 0
fi

if [[ $NEEDS_ASK -eq 1 ]]; then
    emit ask "$ASK_REASON"
    exit 0
fi

exit 0
