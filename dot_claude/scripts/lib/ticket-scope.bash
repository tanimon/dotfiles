#!/usr/bin/env bash
# ticket スキルとガードの適用範囲を判定する。範囲は、gh が作成先にするリポジトリの owner の許可リストで決める。
# source して ticket_scope_in_scope を呼ぶか、直接実行して終了コードを見る
# (bash ticket-scope.bash <dir> [<repo>])。
#
# 許可リストは TICKET_GUARD_OWNERS(空白区切り)。既定値に書くのは公開済みの個人アカウント名だけ。
# 仕事 org の除外リストにしないのは、org 名を public リポジトリに書けないうえ、OSS への PR まで
# 範囲に入ってしまうため。
#
# <repo> が無いときは、origin が GitHub の remote であることを前提条件にし(無い・GitHub 以外なら範囲外)、
# 作成先は gh が非対話で選ぶ base repo に合わせる(gh の context.ResolvedRemotes.BaseRepo)。
# `gh repo set-default` が書く remote.<name>.gh-resolved(値が base ならその remote、owner/repo ならそのリポジトリ)を優先し、
# 無ければ GitHub の remote を upstream > github > origin > その他 の順で選ぶ。origin だけを見ると、許可リストの
# owner の下にある OSS の fork の clone から upstream へ PR を作る場合まで範囲に入る。

# _ticket_scope_repo_from_url <url>: GitHub の remote URL を owner/name にして出す。GitHub 以外なら 1。
_ticket_scope_repo_from_url() {
    case "$1" in
    https://github.com/*) printf '%s' "${1#https://github.com/}" ;;
    git@github.com:*) printf '%s' "${1#git@github.com:}" ;;
    ssh://git@github.com/*) printf '%s' "${1#ssh://git@github.com/}" ;;
    *) return 1 ;;
    esac
}

# _ticket_scope_default_repo <dir>: gh が既定にする作成先を owner/name で出す。決められなければ 1。
_ticket_scope_default_repo() {
    local dir=$1 key value name url repo best='' best_score=-1 score
    url=$(git -C "$dir" remote get-url origin 2>/dev/null) || return 1
    _ticket_scope_repo_from_url "$url" >/dev/null || return 1
    while read -r key value; do
        name=${key#remote.}
        name=${name%.gh-resolved}
        if [[ "$value" == base ]]; then
            url=$(git -C "$dir" remote get-url "$name" 2>/dev/null) || return 1
            _ticket_scope_repo_from_url "$url"
            return
        elif [[ -n "$value" ]]; then
            # 値は OWNER/REPO か HOST/OWNER/REPO。GitHub 以外のホストなら範囲外。
            case "$value" in
            github.com/*) value=${value#github.com/} ;;
            */*/*) return 1 ;;
            esac
            printf '%s' "$value"
            return 0
        fi
    done < <(git -C "$dir" config --get-regexp '^remote\..*\.gh-resolved$' 2>/dev/null)
    for name in $(git -C "$dir" remote 2>/dev/null); do
        url=$(git -C "$dir" remote get-url "$name" 2>/dev/null) || continue
        repo=$(_ticket_scope_repo_from_url "$url") || continue
        case "$name" in
        upstream) score=3 ;;
        github) score=2 ;;
        origin) score=1 ;;
        *) score=0 ;;
        esac
        if [[ $score -gt $best_score ]]; then
            best=$repo
            best_score=$score
        fi
    done
    [[ -n "$best" ]] || return 1
    printf '%s' "$best"
}

# ticket_scope_in_scope <dir> [<repo>]: 範囲内なら 0、範囲外・判定不能なら 1。
# <repo> は owner/name・github.com/owner/name・https://github.com/owner/name。空なら <dir> の remote から gh の既定の作成先を求める。
ticket_scope_in_scope() {
    local dir=${1:-.} repo=${2:-} owner allowed
    if [[ -z "$repo" ]]; then
        repo=$(_ticket_scope_default_repo "$dir") || return 1
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
