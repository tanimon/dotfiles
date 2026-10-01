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
#   - `git pu""sh … --force`: 下の `*push*` の早期終了が reader の引用符除去より先に走る(ADR 0009)
#
# classify_segment とその呼び先は shell_reader_each_segment が名前で間接的に呼ぶ。
# 新しい shellcheck は SC2329、CI の ubuntu に入っている古い版は同じ指摘を SC2317 で出すので両方を抑制する。
# shellcheck disable=SC2317,SC2329
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
# 構文エラーの lib は `source` 自体を exit 2(= 理由なしのブロック)で終わらせるので `"$BASH" -n` で
# 先に確かめ(PATH 上の bash ではなく、このフックを動かしている interpreter で検査する)、
# 空や途中で切れた lib は関数が無いまま進んで exit 127(= フェイルオープン)になるので
# `declare -F` で確かめる。
reader_library="$(dirname "${BASH_SOURCE[0]}")/lib/shell-reader.bash"
if [[ ! -r "$reader_library" ]] || ! "$BASH" -n "$reader_library"; then
    emit ask "$ASK_REASON"
    exit 0
fi
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/shell-reader.bash
source "$reader_library" || {
    emit ask "$ASK_REASON"
    exit 0
}
declare -F shell_reader_read shell_reader_each_segment >/dev/null || {
    emit ask "$ASK_REASON"
    exit 0
}

