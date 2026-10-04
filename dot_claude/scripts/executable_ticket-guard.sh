#!/usr/bin/env bash
# PreToolUse hook: 個人リポジトリでの `gh pr create` を、ticket スキルの作成モードを経た本文(マーカー
# `<!-- ticket-skill -->` を含む)でなければ deny する。`gh issue create` は常に deny し、作成と native relationship の
# 設定を一度に行う create-issue.sh へ案内する(作成後の設定を別の手順にすると、それだけが漏れるため)。
# 設計: chezmoi リポジトリの docs/superpowers/specs/2026-10-04-ticket-skill-design.md
#
# 目的はスキルの起動忘れを防ぐことで、迂回を防ぐことではない(マーカーは手で書ける)。
# そのため reader が読み切れない入力(長すぎる・引用符が閉じない・番兵の byte を含む)は判定せずに通す。
# git-push-guard とは逆の向きで、読めないことを理由に deny すると無関係なコマンドを止める損の方が大きい。
#
# Decision contract:
#   deny        — 範囲内のリポジトリの gh issue create、または本文にマーカーを確認できない gh pr create
#   (no output) — それ以外。allow / ask は返さない
#
# 範囲は lib/ticket-scope.bash が判定する(-R / --repo があればそれ、無ければフックの cwd の origin)。
# 残存: `cd <dir> && gh …` の cd 先は見ない。heredoc 演算子より後ろの segment は本文の行でありうるので判定しない
# (heredoc の後ろに実際に書かれた作成コマンドも素通りする)。`bash -c` の内側、`gh api` での作成、
# launchd から直接 gh を呼ぶスクリプトには効かない。フックが無い・落ちたときは判定なしで通る。
# check_segment は shell_reader_each_segment が名前で間接的に呼ぶ。
# shellcheck disable=SC2317,SC2329
set -uo pipefail

LOG_DIR="${HOME:-}/.claude/logs"
LOG_FILE="$LOG_DIR/ticket-guard-errors.log"
if [[ -n "${HOME:-}" ]] && mkdir -p "$LOG_DIR" 2>/dev/null &&
    (: >>"$LOG_FILE") 2>/dev/null; then
    exec 2>>"$LOG_FILE"
fi

MARKER='<!-- ticket-skill -->'

STDIN_JSON=$(cat) || exit 0
command -v jq >/dev/null 2>&1 || exit 0
COMMAND=$(printf '%s' "$STDIN_JSON" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
CWD=$(printf '%s' "$STDIN_JSON" | jq -r '.cwd // empty' 2>/dev/null) || exit 0
case "$COMMAND" in
*gh*create* | *gh*new*) ;;
*) exit 0 ;;
esac

script_dir=$(dirname "${BASH_SOURCE[0]}")
for library in "$script_dir/lib/shell-reader.bash" "$script_dir/lib/ticket-scope.bash"; do
    [[ -r "$library" ]] && "$BASH" -n "$library" 2>/dev/null || exit 0
    # shellcheck source=/dev/null
    source "$library" || exit 0
done
declare -F shell_reader_read shell_reader_each_segment ticket_scope_in_scope >/dev/null || exit 0

shell_reader_read "$COMMAND"
if [[ $SHELL_READER_TOO_LONG -eq 1 || $SHELL_READER_SEP_IN_INPUT -eq 1 ||
    $SHELL_READER_UNCLOSED_QUOTE -eq 1 ]]; then
    exit 0
fi

# 最初の heredoc 演算子の token index。無ければ -1。
HEREDOC_INDEX=${SHELL_READER_HEREDOC_INDEXES:- }
HEREDOC_INDEX=${HEREDOC_INDEX# }
HEREDOC_INDEX=${HEREDOC_INDEX%% *}
[[ -z "$HEREDOC_INDEX" ]] && HEREDOC_INDEX=-1

DENY_DETAIL=''

# segment が範囲内の作成コマンドで、本文にマーカーを確認できなければ DENY_DETAIL を設定して 1 を返す。
check_segment() {
    local -a tokens=("$@")
    local i=0 count=$#
    while [[ $i -lt $count && "${tokens[$i]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
        i=$((i + 1))
    done
    [[ $i -lt $count ]] || return 0
    [[ "${tokens[$i]}" == gh || "${tokens[$i]}" == */gh ]] || return 0
    [[ "${tokens[$((i + 1))]:-}" == issue || "${tokens[$((i + 1))]:-}" == pr ]] || return 0
    # new は create の alias
    [[ "${tokens[$((i + 2))]:-}" == create || "${tokens[$((i + 2))]:-}" == new ]] || return 0
    if [[ $HEREDOC_INDEX -ge 0 && $SHELL_READER_SEGMENT_START -gt $HEREDOC_INDEX ]]; then
        return 0
    fi

    local repo='' body_file='' has_body_file=0 argument
    local j=$((i + 3))
    while [[ $j -lt $count ]]; do
        argument=${tokens[$j]}
        case "$argument" in
        -R | --repo)
            repo=${tokens[$((j + 1))]:-}
            j=$((j + 1))
            ;;
        --repo=*) repo=${argument#--repo=} ;;
        -F | --body-file)
            has_body_file=1
            body_file=${tokens[$((j + 1))]:-}
            j=$((j + 1))
            ;;
        --body-file=*)
            has_body_file=1
            body_file=${argument#--body-file=}
            ;;
        esac
        j=$((j + 1))
    done

    ticket_scope_in_scope "${CWD:-.}" "$repo" || return 0
    if [[ "${tokens[$((i + 1))]}" == issue ]]; then
        DENY_DETAIL='issue は create-issue.sh で作る(作成と relationship の native 設定を一度に行うため)。'
        return 1
    fi
    case "$COMMAND" in *"$MARKER"*) return 0 ;; esac

    if [[ $has_body_file -eq 1 ]]; then
        case "$body_file" in
        '' | -) DENY_DETAIL='--body-file に標準入力は使えない(フックが本文を読めない)。' ;;
        *'$'* | *'`'*) DENY_DETAIL='--body-file のパスに変数やコマンド置換がある(フックは展開前の文字列しか受け取れない)。' ;;
        /*)
            if [[ -r "$body_file" ]] && grep -qF -- "$MARKER" "$body_file"; then
                return 0
            fi
            DENY_DETAIL="本文ファイル $body_file が読めないか、マーカーが無い。"
            ;;
        *) DENY_DETAIL='--body-file は絶対パスで渡す(cd が前に連結されているとフックから解決できない)。' ;;
        esac
    else
        DENY_DETAIL='本文にマーカーが無い。'
    fi
    return 1
}

shell_reader_each_segment check_segment && exit 0

jq -n --arg detail "$DENY_DETAIL" '{hookSpecificOutput: {hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("ticket-guard: " + $detail
        + " ticket スキル(~/.claude/skills/ticket/SKILL.md)の作成モードで本文を作り"
        + "(関連 issue のメンション、relationship、PR なら Closes と AC 対応表)、末尾に <!-- ticket-skill --> を付ける。"
        + "本文ファイルは git rev-parse --absolute-git-dir の出力の下の ticket/ に置き、PR は gh pr create --body-file <絶対パス>、"
        + "issue は bash ~/.claude/skills/ticket/scripts/create-issue.sh --title <title> --body-file <絶対パス> で作る。")}}'
