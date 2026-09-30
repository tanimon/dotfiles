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
#
# classify_segment とその呼び先は shell_reader_each_segment が名前で間接的に呼ぶ。
# shellcheck disable=SC2329
set -euo pipefail

# Errors go to a log file when one can be opened, and to the hook's own stderr
# otherwise. This lives here rather than in the settings.json wrapper because a
# wrapper of the form `mkdir -p … && script 2>>…` skips the script entirely when
# the log directory cannot be created — a failed redirection abandons the
# command — which turns a logging problem into a missing decision, i.e. into
# fail-open. Nothing here may abort the run.
# The append probe is the guard rather than a `-w` test: `exec` is a special
# builtin, so an open that fails anyway (read-only mount, full disk, immutable
# flag) exits the shell with no output — the very fail-open this avoids.
LOG_DIR="${HOME:-}/.claude/logs"
LOG_FILE="$LOG_DIR/git-push-guard-errors.log"
if [[ -n "${HOME:-}" ]] && mkdir -p "$LOG_DIR" 2>/dev/null &&
    (: >>"$LOG_FILE") 2>/dev/null; then
    exec 2>>"$LOG_FILE"
fi

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

# 共有 reader を読む。このフックの無出力はフェイルオープンなので、読めないときは ask に倒す。
# `source` は存在しないファイルで `||` に届く前に bash 自身が終了する
# (bash 3.2 で実測、終了コード 1)ので、先に読めることを確かめる。
reader_library="$(dirname "${BASH_SOURCE[0]}")/lib/shell-reader.bash"
[[ -r "$reader_library" ]] || {
    emit ask "$ASK_REASON"
    exit 0
}
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/shell-reader.bash
source "$reader_library" || {
    emit ask "$ASK_REASON"
    exit 0
}

shell_reader_read "$COMMAND"
# 長すぎる入力は安く読めない。何も返さず classifier に任せる(ADR 0009 の残存リスク)。
[[ $SHELL_READER_TOO_LONG -eq 1 ]] && exit 0

# reader が引用符を外すので、ここで外すのはバッククォートだけ。`` `git push … --force` `` は
# 実行されるので、前後の 1 つを外して読む。token ごとに呼ぶので $(…) で fork しない。
STRIPPED=''
strip_backticks() {
    STRIPPED=${1#\`}
    STRIPPED=${STRIPPED%\`}
}

DANGER_TOKEN=""
NEEDS_ASK=0

# Classify one segment as a git invocation whose binary sits at token index $1.
# Reads the `tokens` / `token_count` globals classify_segment sets.
#
# $2 is 1 when that index is the command position — the segment's first token,
# or the first one past a recognized prefix — and 0 when the `git` token was
# merely found somewhere further along. The two cases warrant different
# verdicts: `xargs -n1 git push origin main --force` is a real push this scan
# cannot confirm will run, while `- git push --force を deny する` inside a
# heredoc PR body tokenizes identically and pushes nothing. `ask` covers the
# first without making the second unwritable; `deny` there would re-create the
# friction this hook exists to remove.
classify_from() {
    local start=$1 strict=$2
    local index=$((start + 1))
    local subcommand="" config_ask=0 danger="" token value argument

    # Walk git's own options to find the subcommand. `-c <cfg>` and friends take
    # a separate value token, so they advance by two.
    while [[ $index -lt $token_count ]]; do
        strip_backticks "${tokens[$index]}"
        token=$STRIPPED
        case "$token" in
        -c | --config-env)
            strip_backticks "${tokens[$((index + 1))]:-}"
            value=$STRIPPED
            # Config can make a plain push destructive without any flag the
            # argument scan below would see: `remote.<name>.push=+refs/…`
            # carries a force refspec, and `remote.<name>.mirror=true` makes
            # every push behave as `--mirror`. `mirror` does not contain `push`,
            # so it needs its own pattern. Unreadable rather than safe.
            case "$value" in *push* | *mirror*) config_ask=1 ;; esac
            index=$((index + 2))
            ;;
        -C | --git-dir | --work-tree | --namespace | --exec-path)
            index=$((index + 2))
            ;;
        -c* | --config-env=*)
            case "$token" in *push* | *mirror*) config_ask=1 ;; esac
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
    [[ "$subcommand" == "push" ]] || return 0

    argument=$((index + 1))
    while [[ $argument -lt $token_count ]]; do
        strip_backticks "${tokens[$argument]}"
        token=$STRIPPED
        case "$token" in
        --force | --force-with-lease | --force-with-lease=* | --force-if-includes | --delete | --mirror | --prune)
            [[ -z "$danger" ]] && danger=$token
            ;;
        --*)
            # Every other long option is safe, and matching the exact spellings
            # above rather than a substring is what keeps `--no-force-with-lease`
            # out of the deny set.
            ;;
        -*)
            # Bundled short options: -f is --force, -d is --delete.
            case "$token" in
            *f* | *d*) [[ -z "$danger" ]] && danger=$token ;;
            esac
            ;;
        +*)
            # A leading + on a refspec forces the update.
            [[ -z "$danger" ]] && danger=$token
            ;;
        :*)
            # An empty source in `<src>:<dst>` deletes the remote ref.
            [[ -z "$danger" ]] && danger=$token
            ;;
        esac
        argument=$((argument + 1))
    done

    if [[ $strict -eq 0 ]]; then
        # An unconfirmed command position never denies, and the fail-closed
        # triggers below would fire on ordinary prose, so only a dangerous
        # spelling counts here.
        [[ -n "$danger" ]] && NEEDS_ASK=1
        return 0
    fi

    [[ $config_ask -eq 1 ]] && NEEDS_ASK=1

    # A variable or command substitution can carry `--force` or `+main` into the
    # argument list without either appearing here. Scoped to the push segment on
    # purpose: `git commit -m "$(date)" && git push origin x` stays frictionless.
    local raw
    for raw in "${tokens[@]}"; do
        case "$raw" in *'$'* | *'`'*) NEEDS_ASK=1 ;; esac
    done

    [[ -n "$danger" && -z "$DANGER_TOKEN" ]] && DANGER_TOKEN=$danger
    return 0
}

# segment への分割と、グルーピング記号・リダイレクトの `&`・継続行の正規化は
# reader が行う(test/shell-reader.bats)。`git commit -m wip && git push --force` が
# 最初の動詞に隠れず、`(cd dir && git push … --force)` の `)` がフラグに接着しないのは
# そのため。この関数は segment ごとに tokens / token_count を設定して判定する。
#
# shell_reader_each_segment の callback。常に 0 を返す(全 segment を見る)。
# classify_from は tokens / token_count を動的スコープ(または global)経由で読む。
# reader の local は `_sr_` 接頭辞なので、ここの変数名と衝突しない。
classify_segment() {
    # 空配列の展開は bash 3.2 の set -u で落ちるが、callback は空でない segment でしか呼ばれない。
    tokens=("$@")
    token_count=$#

    # Skip what can legitimately precede the binary. Shell keywords and command
    # prefixes are the fourth way a segment stops starting with `git` — after
    # grouping punctuation, redirect operators and line continuations, all three
    # normalized above — and the one an agent produces by accident, because a
    # one-line `for … do git push … ; done` or `if true; then …; fi` is ordinary
    # phrasing. Walking an index rather than re-slicing the array avoids
    # expanding an empty array, which bash 3.2 rejects under `set -u`.
    command_start=0
    while [[ $command_start -lt $token_count ]]; do
        strip_backticks "${tokens[$command_start]}"
        probe=$STRIPPED
        case "$probe" in
        # `VAR=value git push …`. Anchored so a token that merely contains `=`
        # is not mistaken for an assignment.
        [A-Za-z_]*=*) command_start=$((command_start + 1)) ;;
        if | then | elif | else | fi | while | until | do | done | '!' | time | nohup | command | env | sudo | nice | exec)
            command_start=$((command_start + 1))
            ;;
        *) break ;;
        esac
    done

    if [[ $command_start -lt $token_count ]]; then
        strip_backticks "${tokens[$command_start]}"
        binary=$STRIPPED
        # Accept an absolute or relative path to git as well as the bare name.
        if [[ "${binary##*/}" == "git" ]]; then
            classify_from "$command_start" 1
            return 0
        fi
    fi

    # The command position is something else. `git` may still be in here — as a
    # wrapper's argument, inside a substitution, or as a word in a heredoc — so
    # look for it and classify from there, at `ask` strength only. Quotes are
    # *not* stripped for this match, so `echo "git push --force"` stays silent
    # (a quoted `git` is text); a leading backtick is, because that one runs.
    probe=$command_start
    while [[ $probe -lt $token_count ]]; do
        raw=${tokens[$probe]#\`}
        if [[ "${raw##*/}" == "git" ]]; then
            classify_from "$probe" 0
            break
        fi
        probe=$((probe + 1))
    done
    return 0
}

