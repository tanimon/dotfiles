#!/usr/bin/env bash
# chezmoi の source state を読む検査(テンプレートの描画・managed・source-path)に --source として渡す、
# リポジトリの作業ツリーの写しを DEST に作る。
#
# chezmoi は --source のディレクトリを .chezmoiignore の対象も含めてすべて辿り、項目を 1 つずつ lstat する。
# `just lint` は [parallel] なので、別のレシピの pnpm がリポジトリに作っては消す一時ファイル
# (リポジトリ直下の _tmp_<pid>_<hash> や node_modules/.pnpm/lock.yaml.<乱数>)が、一覧を取ってから
# lstat するまでの間に消えると、chezmoi は ENOENT で落ちる。写しには誰も書き込まないので、この競合が起きない。
# 経緯と再現の手順は docs/solutions/integration-issues/chezmoi-source-walk-races-parallel-recipes.md。
#
# 写すのは作業ツリーの内容で、commit していない編集と、.gitignore されていない未追跡ファイルを含む。
# .git と .gitignore されたもの(node_modules など)は写さない。
#
# usage: chezmoi-source-snapshot.sh REPO DEST
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: chezmoi-source-snapshot.sh REPO DEST" >&2
    exit 2
fi
repo=$1
dest=$2
mkdir -p "$dest"
dest=$(cd "$dest" && pwd)
cd "$repo"

# bsdtar は拡張属性と macOS のメタデータを既定で読み、その読み取りで写しが数倍遅くなる(実測)。描画には要らない
tar_opts=()
if [[ $(tar --version 2>/dev/null) == *bsdtar* ]]; then
    tar_opts=(--no-mac-metadata --no-xattrs)
fi

# 追跡しているファイルは並列のレシピが作っては消すことがないので、まとめて tar で写す。
# 作業ツリーで削除済みのものだけを除く(git ls-files --cached は削除済みも出す)
git ls-files -z --cached |
    while IFS= read -r -d '' file; do
        if [ -e "$file" ] || [ -L "$file" ]; then
            printf '%s\0' "$file"
        fi
    done |
    tar ${tar_opts[@]+"${tar_opts[@]}"} --null -T - -cf - |
    tar -xf - -C "$dest"

# 未追跡のファイルには、並列のレシピの一時ファイルが混ざる。写す前か写している間に消えたものは飛ばす
git ls-files -z --others --exclude-standard |
    while IFS= read -r -d '' file; do
        mkdir -p "$dest/$(dirname "$file")"
        if ! cp -pP "$file" "$dest/$file" 2>/dev/null; then
            if [ -e "$file" ] || [ -L "$file" ]; then
                echo "chezmoi-source-snapshot: $file を写せない" >&2
                exit 1
            fi
        fi
    done
