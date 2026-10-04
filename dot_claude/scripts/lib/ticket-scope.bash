#!/usr/bin/env bash
# ticket スキルとガードの適用範囲を判定する。範囲は origin の owner の許可リストで決める。
# source して ticket_scope_in_scope を呼ぶか、直接実行して終了コードを見る
# (bash ticket-scope.bash <dir> [<repo>])。
#
# 許可リストは TICKET_GUARD_OWNERS(空白区切り)。既定値に書くのは公開済みの個人アカウント名だけ。
# 仕事 org の除外リストにしないのは、org 名を public リポジトリに書けないうえ、OSS への PR まで
# 範囲に入ってしまうため。

# ticket_scope_in_scope <dir> [<repo>]: 範囲内なら 0、範囲外・判定不能なら 1。
# <repo> は owner/name・github.com/owner/name・https://github.com/owner/name。空なら <dir> の origin を見る。
ticket_scope_in_scope() {
    local dir=${1:-.} repo=${2:-} url owner allowed
    if [[ -z "$repo" ]]; then
        url=$(git -C "$dir" remote get-url origin 2>/dev/null) || return 1
        case "$url" in
        https://github.com/*) repo=${url#https://github.com/} ;;
        git@github.com:*) repo=${url#git@github.com:} ;;
        ssh://git@github.com/*) repo=${url#ssh://git@github.com/} ;;
        *) return 1 ;;
        esac
    else
        repo=${repo#https://}
        repo=${repo#github.com/}
    fi
    owner=${repo%%/*}
    [[ -n "$owner" && "$owner" != "$repo" ]] || return 1
    owner=$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')
    for allowed in ${TICKET_GUARD_OWNERS-tanimon}; do
        allowed=$(printf '%s' "$allowed" | tr '[:upper:]' '[:lower:]')
        [[ "$owner" == "$allowed" ]] && return 0
    done
    return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    ticket_scope_in_scope "${1:-.}" "${2:-}"
    exit $?
fi