shell_reader_each_segment classify_segment

# reader は $(…) やバッククォートの中を読まないので、引用符の中の置換に埋まった push
# (`echo "$(git push origin main --force)"`、PR 本文の heredoc)は token 1 つの文字列になる。
# 閉じていない引用符(heredoc の `don't`)も、それ以降を 1 token に飲み込む。これらの token に
# git・push・危険な綴りがそろっていれば ask にする。deny にしないのは、PR 本文の散文も同じ形になるため。
# 同じ行に「git … push」と ` -f ` や ` :x` を含む散文が ask になるのは、受容した誤 ask。
DANGER_TEXT_RE='(^|[^[:alnum:]_-])git[[:space:]].*push'
DANGER_FLAG_RE='(--force|--force-with-lease|--force-if-includes|--delete|--mirror|--prune|[[:space:]]-[[:alpha:]]*[fd][[:alpha:]]*([^[:alnum:]_-]|$)|[[:space:]][+:][^[:space:]])'
# 1 行ごとに見る。heredoc の PR 本文では、別々の行にある「git push の手順」と「+12 行」を
# 組み合わせて ask にしないようにする(以前も改行で分割していたので同じ粒度になる)。
text_floor() {
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ $DANGER_TEXT_RE ]] && [[ "$line" =~ $DANGER_FLAG_RE ]]; then
            return 0
        fi
    done <<<"$1"
    return 1
}
if [[ -z "$DANGER_TOKEN" && ${#SHELL_READER_TOKENS[@]} -gt 0 ]]; then
    last_index=$((${#SHELL_READER_TOKENS[@]} - 1))
    for index in "${!SHELL_READER_TOKENS[@]}"; do
        token=${SHELL_READER_TOKENS[$index]}
        case "$token" in
        *'$'* | *'`'*) text_floor "$token" && NEEDS_ASK=1 ;;
        *)
            if [[ $SHELL_READER_UNCLOSED_QUOTE -eq 1 && $index -eq $last_index ]]; then
                text_floor "$token" && NEEDS_ASK=1
            fi
            ;;
        esac
    done
fi

if [[ -n "$DANGER_TOKEN" ]]; then
    emit deny "git-push-guard: 破壊的な push の綴りを検出しました(${DANGER_TOKEN})。force push とリモートブランチ削除は人間が自分の端末で行う方針です。"
    exit 0
fi

if [[ $NEEDS_ASK -eq 1 ]]; then
    emit ask "$ASK_REASON"
    exit 0
fi

exit 0
