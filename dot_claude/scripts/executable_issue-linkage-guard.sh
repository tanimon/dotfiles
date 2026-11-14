#!/usr/bin/env bash
# PreToolUse hook: 個人リポジトリでの `gh pr create` を、issue-linkage スキルの手順を経た本文(マーカー
# `<!-- issue-linkage -->` を含む)でなければ deny する。`gh issue create` は常に deny し、作成と native relationship の
# 設定を一度に行う create-issue.sh へ案内する(作成後の設定を別の手順にすると、それだけが漏れるため)。
# 設計: chezmoi リポジトリの spec #577。ガードを採った理由は同じリポジトリの
# docs/superpowers/specs/2026-10-04-ticket-skill-design.md
#
# 目的はスキルの起動忘れを防ぐことで、迂回を防ぐことではない(マーカーは手で書ける)。
# そのため reader が読み切れない範囲(長すぎる・引用符が閉じない・番兵の byte を含む)は判定せずに通す。読む範囲は
# コマンド全体と、最後の heredoc の終端行より後ろの 2 つで、全体を読み切れなくても後ろを読み切れれば後ろは判定する。
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
# (heredoc_tail)。本文の行は判定しない。本文を heredoc で上書きした直後の `gh pr create --body-file <絶対パス>` は、
# その heredoc がまだ書いていないので、ディスクではなくその本文にマーカーがあるかを見る(heredoc_file_has_marker)。
# 残存: 終端行が無い heredoc の後ろ、同じ行で heredoc 演算子の後ろに書いた作成コマンド(`cat <<EOF && gh pr create`)、
# heredoc が複数あるときに最後の終端行より前に書いた作成コマンドは判定しない。読み直した後ろが 8 KB を超える・引用符が
# 閉じないときも判定せずに通る。引用符の中の `<<` も heredoc 演算子と読むので、その後ろは本文とみなして判定しない。
# heredoc が本文ファイルを書くかは字面で読むので、`>` / `tee` 以外で書く形(`cp` など)はディスクのファイルを読み、
# 書いていない heredoc の本文を引用符の中の `;` などで取り違えることがある。--body の値の heredoc は生の COMMAND から
# 本文を読むが、`gh … create` の行より後ろで同じ区切り語を使う最初の heredoc を本文とみなすので、--body 以外の
# heredoc を先に書くと取り違える。`bash -c` の内側、`gh api` での作成、
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

