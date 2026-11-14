#!/usr/bin/env bash
# PreToolUse hook: 個人リポジトリでの `gh pr create` を、issue-linkage スキルの手順を経た本文(マーカー
# `<!-- issue-linkage -->` を含む)でなければ deny する。`gh issue create` は常に deny し、作成と native relationship の
# 設定を一度に行う create-issue.sh へ案内する(作成後の設定を別の手順にすると、それだけが漏れるため)。
# 設計: chezmoi リポジトリの spec #577。ガードを採った理由は同じリポジトリの
# docs/superpowers/specs/2026-10-04-ticket-skill-design.md
#
# 目的はスキルの起動忘れを防ぐことで、迂回を防ぐことではない(マーカーは手で書ける)。
# そのため reader が読み切れない入力(長すぎる・引用符が閉じない・番兵の byte を含む)は判定せずに通す。
# git-push-guard とは逆の向きで、読めないことを理由に deny すると無関係なコマンドを止める損の方が大きい。
#
# Decision contract:
#   deny        — 範囲内のリポジトリの gh issue create、または本文にマーカーを確認できない gh pr create
#   (no output) — それ以外。allow / ask は返さない
#
# 範囲は lib/issue-linkage-scope.bash が判定する(gh と同じ優先順で、-R / --repo、前置の GH_REPO=、フック自身の環境の GH_REPO、
# 無ければフックの cwd の remote から gh が既定にする作成先)。
# 残存: 先頭の `VAR=` と制御語・`command` / `time` は読み飛ばすが、`sudo` / `env` / `nice` などの前置詞、
# オプション付きの `time`(`time -p`)、`bash -c` の内側は見ない(`sudo gh pr create --fill` は判定せずに通る)。
# `cd <dir> && gh …` の cd 先は見ない。heredoc 演算子より後ろの segment は本文の行でありうるので、全体を読んだ
# 判定では見ない。代わりに生の COMMAND から最後の heredoc の終端行を求め、その後ろだけを読み直して判定する
# (本文を heredoc で書いた直後の `gh pr create --body-file <絶対パス>` はここで判定する。本文ファイルは同じ呼び出しの
# heredoc がまだ書いていないので、その heredoc の本文にマーカーがあるかを見る)。本文の行は判定しない。
# 残存: 終端行が無い heredoc の後ろ、同じ行で heredoc 演算子の後ろに書いた作成コマンド(`cat <<EOF && gh pr create`)、
# 読み直した後ろが 8 KB を超える・引用符が閉じないときは判定せずに通る。heredoc が複数あるときは、最後の終端行より前に
# 書いた作成コマンドも判定しない。--body の値の heredoc は生の COMMAND から本文を読むが、
# `gh … create` の行より後ろで同じ区切り語を使う最初の heredoc を本文とみなすので、--body 以外の heredoc を
# 先に書くと取り違える。`bash -c` の内側、`gh api` での作成、
# launchd から直接 gh を呼ぶスクリプトには効かない。フックが無い・落ちたときは判定なしで通る。
# check_segment は shell_reader_each_segment が名前で間接的に呼ぶ。
# shellcheck disable=SC2317,SC2329
set -uo pipefail

# 起動の自前の部分。起動 module(lib/command-guard.bash)が無い・壊れているときは、この guard の失敗の向きどおり
# 無出力で通す。手順と理由は module のヘッダ。動詞を含まない入力は module を読まずに終わる。
COMMAND_GUARD_STDIN_FAILED=0
COMMAND_GUARD_STDIN=$(cat) || COMMAND_GUARD_STDIN_FAILED=1
# 動詞は自前の部分の照合と command_guard_start の --verb で共有する(ずれると動詞を含む入力が module に届かない)。
COMMAND_GUARD_VERB_CREATE='*gh*create*'
COMMAND_GUARD_VERB_NEW='*gh*new*'
# JSON は文字を \uXXXX でも書けるので、`\u` を含む入力も module に渡す(module が jq で取り出す COMMAND の照合より狭くしない)。
# shellcheck disable=SC2053 # 動詞は glob として照合する
[[ $COMMAND_GUARD_STDIN_FAILED -eq 1 || "$COMMAND_GUARD_STDIN" == $COMMAND_GUARD_VERB_CREATE ||
    "$COMMAND_GUARD_STDIN" == $COMMAND_GUARD_VERB_NEW || "$COMMAND_GUARD_STDIN" == *\\u* ]] || exit 0
