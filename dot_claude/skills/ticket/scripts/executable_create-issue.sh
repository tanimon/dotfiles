#!/usr/bin/env bash
# issue を作り、本文の `## Parent` / `## Blocked by` に書いた関係を native の sub-issue と依存関係にも張る。
# 作成と設定を 1 つにしているのは、作成後の設定を別の手順にするとそれだけが漏れるため(本文は正しいのに
# native が未設定、という形)。このスクリプト内の gh は ticket-guard の対象にならない。
#
# 使い方: create-issue.sh --title <title> --body-file <絶対パス> [gh issue create に渡すその他の引数...]
# 終了コード: 0 成功 / 1 issue は作ったが relationship の一部を張れなかった / 2 引数か本文の不備(何も作らない)
set -uo pipefail
export LC_ALL=C

MARKER='<!-- ticket-skill -->'

# shellcheck source=dot_claude/skills/ticket/scripts/sections.bash
source "$(dirname "${BASH_SOURCE[0]}")/sections.bash"

body_file=''
previous=''
for argument in "$@"; do
    # 値を取るオプションの値は、オプションとして読まない(タイトルは自由記述で `-F…` のように始まりうる)。
    case "$previous" in
    -F | --body-file | -t | --title)
        [[ "$previous" == -F || "$previous" == --body-file ]] && body_file=$argument
        previous=''
        continue
        ;;
    esac
    case "$argument" in
    --body-file=*) body_file=${argument#--body-file=} ;;
    # gh(pflag)は短いオプションに値を続けた -F<path> / -F=<path> も受け付ける。
    -F?*)
        body_file=${argument#-F}
        body_file=${body_file#=}
        ;;
    # --web は issue を作らずブラウザを開くだけで URL を出さないので、relationship を張れない。
    -w | --web)
        echo 'create-issue.sh: --web は使えない(issue の URL が得られず relationship を張れない)' >&2
        exit 2
        ;;
    esac
    previous=$argument
done

case "$body_file" in
/*) ;;
'')
    echo 'create-issue.sh: --body-file <絶対パス> が必要' >&2
    exit 2
    ;;
*)
    echo "create-issue.sh: --body-file は絶対パスで渡す: $body_file" >&2
    exit 2
    ;;
esac
if [[ ! -r "$body_file" ]] || ! grep -qF -- "$MARKER" "$body_file"; then
    echo "create-issue.sh: 本文ファイルが読めないか、マーカー $MARKER が無い(ticket スキルの作成モードで本文を作る): $body_file" >&2
    exit 2
fi

url=$(gh issue create "$@") || exit 2
url=$(printf '%s\n' "$url" | tail -n 1)
printf '%s\n' "$url"

# 親は 1 つしか持てない(2 件目の POST は API が拒否する)ので、書かれた順の先頭 1 件だけを張る。
all_parents=$(section_refs '^#+[ \t]+parent' <"$body_file" | awk '!seen[$0]++')
parents=$(printf '%s\n' "$all_parents" | head -n 1)
if [[ $(printf '%s\n' "$all_parents" | grep -c .) -gt 1 ]]; then
    echo "create-issue.sh: Parent 節の #N は先頭の #$parents だけを親にした(親は 1 つしか持てない)" >&2
fi
blockers=$(section_refs '^#+[ \t]+blocked by' <"$body_file" | sort -un)
[[ -n "$parents$blockers" ]] || exit 0

# relationship は作成した issue と同じリポジトリに張る。-R / --repo で cwd 以外に作ることがあるので、
# repo は cwd からではなく gh issue create が返した URL から取る。
if [[ ! "$url" =~ ^https://[^/]+/([^/]+/[^/]+)/issues/([0-9]+)$ ]]; then
    echo "create-issue.sh: gh issue create の出力が issue の URL ではないので relationship を張れなかった: $url" >&2
    exit 1
fi
repo=${BASH_REMATCH[1]}
number=${BASH_REMATCH[2]}
failed=''
id=$(gh api "repos/$repo/issues/$number" | jq -r .id) || failed+=' id'
if [[ -z "$failed" ]]; then
    for parent in $parents; do
        gh api "repos/$repo/issues/$parent/sub_issues" -X POST -F "sub_issue_id=$id" >/dev/null ||
            failed+=" parent #$parent"
    done
    for blocker in $blockers; do
        blocker_id=$(gh api "repos/$repo/issues/$blocker" | jq -r .id) &&
            gh api "repos/$repo/issues/$number/dependencies/blocked_by" -X POST -F "issue_id=$blocker_id" >/dev/null ||
            failed+=" blocked-by #$blocker"
    done
fi
if [[ -n "$failed" ]]; then
    echo "create-issue.sh: $url は作成済み。次の relationship を張れなかった(ticket スキルの作成モード手順3のコマンドで張り直す):$failed" >&2
    exit 1
fi