# heredoc の演算子・区切り語・終端行の読み方は、この awk の関数だけに書く(heredoc を読む 3 つの関数が共有する)。
# heredoc_ops(line): line の heredoc 演算子を左から順に読み、区切り語を hd_word[k]、`<<-` かを hd_dash[k]、演算子の
# 位置を hd_pos[k] に入れて個数を返す。区切り語は bash と同じく、引用符と backslash を外した語(`<<'EOF-2'` は EOF-2)。
# `<<<`(here-string)は heredoc ではない。引用符の外かどうかは見ないので、引用符の中の `<<` も演算子として読む
# (その後ろを本文とみなし、判定が減る向きにだけ外れる)。
# heredoc_is_end(line, word, dash): line が区切り語 word の終端行か。行頭のタブを外すのは `<<-` のときだけ。
HEREDOC_AWK='
function heredoc_ops(line,    n, offset, word) {
    gsub(/<<</, "   ", line)
    n = 0
    offset = 0
    while (match(line, /<<-?[ \t]*(\047[^\047]*\047|"[^"]*"|[^ \t;&|<>()\047"]+)/)) {
        word = substr(line, RSTART, RLENGTH)
        n++
        hd_pos[n] = offset + RSTART
        hd_dash[n] = (substr(word, 3, 1) == "-")
        sub(/^<<-?[ \t]*/, "", word)
        gsub(/[\047"\\]/, "", word)
        hd_word[n] = word
        offset += RSTART + RLENGTH - 1
        line = substr(line, RSTART + RLENGTH)
    }
    return n
}
function heredoc_is_end(line, word, dash) {
    if (dash) sub(/^\t+/, "", line)
    return line == word
}
'

# heredoc_tail: COMMAND の最後の heredoc の終端行より後ろを出力する。heredoc が無い、または最後の heredoc に終端行が
# 無い(以降がすべて本文)ときは何も出さない。reader は heredoc の本文を読まないので、本文の後ろに書かれた
# 作成コマンドはここで切り出して読み直す。本文の行は対象に入れない。
heredoc_tail() {
    LC_ALL=C awk "$HEREDOC_AWK"'
        BEGIN { first = 1; last = 0 }
        first <= last {
            if (heredoc_is_end($0, word[first], dash[first]) && ++first > last) { seen = 1; buf = "" }
            next
        }
        {
            buf = buf $0 "\n"
            n = heredoc_ops($0)
            for (k = 1; k <= n; k++) { word[++last] = hd_word[k]; dash[last] = hd_dash[k] }
        }
        END { if (seen && first > last) printf "%s", buf }' <<<"$COMMAND"
}

# heredoc_file_has_marker <絶対パス>: COMMAND の heredoc のうち、<絶対パス> に上書きで書くもの(演算子と同じコマンドに
# `> <絶対パス>` / `>| <絶対パス>`、またはパイプの先の `tee <絶対パス>` があるもの)の最後の本文にマーカーがあれば 0、
# 無ければ 1、そういう heredoc が無ければ 2 を返す。本文ファイルを同じ Bash 呼び出しの heredoc で書くとき、フックの
# 時点ではファイルがまだ無いか古いので、ディスクではなく heredoc の本文を読む。追記(`>>`)や `tee -a`、読むだけの
# 引数はディスクのファイルを読ませる(2 を返す)。コマンドの区切りは `;` / `&&` / `||` で、引用符の中の区切りも区切りと読む。
heredoc_file_has_marker() {
    HEREDOC_PATH=$1 LC_ALL=C awk -v marker="$MARKER" "$HEREDOC_AWK"'
        # command_around(line, pos): line の pos を含むコマンド(パイプでつないだ先まで)。
        function command_around(line, pos,    i, c, from, to) {
            from = 1
            to = length(line)
            for (i = pos - 1; i >= 1; i--) {
                c = substr(line, i, 1)
                if (c == ";" || ((c == "&" || c == "|") && substr(line, i - 1, 1) == c)) { from = i + 1; break }
            }
            for (i = pos; i <= length(line); i++) {
                c = substr(line, i, 1)
                if (c == ";" || ((c == "&" || c == "|") && substr(line, i + 1, 1) == c)) { to = i - 1; break }
            }
            return substr(line, from, to - from + 1)
        }
        function overwrites_path(command,    p, head, rest) {
            head = ""
            rest = command
            while ((p = index(rest, path)) > 0) {
                head = head substr(rest, 1, p - 1)
                rest = substr(rest, p + length(path))
                if (substr(rest, 1, 1) !~ /[A-Za-z0-9_.\/-]/) {
                    sub(/[\047"]$/, "", head)
                    if (head ~ /(^|[^>])>\|?[ \t]*$/ || head ~ /(^|[ \t|])tee[ \t]+$/) return 1
                }
                head = head path
            }
            return 0
        }
        BEGIN { path = ENVIRON["HEREDOC_PATH"]; res = 2; first = 1; last = 0 }
        first <= last {
            if (heredoc_is_end($0, word[first], dash[first])) {
                if (target[first]) res = found[first] ? 0 : 1
                first++
            } else if (index($0, marker)) found[first] = 1
            next
        }
        {
            n = heredoc_ops($0)
            for (k = 1; k <= n; k++) {
                word[++last] = hd_word[k]
                dash[last] = hd_dash[k]
                target[last] = overwrites_path(command_around($0, hd_pos[k]))
            }
        }
        END { exit res }' <<<"$COMMAND"
}

# heredoc_body_has_marker <--body の値>: 値の中の最初の heredoc の区切り語を読み、COMMAND の中で `gh … create` の後に
# 始まる最初の、その区切り語の heredoc の本文にマーカーがあれば 0、本文を読めてマーカーが無ければ 1、値に heredoc が
# 無いかその heredoc が見つからなければ 2 を返す。--body "$(cat <<'EOF' … EOF)" の本文に空白を含む二重引用符
# (See "foo bar" here)があると、reader は外側の "…" を内側の " で閉じたと読んで token を分けるので、
# マーカーが --body の値の token に入らない。そのときは token ではなく生の COMMAND から本文を読む。
heredoc_body_has_marker() {
    HEREDOC_BODY_VALUE=$1 LC_ALL=C awk -v marker="$MARKER" "$HEREDOC_AWK"'
        BEGIN {
            if (heredoc_ops(ENVIRON["HEREDOC_BODY_VALUE"]) == 0) { state = 3; exit }
            delimiter = hd_word[1]
        }
        state == 0 && /gh[ \t].*(create|new)/ { state = 1 }
        state == 1 {
            n = heredoc_ops($0)
            for (k = 1; k <= n; k++) if (hd_word[k] == delimiter) { dash = hd_dash[k]; state = 2; next }
        }
        state == 2 {
            if (heredoc_is_end($0, delimiter, dash)) exit
            if (index($0, marker)) { found = 1; exit }
        }
        END { exit found ? 0 : (state == 2 ? 1 : 2) }' <<<"$COMMAND"
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

    local repo='' body_file='' has_body_file=0 body_value='' has_body=0 argument
    local heredoc_read=0 heredoc_status
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
        heredoc_body_has_marker "$body_value"
        heredoc_status=$?
        [[ $heredoc_status -eq 0 ]] && return 0
        [[ $heredoc_status -eq 1 ]] && heredoc_read=1
    fi

    if [[ $has_body_file -eq 1 ]]; then
        case "$body_file" in
        '' | -) DENY_DETAIL='--body-file に標準入力は使えない(フックが本文を読めない)。' ;;
        *'$'* | *'`'*) DENY_DETAIL='--body-file のパスに変数やコマンド置換がある(フックは展開前の文字列しか受け取れない)。' ;;
        '~'*) DENY_DETAIL='--body-file のパスがチルダで始まる(フックはチルダを展開できないので、展開済みの絶対パスを渡す)。' ;;
        /*)
            # 同じ呼び出しの heredoc が書くファイルは、フックの時点で無いか古いので、heredoc の本文を正とする。
            # 全体を読む判定の作成コマンドは最初の heredoc 演算子より前にあり、heredoc はその後で書くので、
            # heredoc の本文を見るのは終端行の後ろを読み直すときだけ。
            heredoc_status=2
            if [[ $READING_HEREDOC_TAIL -eq 1 ]]; then
                heredoc_file_has_marker "$body_file"
                heredoc_status=$?
            fi
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
READING_HEREDOC_TAIL=0
if reader_judges "$COMMAND"; then
    READING_HEREDOC_TAIL=1
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