command_guard_dir=${BASH_SOURCE[0]%/*}
[[ "$command_guard_dir" != "${BASH_SOURCE[0]}" ]] || command_guard_dir=.
# shellcheck source-path=SCRIPTDIR source=lib/command-guard.bash
if [[ ! -r "$command_guard_dir/lib/command-guard.bash" ]] || ! "$BASH" -n "$command_guard_dir/lib/command-guard.bash" ||
    ! source "$command_guard_dir/lib/command-guard.bash" || ! declare -F command_guard_start command_guard_emit >/dev/null; then
    exit 0
fi

command_guard_start --name issue-linkage-guard --verb "$COMMAND_GUARD_VERB_CREATE" --verb "$COMMAND_GUARD_VERB_NEW" --on-unreadable pass \
    --lib shell-reader.bash --lib issue-linkage-scope.bash \
    --require 'shell_reader_read shell_reader_each_segment shell_reader_segment_follows issue_linkage_scope_in_scope issue_linkage_scope_repo_flag'
# command_guard_start から戻った時点で、COMMAND(.tool_input.command。動詞に一致する)と jq が使える。

MARKER='<!-- issue-linkage -->'
CWD=$(printf '%s' "$COMMAND_GUARD_STDIN" | jq -r '.cwd // empty' 2>/dev/null) || exit 0

DENY_DETAIL=''

# heredoc_tail: COMMAND の最後の heredoc の終端行より後ろを出力する。heredoc が無い、または最後の heredoc に終端行が
# 無い(以降がすべて本文)ときは何も出さない。reader は heredoc の本文を読まないので、本文の後ろに書かれた
# 作成コマンドはここで切り出して読み直す。本文の行は対象に入れない。`<<<`(here-string)は heredoc ではない。
# 引用符の中の `<<` を演算子と取り違えると、後ろを本文とみなして何も出さないだけで、判定が増える向きには外れない。
heredoc_tail() {
    printf '%s\n' "$COMMAND" | LC_ALL=C awk '
        function enqueue(line,    word) {
            gsub(/<<</, "", line)
            while (match(line, /<<-?[ \t]*[\047"]?[A-Za-z0-9_]+/)) {
                word = substr(line, RSTART, RLENGTH)
                sub(/^<<-?[ \t]*[\047"]?/, "", word)
                queue[++last] = word
                line = substr(line, RSTART + RLENGTH)
            }
        }
        BEGIN { first = 1; last = 0 }
        first <= last {
            line = $0
            sub(/^\t*/, "", line)
            if (line == queue[first] && ++first > last) { seen = 1; buf = "" }
            next
        }
        { buf = buf $0 "\n"; enqueue($0) }
        END { if (seen && first > last) printf "%s", buf }'
}

