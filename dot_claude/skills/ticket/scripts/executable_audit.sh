#!/usr/bin/env bash
# ticket スキルの照合モードの検出部分。カレントのリポジトリの issue と PR の食い違いを、
# 1 行 1 件のタブ区切り「<kind> <issue 番号> <根拠>」で出す。書き込みはしない。
#   parent-missing      本文の Parent 節の先頭の親が、API では未設定(親は 1 つしか持てないので先頭だけを見る。
#                       create-issue.sh も先頭だけを張る)
#   parent-mismatch     本文の Parent 節の先頭の親と、API に設定済みの別の親が食い違う(根拠は API 側の親。別リポジトリの親なら owner/repo#N)
#   blocked-by-missing  本文の Blocked by 節にある blocker が、API の dependencies に無い
#   open-after-merge    マージ済み PR の closingIssuesReferences にある issue が open のまま
#   ac-unchecked        マージ済みの PR で close された issue の AC 節に [ ] が残る(1 項目 1 行。根拠はマージ済みの PR だけ)
#   mentioned-by-merged open の issue に同じリポジトリのマージ済み PR からの言及がある(Closes の書き忘れの候補。
#                       言及は解決を意味しないので、close するかは人が決める)
# 件数の上限は TICKET_AUDIT_LIMIT(既定 100)。取得件数が上限に達した一覧があれば stderr に 1 行知らせる(stdout は変えない)。gh の --jq は使わず jq に渡す(テストで gh をスタブにするため)。
# issue 単位の API 呼び出しが失敗しても、stderr に出して残りを続け、最後に 1 で終わる(途中で止めると、
# 部分的な出力が全件に見えるため)。一覧の取得の失敗はその場で終わる。
set -euo pipefail
export LC_ALL=C

LIMIT=${TICKET_AUDIT_LIMIT:-100}
FAILED=0

# api_failed <issue 番号> <何を>: issue 単位の失敗を stderr に出し、終了コードを 1 にする印を付ける。
api_failed() {
    echo "audit.sh: #$1 の $2 を取得できなかったので、この issue のその検査を飛ばした" >&2
    FAILED=1
}

# shellcheck source=dot_claude/skills/ticket/scripts/sections.bash
source "$(dirname "${BASH_SOURCE[0]}")/sections.bash"

# warn_if_limit_reached <対象> <件数>: 件数が上限に等しければ、古いものを見ていない可能性を stderr に出す。
warn_if_limit_reached() {
    if [[ "$2" -eq "$LIMIT" ]]; then
        echo "audit.sh: $1 が上限 $LIMIT 件に達した。TICKET_AUDIT_LIMIT を上げて再実行すると古いものも見る" >&2
    fi
}

repo=$(gh repo view --json nameWithOwner | jq -r .nameWithOwner)
open_json=$(gh issue list --state open --limit "$LIMIT" --json number,body)
warn_if_limit_reached "open の issue" "$(printf '%s' "$open_json" | jq 'length')"
open_numbers=$(printf '%s' "$open_json" | jq -r '.[].number')

