#!/usr/bin/env bash
# HEAD を基準のブランチ(既定 origin/main)とマージした結果を、scripts/check-instruction-size.sh で測る。
# CI は pull_request のマージ commit を測るので、ブランチ単体では上限内でも、先に基準のブランチへ入った
# 変更と合わせて上限を超えることがある(上限は増加を止めるため、今のサイズに近い値に置いてある)。
# 作業ツリーの未 commit の変更は測らない(CI と同じく commit 済みのものだけを測る)。
#
# 使い方(リポジトリのルートで実行する):
#   check-instruction-size-merged.sh [<base-ref>]   # 既定は origin/main
# 環境変数:
#   INSTRUCTION_SIZE_SKIP_FETCH=1   リモートに接続しない。値を問わず、設定されていれば飛ばす
#                                   (scripts/pr-context.sh の PR_CONTEXT_SKIP_FETCH と同じ約束)
#
# 範囲: 測るのは check-instruction-size.sh の既定の使い方(ソースのまま測るファイル)だけ。描画してから測る
# テンプレート(test/rendered-instruction-size.bats)も同じ形でぶつかりうるが、ここでは測らない。
#
# 終了コード: 0 = 上限内か、マージ結果を作れない(理由を出す)、1 = 上限を超えたファイルがある、
# 2 = 上限の一覧を読めない。pre-push で走るので、マージ結果を作れないときは push を止めない: 衝突した PR では
# GitHub が pull_request のワークフローを走らせず、止めると衝突を PR に載せる push もできなくなる。
set -euo pipefail

base=${1:-origin/main}
remote=${base%%/*}
branch=${base#*/}

# 測る前に fetch する。手元の基準が古いと、先に入った変更を見ずに通ってしまう。
# fetch を飛ばしたときと失敗したときは、古い基準と比べていることを名前で出す(黙って通すと「上限内」に見える)
if [[ -n ${INSTRUCTION_SIZE_SKIP_FETCH+set} ]]; then
    echo "instruction-size-merged: fetch を飛ばした(INSTRUCTION_SIZE_SKIP_FETCH)。${base} は古いかもしれない" >&2
elif [[ $base != */* ]] || ! git remote | grep -qxF "$remote"; then
    echo "instruction-size-merged: ${base} はリモートを指さないので fetch しない" >&2
elif ! fetch_error=$(git fetch -q "$remote" "$branch" 2>&1); then
    echo "instruction-size-merged: ${remote} ${branch} を fetch できなかった。古い ${base} と比べる:" >&2
    printf '%s\n' "$fetch_error" >&2
fi

if ! git rev-parse --verify --quiet "${base}^{commit}" >/dev/null; then
    echo "instruction-size-merged: 基準を解決できないので測らない: ${base}" >&2
    exit 0
fi

# --write-tree は衝突すると exit 1 で、衝突の情報を続けて出す。衝突した tree は衝突の印を含むので測らない
if ! merge_output=$(git merge-tree --write-tree HEAD "$base"); then
    echo "instruction-size-merged: HEAD と ${base} のマージ結果を作れない(衝突など)ので測らない。衝突を解いてから測る:" >&2
    printf '%s\n' "$merge_output" >&2
    exit 0
fi
merged_tree=${merge_output%%$'\n'*}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/tree"
# 一時の index と作業ツリーに展開し、このリポジトリの git dir(オブジェクト)はそのまま使う。
# check-instruction-size.sh は git ls-files で対象を数え、カレントディレクトリからの相対パスで読む
GIT_DIR=$(git rev-parse --absolute-git-dir)
export GIT_DIR
export GIT_WORK_TREE="$work/tree"
export GIT_INDEX_FILE="$work/index"
cd "$work/tree"
git read-tree "$merged_tree"
git checkout-index --all

# マージ後のスクリプトと上限の一覧で測る(CI が走らせるのもマージ後のもの)
status=0
bash scripts/check-instruction-size.sh || status=$?
if ((status == 1)); then
    echo "instruction-size-merged: ${base} とマージした結果で上限を超える。${base} を取り込んでから詰める" >&2
fi
exit "$status"
