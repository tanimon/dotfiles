#!/usr/bin/env bash
# ticket スキルの照合モードの検出部分。カレントのリポジトリの issue と PR の食い違いを、
# 1 行 1 件のタブ区切り「<kind> <issue 番号> <根拠>」で出す。書き込みはしない。
#   parent-missing      本文の Parent 節にある親が、API の parent と違う
#   blocked-by-missing  本文の Blocked by 節にある blocker が、API の dependencies に無い
#   open-after-merge    マージ済み PR の closingIssuesReferences にある issue が open のまま
#   ac-unchecked        PR で close された issue の AC 節に [ ] が残る(1 項目 1 行)
#   mentioned-by-merged open の issue に同じリポジトリのマージ済み PR からの言及がある(Closes の書き忘れの候補。
#                       言及は解決を意味しないので、close するかは人が決める)
# 件数の上限は TICKET_AUDIT_LIMIT(既定 100)。gh の --jq は使わず jq に渡す(テストで gh をスタブにするため)。
set -euo pipefail
export LC_ALL=C

LIMIT=${TICKET_AUDIT_LIMIT:-100}

# shellcheck source=dot_claude/skills/ticket/scripts/sections.bash
source "$(dirname "${BASH_SOURCE[0]}")/sections.bash"

repo=$(gh repo view --json nameWithOwner | jq -r .nameWithOwner)
open_json=$(gh issue list --state open --limit "$LIMIT" --json number,body)
open_numbers=$(printf '%s' "$open_json" | jq -r '.[].number')

# relationship
items=$(printf '%s' "$open_json" | jq -c '.[]')
while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    number=$(printf '%s' "$item" | jq -r .number)
    body=$(printf '%s' "$item" | jq -r '.body // ""')
    parents=$(printf '%s\n' "$body" | section_refs '^#+[ \t]+parent')
    blockers=$(printf '%s\n' "$body" | section_refs '^#+[ \t]+blocked by')
    if [[ -n "$parents" ]]; then
        actual=$(gh api "repos/$repo/issues/$number" | jq -r '.parent_issue_url // ""')
        actual=${actual##*/}
        for parent in $parents; do
            if [[ "$parent" != "$actual" ]]; then
                printf 'parent-missing\t%s\t#%s\n' "$number" "$parent"
            fi
        done
    fi
    if [[ -n "$blockers" ]]; then
        actual=$(gh api "repos/$repo/issues/$number/dependencies/blocked_by" | jq -r '.[].number')
        for blocker in $blockers; do
            if ! printf '%s\n' "$actual" | grep -qx "$blocker"; then
                printf 'blocked-by-missing\t%s\t#%s\n' "$number" "$blocker"
            fi
        done
    fi
done <<<"$items"

# open-after-merge
references=$(gh pr list --state merged --limit "$LIMIT" --json number,closingIssuesReferences |
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
    mentions=$(gh api "repos/$repo/issues/$number/timeline" --paginate |
        jq -r --arg repo "$repo" '.[] | select(.event == "cross-referenced") | .source.issue // empty
            | select(.pull_request.merged_at != null)
            | select((.repository.full_name // "") == $repo)
            | .number' | sort -un)
    for pr in $mentions; do
        printf 'mentioned-by-merged\t%s\tPR #%s\n' "$number" "$pr"
    done
done

# ac-unchecked
closed=$(gh issue list --state closed --limit "$LIMIT" --json number,body,closedByPullRequestsReferences |
    jq -c '.[] | select((.closedByPullRequestsReferences | length) > 0)
        | {number, body: (.body // ""), pr: .closedByPullRequestsReferences[0].number}')
while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    number=$(printf '%s' "$item" | jq -r .number)
    pr=$(printf '%s' "$item" | jq -r .pr)
    printf '%s' "$item" | jq -r .body |
        unchecked_items '^#+[ \t]+(acceptance criteria|完了条件)' |
        while IFS= read -r text; do
            printf 'ac-unchecked\t%s\tPR #%s: %s\n' "$number" "$pr" "$text"
        done
done <<<"$closed"