# relationship。open の issue だけを見る(close 済みの relationship は作業の順序に効かず、issue ごとに API を呼ぶので
# 対象を広げると件数に比例して遅くなる)。
items=$(printf '%s' "$open_json" | jq -c '.[]')
while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    number=$(printf '%s' "$item" | jq -r .number)
    body=$(printf '%s' "$item" | jq -r '.body // ""')
    parents=$(printf '%s\n' "$body" | section_refs '^#+[ \t]+parent')
    blockers=$(printf '%s\n' "$body" | section_refs '^#+[ \t]+blocked by')
    parent=$(printf '%s\n' "$parents" | head -n 1)
    if [[ -n "$parent" ]]; then
        # 本文の #N は同じリポジトリの番号なので、API の親は番号だけでなくリポジトリも比べる。
        # 別リポジトリの親は owner/repo#N で出す(番号だけでは同じリポジトリの #N と区別できない)。
        if actual=$(gh api "repos/$repo/issues/$number" | jq -r --arg repo "$repo" '.parent_issue_url // ""
            | if . == "" then "" else (split("/") | (.[-4:-2] | join("/")) as $owner_repo
                | if $owner_repo == $repo then "#" + .[-1] else $owner_repo + "#" + .[-1] end) end'); then
            if [[ -z "$actual" ]]; then
                printf 'parent-missing\t%s\t#%s\n' "$number" "$parent"
            elif [[ "#$parent" != "$actual" ]]; then
                printf 'parent-mismatch\t%s\t#%s(本文) / %s(API)\n' "$number" "$parent" "$actual"
            fi
        else
            api_failed "$number" parent
        fi
    fi
    if [[ -n "$blockers" ]]; then
        # 別リポジトリの blocker は本文の #N と番号が一致しても同じ issue ではないので、同じリポジトリのものだけを比べる。
        if ! actual=$(gh api "repos/$repo/issues/$number/dependencies/blocked_by" --paginate |
            jq -r --arg repo "$repo" '.[] | select((.repository_url // "") | endswith("/repos/" + $repo)) | .number'); then
            api_failed "$number" dependencies
            continue
        fi
        for blocker in $blockers; do
            if ! printf '%s\n' "$actual" | grep -qx "$blocker"; then
                printf 'blocked-by-missing\t%s\t#%s\n' "$number" "$blocker"
            fi
        done
    fi
done <<<"$items"

# open-after-merge
merged_json=$(gh pr list --state merged --limit "$LIMIT" --json number,closingIssuesReferences)
warn_if_limit_reached "マージ済みの PR" "$(printf '%s' "$merged_json" | jq 'length')"
references=$(printf '%s' "$merged_json" |
    jq -r --arg repo "$repo" '.[] | .number as $pr | .closingIssuesReferences[]
        | select((.url | split("/")[3:5] | join("/")) == $repo)
        | "\(.number)\t\($pr)"')
after_merge=''
while IFS=$'\t' read -r issue pr; do
    [[ -n "$issue" ]] || continue
    if printf '%s\n' "$open_numbers" | grep -qx "$issue"; then
        printf 'open-after-merge\t%s\tPR #%s\n' "$issue" "$pr"
        after_merge+="$issue"$'\n'
    fi
done <<<"$references"

# mentioned-by-merged
for number in $open_numbers; do
    if printf '%s' "$after_merge" | grep -qx "$number"; then
        continue
    fi
    if ! mentions=$(gh api "repos/$repo/issues/$number/timeline" --paginate |
        jq -r --arg repo "$repo" '.[] | select(.event == "cross-referenced") | .source.issue // empty
            | select(.pull_request.merged_at != null)
            | select((.repository.full_name // "") == $repo)
            | .number' | sort -un); then
        api_failed "$number" timeline
        continue
    fi
    for pr in $mentions; do
        printf 'mentioned-by-merged\t%s\tPR #%s\n' "$number" "$pr"
    done
done

# ac-unchecked
closed_json=$(gh issue list --state closed --limit "$LIMIT" --json number,body,closedByPullRequestsReferences)
warn_if_limit_reached "close 済みの issue" "$(printf '%s' "$closed_json" | jq 'length')"
closed=$(printf '%s' "$closed_json" |
    jq -c '.[] | select((.closedByPullRequestsReferences | length) > 0)
        | {number, body: (.body // ""),
           prs: [.closedByPullRequestsReferences[] | {number, ref: (.url // (.number | tostring))}]}')
while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    number=$(printf '%s' "$item" | jq -r .number)
    unchecked=$(printf '%s' "$item" | jq -r .body | unchecked_items '^#+[ \t]+(acceptance criteria|完了条件)')
    [[ -n "$unchecked" ]] || continue
    # closedByPullRequestsReferences は PR の state を持たず、未マージ(open)の PR も含みうるので、
    # 根拠にするのはマージ済みの PR だけにする。state は [ ] が残る issue の PR についてだけ引く。
    # close した PR が複数あれば、AC の対応表がどれにあってもよいように、マージ済みの全件を根拠に出す。
    prs=''
    pr_failed=0
    while IFS=$'\t' read -r pr ref; do
        if ! state=$(gh pr view "$ref" --json state </dev/null | jq -r .state); then
            pr_failed=1
            continue
        fi
        if [[ "$state" == MERGED ]]; then
            prs+="${prs:+, }PR #$pr"
        fi
    done < <(printf '%s' "$item" | jq -r '.prs[] | "\(.number)\t\(.ref)"')
    if [[ $pr_failed -eq 1 ]]; then
        api_failed "$number" "close した PR の state"
        continue
    fi
    [[ -n "$prs" ]] || continue
    while IFS= read -r text; do
        printf 'ac-unchecked\t%s\t%s: %s\n' "$number" "$prs" "$text"
    done <<<"$unchecked"
done <<<"$closed"

exit "$FAILED"