DANGER_TEXT_RE='(^|[^[:alnum:]_-])git[[:space:]].*push'
DANGER_FLAG_RE='(--force|--force-with-lease|--force-if-includes|--delete|--mirror|--prune|[[:space:]]-[[:alpha:]]*[fd][[:alpha:]]*([^[:alnum:]_-]|$)|[[:space:]][+:][^[:space:]])'
# 1 行ごとに見る。heredoc の PR 本文では、別々の行にある「git push の手順」と「+12 行」を
# 組み合わせて ask にしないようにする(以前も改行で分割していたので同じ粒度になる)。
# here-string は一時ファイルを使う($TMPDIR に書けないと黙って「一致なし」になる)ので使わない。
# `${s%%$'\n'*}` / `${s#*$'\n'}` の行ループも使わない — 残りの文字列を毎行コピーするので二乗になり、
# 長さ超過の入力(下)で 179 KB に 2.3 秒かかった。改行での単語分割は線形(同じ入力で 0.02 秒)。
# 空行は落ちるが、空行はどちらの正規表現にも一致しない。
text_floor() {
    local LC_ALL=C IFS=$'\n' line restore_glob=0
    local -a lines
    # 分割の結果が glob として cwd に展開されないように、分割の間だけ set -f にする。
    if [[ $- != *f* ]]; then
        set -f
        restore_glob=1
    fi
    # shellcheck disable=SC2206 # 改行での単語分割そのものが目的
    lines=($1)
    [[ $restore_glob -eq 1 ]] && set +f
    [[ ${#lines[@]} -eq 0 ]] && return 1
    for line in "${lines[@]}"; do
        if [[ "$line" =~ $DANGER_TEXT_RE ]] && [[ "$line" =~ $DANGER_FLAG_RE ]]; then
            return 0
        fi
    done
    return 1
}

shell_reader_read "$COMMAND"
# 長すぎる入力は reader が token を作らない(安く読めない)。字面の床(行単位の正規表現で、
# reader の byte ごとの走査ではない)だけを生のコマンドに当て、一致したら ask にする。deny に
# しないのは、長い PR 本文の散文も同じ形になるため。一致しなければ classifier に任せる(ADR 0009)。
if [[ $SHELL_READER_TOO_LONG -eq 1 ]]; then
    text_floor "$COMMAND" && emit ask "$ASK_REASON"
    exit 0
fi

# 番兵の byte が入力にあると、reader が作る segment の境目を偽造できる(`git push origin main 2>\x01 --force`
# は bash では stderr の redirect 先が `\x01` の force push だが、reader には `--force` だけの segment が
# 別にあるように見える)。この時点でコマンドは `push` を含むので、読み切れないとして ask にする。
# プロセス置換も同じ: `git push origin <(echo) --force` の `)` の後ろは git の引数の続きだが、reader の
# segment では `--force` だけの segment に見える。
if [[ $SHELL_READER_SEP_IN_INPUT -eq 1 || $SHELL_READER_PROCESS_SUBSTITUTION -eq 1 ]]; then
    emit ask "$ASK_REASON"
    exit 0
fi

# reader が引用符を外すので、ここで外すのはバッククォートだけ。`` `git push … --force` `` は
# 実行されるので、前後の 1 つを外して読む。token ごとに呼ぶので $(…) で fork しない。
STRIPPED=''
strip_backticks() {
    STRIPPED=${1#\`}
    STRIPPED=${STRIPPED%\`}
}

DANGER_TOKEN=""
NEEDS_ASK=0

# $1(`--` 付き、`=` より前)が、破壊的な push の長オプションのどれかの前方一致か。
long_option_is_dangerous() {
    local option
    for option in --force --force-with-lease --force-if-includes --delete --mirror --prune; do
        [[ "$option" == "$1"* ]] && return 0
    done
    return 1
}

# 現在の segment(SHELL_READER_SEGMENT_START から token_count 個)にブレース展開があるか。
# 展開の結果は reader の token に現れない(`{main,--force}` の token は `main,--force`)ので、
# 危険な綴りを探す代わりに、展開がある push を読み切れないとして扱う。
segment_has_brace_expansion() {
    local brace_index
    for brace_index in $SHELL_READER_BRACE_INDEXES; do
        if [[ $brace_index -ge $SHELL_READER_SEGMENT_START &&
            $brace_index -lt $((SHELL_READER_SEGMENT_START + token_count)) ]]; then
            return 0
        fi
    done
    return 1
}

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
    local subcommand="" config_ask=0 alias_ask=0 danger="" token value argument

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
            # `-c alias.p='push --force' p` は、サブコマンドが `push` でなくても push になる。
            # git の設定キーは大文字小文字を区別しないので、`ALIAS.p=…` も同じに扱う。
            case "$value" in [Aa][Ll][Ii][Aa][Ss].*=*push*) alias_ask=1 ;; esac
            index=$((index + 2))
            ;;
        -C | --git-dir | --work-tree | --namespace | --exec-path)
            index=$((index + 2))
            ;;
        -c* | --config-env=*)
            case "$token" in *push* | *mirror*) config_ask=1 ;; esac
            case "$token" in -c[Aa][Ll][Ii][Aa][Ss].*=*push*) alias_ask=1 ;; esac
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
    # 下の `push` でないときの早期 return より前に立てる(alias の展開先はここでは読めない)。
    [[ $alias_ask -eq 1 ]] && NEEDS_ASK=1
    [[ "$subcommand" == "push" ]] || return 0

    local expansion=0 raw_argument
    # ブレース展開は `--force` や `+main` を token に現さずに作れる(`git push origin {main,--force}`)。
    # strict=0 でも同じ理由で ask にする(`expansion` は両方の分岐で ask になる)。
    segment_has_brace_expansion && expansion=1
    argument=$((index + 1))
    while [[ $argument -lt $token_count ]]; do
        # strict=0 用: push の引数に `$` かバッククォートがあるか。末尾の 1 つだけは除く —
        # `` x=`git push origin main` `` の `` main` `` は、git を包む置換を閉じるだけのもの。
        raw_argument=${tokens[$argument]%\`}
        case "$raw_argument" in *'$'* | *'`'*) expansion=1 ;; esac
        strip_backticks "${tokens[$argument]}"
        token=$STRIPPED
        case "$token" in
        --?*)
            # git は長オプションの一意な前方一致を受け付ける(`--dele` は `--delete`、`--force-w` は
            # `--force-with-lease`)。そこで `=` より前が危険なオプションの前方一致なら danger にする。
            # 曖昧な前方一致(`--d` は `--dry-run` とも一致する)は git 自身がエラーにするので、
            # deny しても失うものは無い。部分一致ではなく前方一致なので、`--no-force-with-lease` は
            # 一致しない。
            if long_option_is_dangerous "${token%%=*}"; then
                [[ -z "$danger" ]] && danger=$token
            fi
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
        # コマンド位置を確定できないので deny にはしない(ask 止まり)。下の -c の検査は散文でも
        # 立ちうるので使わず、危険な綴りと、push の引数の `$` / バッククォートだけを見る。
        # 後者が無いと、`` x=`git push origin $r` `` のように変数が --force を運ぶ push が、
        # バッククォートで包むだけで無出力になる。push の引数に限るので、git より前の token や
        # 引用符の中の散文(`echo "git push origin $r"` は token 1 つで、git と読める token が無い)は巻き込まない。
        [[ -n "$danger" || $expansion -eq 1 ]] && NEEDS_ASK=1
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
    [[ $expansion -eq 1 ]] && NEEDS_ASK=1

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
    # token の途中のバッククォートも同じく実行される。引用符の外の `` x=`git push … --force` `` は
    # reader が空白で割るので、代入の token が `` x=`git `` になり、上の前置の読み飛ばしで
    # command_start の手前に置かれる。そこで走査は先頭から始め、最後のバッククォートより後ろを見る
    # (バッククォートを含まない token では何も外さない)。command_start の手前にあるのは代入と
    # キーワード・前置詞だけで、ここから見つかった git は ask 止まり(危険な綴りがあるときだけ)。
    probe=0
    while [[ $probe -lt $token_count ]]; do
        raw=${tokens[$probe]##*\`}
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
# text_floor と正規表現は上(長さ超過の分岐と共用)。
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
