#!/usr/bin/env bash
# Command Guard(GLOSSARY)の起動部。各 guard は自前の部分(stdin の読み取り → 生の stdin の動詞の照合 →
# この module の検査)を済ませてから source し、command_guard_start と command_guard_emit を上から呼ぶ。
# set は呼び出し側に従う。-e の無い guard(issue-linkage-guard)でも同じに動くよう、失敗の経路はすべて if で分岐する。
#
# 約束(ADR 0009): 起動に失敗したとき(stdin を読めない、jq が無い、stdin が JSON でない、lib が無い・壊れている)、
# Failure Direction が ask の guard は ask を返し、無出力にも理由の無い exit 2 にもしない。pass の guard は無出力で
# exit 0 する。ただし動詞を含まない入力は、どちらの向きでも無出力で終わる。振る舞いの正本は test/guard-contract.bats。
# 配線とログの契約は .claude/rules/command-guard.md。
#
#   command_guard_start --name <name> --verb <glob>… --on-unreadable ask|pass [--lib <basename>]… [--require '<関数>…']…
#     戻った時点で COMMAND(.tool_input.command。空ではなく、どれかの動詞に一致する)が使え、jq があることも保証される。
#     起動に失敗したら Failure Direction に応じて ask を出すか無出力で exit 0 する。動詞に一致しないときも exit 0。
#     --name は英小文字と `-` だけ(jq が無くても固定文の JSON に埋めるため)、--lib はこのディレクトリの basename。
#   command_guard_emit deny|ask <理由>
#     判定の JSON を出す。deny / ask 以外は受け付けず、起動の失敗と同じに扱う(Command Guard は allow を返さない)。
#
# guard が source の前に設定する global:
#   COMMAND_GUARD_STDIN         stdin の内容
#   COMMAND_GUARD_STDIN_FAILED  stdin の読み取りに失敗したら 1(空の入力と区別する)
#
# 起動の手順がこの形である理由:
# - ログは開けるときだけ `exec 2>>` で繋ぐ。開けるかは `-w` ではなく `(: >>file)` の実書き込みで試す。`exec` は特殊
#   組み込みなので、開けないファイルへの `exec 2>>` はシェルごと無出力で終わらせる(= フェイルオープン)。
# - lib は `-r` → `"$BASH" -n` → `source` → `declare -F` の順に確かめる。存在しないファイルを `source` すると
#   `||` に届く前に bash が終了し(bash 3.2 で exit 1)、構文エラーの lib の `source` は exit 2(= 理由の無いブロック)に
#   なり、空や途中で切れた lib は関数が無いまま進んで exit 127(= フェイルオープン)になる。`-n` は PATH 上の bash ではなく
#   guard を動かしている interpreter で行い、その診断はログに残す。
# - jq を確かめるまでは builtin と `mkdir` だけを使う。jq が無い環境では PATH に他のコマンドも無いことがある。
# - source する lib はトップレベルで declare / typeset を使わない。command_guard_start の中で source するので、declare した
#   変数はその関数のローカル変数になり、start から戻ると消える(bash 3.2 には declare -g が無い)。この関数のローカル
#   変数は lib のトップレベルの代入と衝突しないよう `_command_guard_` で始める。
# - 公開の 2 関数はファイルの末尾に置く。途中で切れた module では公開の関数のどちらかが欠け、guard の declare -F が
#   捕まえる(内部の関数だけが欠けた module は作られない)。

_COMMAND_GUARD_NAME=command-guard
_COMMAND_GUARD_DIRECTION=ask
_COMMAND_GUARD_VERBS=()

# _command_guard_unreadable <種類>: 起動の失敗。Failure Direction が ask なら共通の固定文で ask を出す。どちらも exit 0。
# 種類は固定の文と lib の basename だけなので、JSON の escape は要らない。
_command_guard_unreadable() {
    if [[ "$_COMMAND_GUARD_DIRECTION" == ask ]]; then
        printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s: フックの部品を読めないため承認が必要です(%s)"}}\n' \
            "$_COMMAND_GUARD_NAME" "$1"
    fi
    exit 0
}

# _command_guard_matches_verb <文字列>: どれかの動詞(glob)に一致すれば 0。
_command_guard_matches_verb() {
    local _command_guard_verb
    for _command_guard_verb in "${_COMMAND_GUARD_VERBS[@]}"; do
        # shellcheck disable=SC2254 # 動詞は glob として照合する
        case "$1" in $_command_guard_verb) return 0 ;; esac
    done
    return 1
}

# _command_guard_unreadable_input <種類>: 入力を読めない。生の stdin に動詞があれば起動の失敗、無ければ無出力で終わる
# (無関係なコマンドまで ask にしても守れるものは無く、承認を惰性にするだけ)。
_command_guard_unreadable_input() {
    if _command_guard_matches_verb "${COMMAND_GUARD_STDIN-}"; then
        _command_guard_unreadable "$1"
    fi
    exit 0
}

