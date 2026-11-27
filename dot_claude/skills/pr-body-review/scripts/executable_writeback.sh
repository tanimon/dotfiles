#!/usr/bin/env bash
# PR 本文を edited.md で書き戻す。書く直前に本文を取り直して original.md と照らし、書いた後にも取り直して
# edited.md と照らす。`gh pr edit --body-file` は本文を全部置き換えるので、照らさずに書くと、確認の間に
# 他の人が入れた変更を消す。照合が食い違っても自分で書き直して再試行しない(GitHub 側の正規化か取りこぼしかは、
# 差分を見た人が決める)。本文は `jq -j .body` で取る。`-q` は末尾に改行を足し、書き戻すたびに改行が増える。
#
# 使い方: writeback.sh <PR の URL> <original.md> <edited.md>
# 終了コード: 0 書き戻して照合した
#             1 何も書いていない(引数の不備、本文の取得の失敗、取り直した本文が original.md と食い違う、
#               gh pr edit が失敗し、書いた後の本文が original.md のまま)
#             2 書いた後の本文が edited.md と食い違うか、書いた後の本文を取得できない
# -e を付けない。付けると、差分を見せる diff -u が 1 を返した時点で止まり、終了コード 2 が 1 になる。
set -uo pipefail

if [[ $# -ne 3 ]]; then
    echo 'writeback.sh: 使い方: writeback.sh <PR の URL> <original.md> <edited.md>' >&2
    exit 1
fi
pr_url=$1
original=$2
edited=$3

# 番号では gh が現在のディレクトリのリポジトリで PR を探し、別のリポジトリの PR を書き換えうる。
if [[ ! "$pr_url" =~ ^https://github\.com/[^/]+/[^/]+/pull/[0-9]+$ ]]; then
    echo "writeback.sh: PR は URL で渡す: $pr_url" >&2
    exit 1
fi
for file in "$original" "$edited"; do
    if [[ ! -r "$file" ]]; then
        echo "writeback.sh: 読めない: $file" >&2
        exit 1
    fi
done

work=$(mktemp -d "${TMPDIR:-/tmp}/pr-body-writeback.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

fetch_body() {
    gh pr view "$pr_url" --json body | jq -j .body >"$1"
}

if ! fetch_body "$work/before.md"; then
    echo "writeback.sh: 本文を取得できなかった。何も書いていない: $pr_url" >&2
    exit 1
fi
if ! cmp -s "$original" "$work/before.md"; then
    echo "writeback.sh: 取り直した本文が original.md と食い違う(確認の間に本文が変わった)。何も書いていない: $pr_url" >&2
    diff -u "$original" "$work/before.md" >&2
    exit 1
fi

# 失敗しても書かれたかは分からないので、取り直して照らす。
edit_failed=
if ! gh pr edit "$pr_url" --body-file "$edited" >/dev/null; then
    edit_failed=1
    echo "writeback.sh: gh pr edit が失敗した。書いた後の本文を照らす" >&2
fi

if ! fetch_body "$work/after.md"; then
    echo "writeback.sh: 書いた後の本文を取得できず、照らせない。元に戻すときは $original を gh pr edit --body-file に渡す: $pr_url" >&2
    exit 2
fi
if ! cmp -s "$edited" "$work/after.md"; then
    # gh pr edit が成功を返したのに本文が元のままなら、読み取りが古いだけかもしれないので「書いていない」とは言えない。
    if [[ -n "$edit_failed" ]] && cmp -s "$original" "$work/after.md"; then
        echo "writeback.sh: gh pr edit が失敗し、本文は original.md のまま。何も書いていない: ${pr_url}" >&2
        exit 1
    fi
    echo "writeback.sh: 書いた後の本文が edited.md と食い違う。元に戻すときは $original を gh pr edit --body-file に渡す: $pr_url" >&2
    diff -u "$edited" "$work/after.md" >&2
    exit 2
fi
echo "writeback.sh: 書き戻して照合した: $pr_url"
