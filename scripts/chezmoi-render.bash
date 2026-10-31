#!/usr/bin/env bash
# chezmoi のテンプレートを Machine Profile の fixture(test/fixtures/chezmoi-<profile>.toml)で描画する、描画の module。
# source 専用。set は呼び出し側に従う(set -u 下でも動く)。bats に依存しないので、bats の suite(test/helpers/render.bash)・
# justfile の recipe(check-templates)・scripts/ のスクリプトのどこからでも使える。
#
# interface:
#   render_init 作業ディレクトリ   初期化。chezmoi を絶対パスに解決し、作業ディレクトリの中にリポジトリの作業ツリーの写しを作る
#   render_template PROFILE TEMPLATE
#   render_chezmoi PROFILE サブコマンド [引数…]
# 公開する変数は、リポジトリのルートを指す RENDER_REPO だけ。chezmoi の絶対パス・写し・fixture のパスは呼び出し側に渡さない。
#
# chezmoi が無ければ render_init は失敗する。skip にしないのは、CI で描画を使う検査が全部素通りして緑になるため。
# chezmoi は render_init の時点で絶対パスに解決するので、呼び出し側が `PATH=… render_template …` と PATH を狭めても見失わない。
#
# chezmoi の --source には RENDER_REPO ではなく、作業ディレクトリの中の写しを渡す。chezmoi は --source のディレクトリを
# すべて lstat しながら辿るので、並列に走る別のレシピがリポジトリに作っては消す一時ファイルで落ちる
# (理由は scripts/chezmoi-source-snapshot.sh)。描画結果の .chezmoi.sourceDir は写しになる。
# 写しは recipe の間で共有しない(`just lint` は並列なので、共有すると作る・消すの調停が要る)。作業ディレクトリは呼び出し側が渡し、
# その後始末も呼び出し側が持つ。

RENDER_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || return 1
_RENDER_EXECUTABLE=""
_RENDER_SNAPSHOT=""

# render_init WORK_DIR: chezmoi を解決し、WORK_DIR の中に写しを 1 度だけ作る。
# 同じ WORK_DIR で並行して呼んでも、symlink を張れた 1 つだけが使われる(-n で既存の symlink の先を辿らないので、2 つ目の ln -sn は失敗する)
render_init() {
    local work_dir=${1:-} link snapshot
    if [ -z "$work_dir" ] || [ ! -d "$work_dir" ]; then
        echo "render: 作業ディレクトリがありません: ${work_dir}" >&2
        return 1
    fi
    _RENDER_EXECUTABLE=$(command -v chezmoi) || {
        echo "render: chezmoi が必要(描画を使う検査は skip しない)" >&2
        return 1
    }
    link="$work_dir/chezmoi-source"
    if [ ! -d "$link" ]; then
        snapshot=$(mktemp -d "$work_dir/chezmoi-source.XXXXXX") || return 1
        bash "$RENDER_REPO/scripts/chezmoi-source-snapshot.sh" "$RENDER_REPO" "$snapshot" || {
            echo "render: source の写しを作れない" >&2
            return 1
        }
        ln -sn "$snapshot" "$link" 2>/dev/null || rm -rf "$snapshot"
    fi
    _RENDER_SNAPSHOT=$(cd "$link" && pwd -P) || return 1
}

# render_profiles: Machine Profile の名前を 1 行ずつ出す。一覧の正本は test/fixtures/chezmoi-<profile>.toml の実ファイルで、
# 「全 Machine Profile」で描画する検査はここから一覧を取る。fixture が 0 件なら失敗する(検査が空振りして通らないように)。
# render_init を呼ばずに使える
render_profiles() {
    local config found=""
    for config in "$RENDER_REPO"/test/fixtures/chezmoi-*.toml; do
        [ -f "$config" ] || continue
        config=${config##*/chezmoi-}
        printf '%s\n' "${config%.toml}"
        found=1
    done
    if [ -z "$found" ]; then
        echo "render: Machine Profile の fixture が 1 件も無い: ${RENDER_REPO}/test/fixtures/chezmoi-*.toml" >&2
        return 1
    fi
}

# _render_fixture PROFILE: その Machine Profile の fixture の絶対パスを出す
_render_fixture() {
    local config="$RENDER_REPO/test/fixtures/chezmoi-${1:-}.toml"
    if [ -z "${1:-}" ] || [ ! -f "$config" ]; then
        echo "render: profile '${1:-}' の fixture がありません: ${config}" >&2
        return 1
    fi
    printf '%s\n' "$config"
}

# render_chezmoi PROFILE SUBCOMMAND [ARGS…]: その Machine Profile の fixture を --config に、写しを --source に付けて
# chezmoi を走らせる。source state を読むサブコマンド(execute-template・managed・source-path)に使う
render_chezmoi() {
    local config
    if [ -z "$_RENDER_EXECUTABLE" ]; then
        echo "render: render_init を先に呼ぶ" >&2
        return 1
    fi
    config=$(_render_fixture "${1:-}") || return 1
    shift
    "$_RENDER_EXECUTABLE" --config "$config" --source "$_RENDER_SNAPSHOT" "$@"
}

# render_template PROFILE TEMPLATE: TEMPLATE を PROFILE の fixture で描画して stdout に出す。
# テンプレートを stdin から渡すときは TEMPLATE に /dev/stdin を渡す。TEMPLATE はこのリポジトリの外にあってもよい
# (source は常にこのリポジトリの写し)
render_template() {
    render_chezmoi "${1:-}" execute-template <"${2:-}"
}