command_guard_emit() {
    case "${1-}" in
    deny | ask) ;;
    *) _command_guard_unreadable '判定の指定が不正' ;;
    esac
    if ! jq -n --arg d "$1" --arg r "${2-}" \
        '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'; then
        _command_guard_unreadable '判定を出せない'
    fi
}

command_guard_start() {
    local _command_guard_name='' _command_guard_direction='' _command_guard_required='' _command_guard_invalid=0
    local _command_guard_libraries=() _command_guard_library _command_guard_path _command_guard_lib_dir
    local _command_guard_log_dir _command_guard_log_file
    _COMMAND_GUARD_VERBS=()
    while [[ $# -gt 0 ]]; do
        if [[ $# -lt 2 ]]; then
            _command_guard_invalid=1
            break
        fi
        case "$1" in
        --name) _command_guard_name=$2 ;;
        --verb) _COMMAND_GUARD_VERBS+=("$2") ;;
        --on-unreadable) _command_guard_direction=$2 ;;
        --lib) _command_guard_libraries+=("$2") ;;
        --require) _command_guard_required="$_command_guard_required $2" ;;
        *) _command_guard_invalid=1 ;;
        esac
        shift 2
    done
    # 名前と向きは、読めた分だけ先に反映する(指定の誤りを知らせる ask にも名前を載せる)。向きが読めなければ ask のまま。
    if [[ "$_command_guard_name" =~ ^[a-z][a-z-]*$ ]]; then
        _COMMAND_GUARD_NAME=$_command_guard_name
    else
        _command_guard_invalid=1
    fi
    case "$_command_guard_direction" in
    ask | pass) _COMMAND_GUARD_DIRECTION=$_command_guard_direction ;;
    *) _command_guard_invalid=1 ;;
    esac
    if [[ ${#_COMMAND_GUARD_VERBS[@]} -eq 0 ]]; then
        _command_guard_invalid=1
    fi
    if [[ ${#_command_guard_libraries[@]} -gt 0 ]]; then
        for _command_guard_library in "${_command_guard_libraries[@]}"; do
            [[ "$_command_guard_library" =~ ^[A-Za-z0-9._-]+$ ]] || _command_guard_invalid=1
        done
    fi
    if [[ $_command_guard_invalid -eq 1 ]]; then
        _command_guard_unreadable '起動の指定が不正'
    fi

    _command_guard_log_dir="${HOME:-}/.claude/logs"
    _command_guard_log_file="$_command_guard_log_dir/$_COMMAND_GUARD_NAME-errors.log"
    if [[ -n "${HOME:-}" ]] && mkdir -p "$_command_guard_log_dir" 2>/dev/null &&
        (: >>"$_command_guard_log_file") 2>/dev/null; then
        exec 2>>"$_command_guard_log_file"
    fi

    if [[ "${COMMAND_GUARD_STDIN_FAILED:-0}" == 1 ]]; then
        _command_guard_unreadable 'stdin を読めない'
    fi
    if ! command -v jq >/dev/null 2>&1; then
        _command_guard_unreadable_input 'jq が無い'
    fi
    if ! COMMAND=$(printf '%s' "${COMMAND_GUARD_STDIN-}" | jq -r '.tool_input.command // empty' 2>/dev/null); then
        _command_guard_unreadable_input 'stdin が JSON でない'
    fi
    # 空の command は Bash 以外のツールか、command を持たない payload。JSON でない payload は上の取り出しで落ちる。
    if [[ -z "$COMMAND" ]] || ! _command_guard_matches_verb "$COMMAND"; then
        exit 0
    fi

    _command_guard_lib_dir=${BASH_SOURCE[0]%/*}
    if [[ "$_command_guard_lib_dir" == "${BASH_SOURCE[0]}" ]]; then
        _command_guard_lib_dir=.
    fi
    if [[ ${#_command_guard_libraries[@]} -gt 0 ]]; then
        for _command_guard_library in "${_command_guard_libraries[@]}"; do
            _command_guard_path="$_command_guard_lib_dir/$_command_guard_library"
            if [[ ! -r "$_command_guard_path" ]] || ! "$BASH" -n "$_command_guard_path"; then
                _command_guard_unreadable "lib の ${_command_guard_library} を読めない"
            fi
            # shellcheck source=/dev/null
            if ! source "$_command_guard_path"; then
                _command_guard_unreadable "lib の ${_command_guard_library} を読めない"
            fi
        done
    fi
    # shellcheck disable=SC2086 # 関数名の並びを語に分ける
    if [[ -n "${_command_guard_required// /}" ]] && ! declare -F $_command_guard_required >/dev/null; then
        _command_guard_unreadable 'lib に関数が無い'
    fi
}