# heredoc_file_has_marker <絶対パス>: COMMAND の heredoc のうち、演算子の行に <絶対パス> を書いているもの
# (`cat > <絶対パス> <<'EOF'`)の最後の本文にマーカーがあれば 0、無ければ 1、そういう heredoc が無ければ 2 を返す。
# 本文ファイルを同じ Bash 呼び出しの heredoc で書くとき、フックの時点ではファイルがまだ無いので、ディスクではなく
# heredoc の本文を読む。
heredoc_file_has_marker() {
    printf '%s\n' "$COMMAND" | LC_ALL=C awk -v path="$1" -v marker="$MARKER" '
        function writes_path(line,    p, before, after) {
            p = index(line, path)
            if (p == 0) return 0
            before = (p > 1) ? substr(line, p - 1, 1) : ""
            after = substr(line, p + length(path), 1)
            return before !~ /[A-Za-z0-9_.\/-]/ && after !~ /[A-Za-z0-9_.\/-]/
        }
        BEGIN { res = 2 }
        state == 1 {
            line = $0
            sub(/^\t*/, "", line)
            if (line == delimiter) {
                if (targets) res = found ? 0 : 1
                state = 0
            } else if (index($0, marker)) found = 1
            next
        }
        {
            copy = $0
            gsub(/<<</, "", copy)
            if (match(copy, /<<-?[ \t]*[\047"]?[A-Za-z0-9_]+/)) {
                delimiter = substr(copy, RSTART, RLENGTH)
                sub(/^<<-?[ \t]*[\047"]?/, "", delimiter)
                targets = writes_path(copy)
                found = 0
                state = 1
            }
        }
        END { exit res }'
}

# heredoc_body_has_marker <区切り語>: COMMAND の中で `gh … create` の後に始まる最初の、区切り語 <区切り語> の
# heredoc の本文にマーカーがあれば 0、本文を読めてマーカーが無ければ 1、その heredoc が見つからなければ 2 を返す。--body "$(cat <<'EOF' … EOF)" の本文に空白を含む二重引用符
# (See "foo bar" here)があると、reader は外側の "…" を内側の " で閉じたと読んで token を分けるので、
# マーカーが --body の値の token に入らない。そのときは token ではなく生の COMMAND から本文を読む。
heredoc_body_has_marker() {
    printf '%s\n' "$COMMAND" | LC_ALL=C awk -v delimiter="$1" -v marker="$MARKER" '
        state == 0 && /gh[ \t].*(create|new)/ { state = 1 }
        state == 1 && $0 ~ ("<<-?[ \t]*[\047\"]?" delimiter "[\047\"]?([ \t)]|$)") { state = 2; next }
        state == 2 {
            line = $0
            sub(/^\t*/, "", line)
            if (line == delimiter) exit
            if (index($0, marker)) { found = 1; exit }
        }
        END { exit found ? 0 : (state == 2 ? 1 : 2) }'
}

# segment が範囲内の作成コマンドで、本文にマーカーを確認できなければ DENY_DETAIL を設定して 1 を返す。
check_segment() {
    local -a tokens=("$@")
    local i=0 count=$# env_repo=''
    while [[ $i -lt $count ]]; do
        case "${tokens[$i]}" in
        if | then | elif | else | while | until | do | '!' | '{' | command | time) ;;
        GH_REPO=*) env_repo=${tokens[$i]#GH_REPO=} ;;
        *)
            [[ "${tokens[$i]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || break
            ;;
        esac
        i=$((i + 1))
    done
    [[ $i -lt $count ]] || return 0
    [[ "${tokens[$i]}" == gh || "${tokens[$i]}" == */gh ]] || return 0
    [[ "${tokens[$((i + 1))]:-}" == issue || "${tokens[$((i + 1))]:-}" == pr ]] || return 0
    # new は create の alias
    [[ "${tokens[$((i + 2))]:-}" == create || "${tokens[$((i + 2))]:-}" == new ]] || return 0
    shell_reader_segment_follows heredoc && return 0

    local repo='' body_file='' has_body_file=0 body_value='' has_body=0 argument delimiter
    local heredoc_read=0 heredoc_status
    local heredoc_pattern="<<-?[[:space:]]*['\"]?([A-Za-z0-9_]+)"
    local j=$((i + 3))
    while [[ $j -lt $count ]]; do
        argument=${tokens[$j]}
        case "$argument" in
        # 作成しない呼び出し。範囲内でも止めると、調べもののたびに実情と合わない理由で deny する。
        --help | -h | --dry-run) return 0 ;;
        # タイトルは自由記述で `-` から始まりうる。値を読み飛ばさないと -F / -b / -R の短縮形と誤読する。
        # 作成先の -R / --repo は issue_linkage_scope_repo_flag が読むので、ここでは値を読み飛ばすだけ。
        -t | --title | -R | --repo) j=$((j + 1)) ;;
        -F | --body-file)
            has_body_file=1
            body_file=${tokens[$((j + 1))]:-}
            j=$((j + 1))
            ;;
        --body-file=*)
            has_body_file=1
            body_file=${argument#--body-file=}
            ;;
        # gh(pflag)は短いオプションに値を続けた -F<path> / -b<text> と、その間に = を挟む形も受け付ける。
        -F?*)
            has_body_file=1
            body_file=${argument#-F}
            body_file=${body_file#=}
            ;;
        # heredoc を `--body "$(cat <<'EOF' … EOF)"` で渡したときも、本文は --body の値の token に入る。
        -b | --body) body_value=${tokens[$((j + 1))]:-} has_body=1 j=$((j + 1)) ;;
        --body=*) body_value=${argument#--body=} has_body=1 ;;
        -b?*)
            body_value=${argument#-b}
            body_value=${body_value#=}
            has_body=1
            ;;
        esac
        j=$((j + 1))
    done

    # gh は -R を GH_REPO より優先する。前置の GH_REPO= が無ければ、Bash ツールが引き継ぐフック自身の環境の値を見る。
    # create-issue.sh も同じ関数で作成先を読む。
    repo=$(issue_linkage_scope_repo_flag "${tokens[@]:$((i + 3))}")
    [[ -n "$repo" ]] || repo=${env_repo:-${GH_REPO:-}}
    issue_linkage_scope_in_scope "${CWD:-.}" "$repo" || return 0
    if [[ "${tokens[$((i + 1))]}" == issue ]]; then
        DENY_DETAIL='issue は create-issue.sh で作る(作成と relationship の native 設定を一度に行うため)。'
        return 1
    fi
    # 照合は --body / -b の値に限る。コマンド全体で探すと、--title や連結された別の segment の echo に
    # あるマーカーでも通ってしまう。
    if [[ $has_body -eq 1 ]]; then
        case "$body_value" in *"$MARKER"*) return 0 ;; esac
        if [[ "$body_value" =~ $heredoc_pattern ]]; then
            delimiter=${BASH_REMATCH[1]}
            heredoc_body_has_marker "$delimiter"
            heredoc_status=$?
            [[ $heredoc_status -eq 0 ]] && return 0
            [[ $heredoc_status -eq 1 ]] && heredoc_read=1
        fi
    fi

    if [[ $has_body_file -eq 1 ]]; then
        case "$body_file" in
        '' | -) DENY_DETAIL='--body-file に標準入力は使えない(フックが本文を読めない)。' ;;
        *'$'* | *'`'*) DENY_DETAIL='--body-file のパスに変数やコマンド置換がある(フックは展開前の文字列しか受け取れない)。' ;;
        '~'*) DENY_DETAIL='--body-file のパスがチルダで始まる(フックはチルダを展開できないので、展開済みの絶対パスを渡す)。' ;;
        /*)
            # 同じ呼び出しの heredoc が書くファイルは、フックの時点で無いか古いので、heredoc の本文を正とする。
            heredoc_file_has_marker "$body_file"
            heredoc_status=$?
            [[ $heredoc_status -eq 0 ]] && return 0
            if [[ $heredoc_status -eq 1 ]]; then
                DENY_DETAIL="本文ファイル $body_file を書く heredoc の本文にマーカーが無い。"
            elif [[ -r "$body_file" ]] && grep -qF -- "$MARKER" "$body_file"; then
                return 0
            else
                DENY_DETAIL="本文ファイル $body_file が読めないか、マーカーが無い。"
            fi
            ;;
        *) DENY_DETAIL='--body-file は絶対パスで渡す(cd が前に連結されているとフックから解決できない)。' ;;
        esac
    elif [[ $heredoc_read -eq 1 ]]; then
        DENY_DETAIL='本文にマーカーが無い(--body の heredoc の本文を読んだ)。'
    else
        case "$body_value" in
        *\$\(* | *'`'*)
            DENY_DETAIL='--body の値にコマンド置換があり、フックは置換の中の本文を読めないのでマーカーを確認できない(本文は --body-file で渡す)。'
            ;;
        *) DENY_DETAIL='本文にマーカーが無い。' ;;
        esac
    fi
    return 1
}

# reader_judges <コマンド文字列>: 読み切れたときだけ判定する。読み切れなければ判定せずに 0、deny なら 1 を返す。
reader_judges() {
    shell_reader_read "$1"
    if [[ $SHELL_READER_TOO_LONG -eq 1 || $SHELL_READER_SEP_IN_INPUT -eq 1 ||
        $SHELL_READER_UNCLOSED_QUOTE -eq 1 ]]; then
        return 0
    fi
    shell_reader_each_segment check_segment
}

# 全体を読み、続けて最後の heredoc の終端行より後ろだけを読み直す。全体の読み取りは heredoc の本文の
# apostrophe や長さで失敗しうるので、読み直しは全体の結果に依らず行う。
if reader_judges "$COMMAND"; then
    AFTER_HEREDOC=$(heredoc_tail)
    if [[ -z "$AFTER_HEREDOC" ]] || reader_judges "$AFTER_HEREDOC"; then
        exit 0
    fi
fi

command_guard_emit deny "issue-linkage-guard: ${DENY_DETAIL}\
 issue-linkage スキル(~/.claude/skills/issue-linkage/SKILL.md)の手順で本文を作り\
(関連 issue のメンション、relationship、PR なら Closes と AC 対応表)、末尾に <!-- issue-linkage --> を付ける。\
本文ファイルは git rev-parse --absolute-git-dir の出力の下の issue-linkage/ に置き、PR は gh pr create --body-file <絶対パス>、\
issue は bash ~/.claude/skills/issue-linkage/scripts/create-issue.sh --title <title> --body-file <絶対パス> で作る。"
exit 0
