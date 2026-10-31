#!/usr/bin/env bash
# issue-linkage スキルとガードの適用範囲を判定する。範囲は、gh が作成先にするリポジトリの owner の許可リストで決める。
# source して issue_linkage_scope_in_scope を呼ぶか、直接実行して終了コードを見る
# (bash issue-linkage-scope.bash <dir> [<repo>])。作成先の -R / --repo は issue_linkage_scope_repo_flag で読む
# (ガードと create-issue.sh が同じ読み方をするため)。
#
# 許可リストは ISSUE_LINKAGE_GUARD_OWNERS(空白区切り)。既定値に書くのは公開済みの個人アカウント名だけ。
# 仕事 org の除外リストにしないのは、org 名を public リポジトリに書けないうえ、OSS への PR まで
# 範囲に入ってしまうため。
#
# <repo> が無いときは、origin が GitHub の remote であることを前提条件にし(無い・GitHub 以外なら範囲外)、
# 作成先は gh が非対話で選ぶ base repo に合わせる(gh の context.ResolvedRemotes.BaseRepo)。
# `gh repo set-default` が書く remote.<name>.gh-resolved(値が base ならその remote、owner/repo ならそのリポジトリ)を優先し、
# 無ければ GitHub の remote を upstream > github > origin > その他 の順で選ぶ。origin だけを見ると、許可リストの
# owner の下にある OSS の fork の clone から upstream へ PR を作る場合まで範囲に入る。

# _issue_linkage_scope_repo_from_url <url>: GitHub の remote URL を owner/name にして出す。GitHub 以外なら 1。
_issue_linkage_scope_repo_from_url() {
    case "$1" in
    https://github.com/*) printf '%s' "${1#https://github.com/}" ;;
    git@github.com:*) printf '%s' "${1#git@github.com:}" ;;
    ssh://git@github.com/*) printf '%s' "${1#ssh://git@github.com/}" ;;
    *) return 1 ;;
    esac
}

# _issue_linkage_scope_default_repo <dir>: gh が既定にする作成先を owner/name で出す。決められなければ 1。
_issue_linkage_scope_default_repo() {
    local dir=$1 key value name url repo best='' best_score=-1 score
    url=$(git -C "$dir" remote get-url origin 2>/dev/null) || return 1
    _issue_linkage_scope_repo_from_url "$url" >/dev/null || return 1
    while read -r key value; do
        name=${key#remote.}
        name=${name%.gh-resolved}
        if [[ "$value" == base ]]; then
            url=$(git -C "$dir" remote get-url "$name" 2>/dev/null) || return 1
            _issue_linkage_scope_repo_from_url "$url"
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
        # gh は GitHub 以外のホストの remote を作成先に選ばないので飛ばす。ただし github を含むのに読めない形の URL
        # (ユーザー名付き・SSH のホスト別名・ポート付きなど)は gh が GitHub の remote として選びうる。そこで作成先の
        # 候補として同じ順位で比べ(repo は空)、それが選ばれるなら判定不能にする。同順位の並びで gh がどちらを選ぶかは
        # 確かめていないので、同順位なら読めない側を選ぶ。名前に github を含まない SSH のホスト別名は見分けられない。
        if ! repo=$(_issue_linkage_scope_repo_from_url "$url"); then
            [[ "$(printf '%s' "$url" | tr '[:upper:]' '[:lower:]')" == *github* ]] || continue
            repo=''
        fi
        case "$name" in
        upstream) score=3 ;;
        github) score=2 ;;
        origin) score=1 ;;
        *) score=0 ;;
        esac
        if [[ $score -gt $best_score || (-z "$repo" && $score -ge $best_score) ]]; then
            best=$repo
            best_score=$score
        fi
    done
    [[ -n "$best" ]] || return 1
    printf '%s' "$best"
}

# issue_linkage_scope_repo_flag <gh issue/pr create の引数...>: -R / --repo の値を出す(複数あれば gh と同じく最後の値)。
# 無ければ何も出さない。値を取るオプションの値は読み飛ばす。読み飛ばさないと `--label -Rx/y` の値を作成先と誤読し、
# 実際の作成先(cwd の remote)と違うリポジトリで範囲を判定してしまう。
# pflag は短いオプションをつなげた形(`-wRx/y`)と、値を続けた形(`-Rx/y` / `-R=x/y`)も受け付ける。
issue_linkage_scope_repo_flag() {
    local repo='' argument letters letter rest
    while [[ $# -gt 0 ]]; do
        argument=$1
        shift
        case "$argument" in
        --) break ;;
        --repo) repo=${1:-} && { [[ $# -eq 0 ]] || shift; } ;;
        --repo=*) repo=${argument#--repo=} ;;
        --*=*) ;;
        --assignee | --attach | --base | --blocked-by | --blocking | --body | --body-file | --head | --label | \
            --milestone | --parent | --project | --recover | --reviewer | --template | --title | --type)
            [[ $# -eq 0 ]] || shift
            ;;
        --*) ;;
        -?*)
            letters=${argument#-}
            while [[ -n "$letters" ]]; do
                letter=${letters:0:1}
                rest=${letters:1}
                case "$letter" in
                R | a | b | F | l | m | p | T | t | B | H | r)
                    if [[ -z "$rest" ]]; then
                        rest=${1:-}
                        [[ $# -eq 0 ]] || shift
                    else
                        rest=${rest#=}
                    fi
                    [[ "$letter" == R ]] && repo=$rest
                    break
                    ;;
                esac
                # 値を取らないオプションに `=` を続けた形(`-e=t`)は、`=` より後ろ全体がそのオプションの値になる。
                [[ "$rest" == =* ]] && break
                letters=$rest
            done
            ;;
        esac
    done
    printf '%s' "$repo"
}

# issue_linkage_scope_in_scope <dir> [<repo>]: 範囲内なら 0、範囲外・判定不能なら 1。
# <repo> は owner/name・github.com/owner/name・https://github.com/owner/name。空なら <dir> の remote から gh の既定の作成先を求める。
issue_linkage_scope_in_scope() {
    local dir=${1:-.} repo=${2:-} owner allowed host
    if [[ -z "$repo" ]]; then
        repo=$(_issue_linkage_scope_default_repo "$dir") || return 1
    else
        repo=${repo#https://}
        case "$repo" in
        github.com/*) repo=${repo#github.com/} ;;
        *)
            # ホストの無い OWNER/REPO は、gh が GH_HOST のホストで解決する(gh help environment)。
            # github.com 以外なら、同じ owner 名でも別のホストのリポジトリなので範囲外。
            host=$(printf '%s' "${GH_HOST:-github.com}" | tr '[:upper:]' '[:lower:]')
            [[ "$host" == github.com ]] || return 1
            ;;
        esac
    fi
    owner=${repo%%/*}
    [[ -n "$owner" && "$owner" != "$repo" ]] || return 1
    owner=$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')
    for allowed in ${ISSUE_LINKAGE_GUARD_OWNERS-tanimon}; do
        allowed=$(printf '%s' "$allowed" | tr '[:upper:]' '[:lower:]')
        [[ "$owner" == "$allowed" ]] && return 0
    done
    return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    issue_linkage_scope_in_scope "${1:-.}" "${2:-}"
    exit $?
fi
