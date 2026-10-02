#!/usr/bin/env bash
# コードコメントのうち、機械的に判定できる種類のノイズを検出する。
# 規約の正本はルールファイル(RULE_FILE)で、ここには判定だけを置く。
set -euo pipefail
# トークン分割で glob 展開させない
set -f
# 判定をロケールに依存させない(マルチバイト文字はバイト列として扱う)
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ALLOWLIST_FILE="${COMMENT_NOISE_ALLOWLIST:-${SCRIPT_DIR}/comment-noise-allowlist.txt}"
RULE_FILE="dot_claude/rules/common/code-comments.md"

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

PLAN_STEP_RE='(^|[^A-Za-z])(Task|Step) [0-9]+'
# 番号と動詞の間は 24 バイトまで(LC_ALL=C なので日本語は 1 文字 3 バイト)
ISSUE_ORIGIN_JA_RE='#[0-9]+[^#]{0,24}(で発覚|で追加|で導入|で修正|で判明)'
ISSUE_ORIGIN_EN_RE='(added|introduced|found|fixed) in #[0-9]+'

# Markdown・docs は経緯の記録が正当な場合が多く、JSON はコメントを持たない
is_excluded() {
    case $1 in
    *.md | docs/* | *.json | pnpm-lock.yaml) return 0 ;;
    esac
    return 1
}

# 許可リストの、コメント行と空行を除いた行を出す。ファイルが無ければ何も出さない
read_allowlist() {
    local line
    [[ -f $ALLOWLIST_FILE ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line =~ ^[[:space:]]*# ]] && continue
        [[ -z ${line//[[:space:]]/} ]] && continue
        printf '%s\n' "$line"
    done <"$ALLOWLIST_FILE"
}
ALLOW_ENTRIES="$(read_allowlist)"

# 許可リストの各行は <path-suffix or *>:<regex>
is_allowed() {
    local file=$1 text=$2 entry suffix regex status
    [[ -n $ALLOW_ENTRIES ]] || return 1
    while IFS= read -r entry; do
        suffix=${entry%%:*}
        regex=${entry#*:}
        [[ $suffix == '*' || $file == *"$suffix" ]] || continue
        status=0
        # $? は =~ の結果(0 一致 / 1 不一致 / 2 不正な正規表現)をそのまま拾う
        # shellcheck disable=SC2319
        [[ $text =~ $regex ]] || status=$?
        if ((status == 0)); then
            return 0
        elif ((status == 2)); then
            printf 'error: invalid regex in %s: %s\n' "$ALLOWLIST_FILE" "$entry" >&2
            exit 2
        fi
    done <<<"$ALLOW_ENTRIES"
    return 1
}

# git 管理下のトップレベルのディレクトリ。先頭の要素がこれと一致するトークンだけを
# リポジトリ内のパスとみなす(~/ で始まる配置先のパスや、ファイルからの相対パスを避ける)
TOP_DIRS="$(git ls-files | grep / | cut -d/ -f1 | sort -u || true)"

is_top_dir() {
    case $'\n'"$TOP_DIRS"$'\n' in
    *$'\n'"$1"$'\n'*) return 0 ;;
    esac
    return 1
}

violations=0

report() {
    local file=$1 lineno=$2 pattern=$3 text=$4
    is_allowed "$file" "$text" && return 0
    printf '%s:%s: [%s] %s\n' "$file" "$lineno" "$pattern" "$text"
    violations=$((violations + 1))
}

check_paths() {
    local file=$1 lineno=$2 text=$3 tokens token
    # パスに使う文字以外を区切りにする。:行番号・#アンカー・括弧・句読点・CR はここで落ちる
    tokens=$(printf '%s' "$text" | sed 's#[^A-Za-z0-9_./~{}<>*$-]# #g')
    for token in $tokens; do
        while [[ $token == *. ]]; do token=${token%.}; done
        [[ $token == */* ]] || continue
        case $token in *'{'* | *'}'* | *'<'* | *'>'* | *'*'* | *'$'*) continue ;; esac
        is_top_dir "${token%%/*}" || continue
        [[ -e $token ]] && continue
        # gitignore されたパス(ローカルにだけ置くファイル)は、無いのが正常
        git check-ignore -q --no-index -- "$token" && continue
        report "$file" "$lineno" missing-path "$text"
    done
}

check_line() {
    local file=$1 lineno=$2 text=$3
    if [[ $text =~ $PLAN_STEP_RE ]]; then
        report "$file" "$lineno" plan-step "$text"
    fi
    if [[ $text =~ $ISSUE_ORIGIN_JA_RE || $text =~ $ISSUE_ORIGIN_EN_RE ]]; then
        report "$file" "$lineno" issue-origin "$text"
    fi
    check_paths "$file" "$lineno" "$text"
}

while IFS= read -r -d '' file; do
    is_excluded "$file" && continue
    [[ -f $file ]] || continue
    while IFS= read -r hit; do
        lineno=${hit%%:*}
        text=${hit#*:}
        [[ $lineno == 1 && $text == '#!'* ]] && continue
        check_line "$file" "$lineno" "$text"
    done < <(grep -InE '^[[:space:]]*(#|//)' -- "$file" || true)
done < <(git ls-files -z)

if ((violations > 0)); then
    printf '\n%d 件のコメントが規約に反しています。規約: %s\n' "$violations" "$RULE_FILE" >&2
    printf '残すべきものは %s に <path-suffix or *>:<regex> で追加してください。\n' "$ALLOWLIST_FILE" >&2
    exit 1
fi
