# chezmoi テンプレートを Machine Profile の fixture で描画する、bats suite 用の唯一の seam。
# just check-templates はこれを通らず chezmoi execute-template を直接呼ぶ別経路。
#
# 読み込んだ時点で chezmoi を絶対パスに解決し、無ければ読み込みごと失敗する。
# skip にしないのは、CI で描画を使う検査が全部素通りして緑になるため。
# setup_file で読み込めば suite の test は 1 件も走らず、setup で読み込めば全 test が失敗する。
#
# 呼び出し側の環境をそのまま引き継ぐ。PATH を差し替えて描画したい suite は
# `PATH=… render_template …` と包む。chezmoi は絶対パスで呼ぶので PATH を狭めても見失わない。
#
# profile の一覧は test/fixtures/chezmoi-<profile>.toml の実ファイルが正本。
# profile ごとに描画して契約を見るのは .profile で分岐するテンプレートだけで、
# その一覧は test/gitconfig.bats の検知テストが固定している。

#
# chezmoi の --source には RENDER_REPO ではなく、その作業ツリーの写し RENDER_SOURCE を渡す。
# chezmoi は --source のディレクトリをすべて lstat しながら辿るので、並列に走る別のレシピが
# リポジトリに作っては消す一時ファイルで落ちる(理由は scripts/chezmoi-source-snapshot.sh)。
# chezmoi を直接呼ぶ suite も --source には RENDER_SOURCE を渡す。テンプレートや fixture を
# 読む場所は RENDER_REPO のままでよい。描画結果の .chezmoi.sourceDir は RENDER_SOURCE になる。

RENDER_REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
RENDER_CHEZMOI="$(command -v chezmoi)" || {
    echo "chezmoi が必要(描画を使う suite は skip しない)" >&2
    return 1
}

# 写しは bats の実行 1 回につき 1 つ作り、suite と test のあいだで共有する。
# 並列の test が同時に作っても、symlink を張れた 1 つだけが使われる(-n で既存の symlink の先を辿らないので、2 つ目の ln -sn は失敗する)
RENDER_SOURCE="$BATS_RUN_TMPDIR/chezmoi-source"
if [ ! -d "$RENDER_SOURCE" ]; then
    render_snapshot=$(mktemp -d "$BATS_RUN_TMPDIR/chezmoi-source.XXXXXX") || return 1
    bash "$RENDER_REPO/scripts/chezmoi-source-snapshot.sh" "$RENDER_REPO" "$render_snapshot" || {
        echo "render: source の写しを作れない" >&2
        return 1
    }
    ln -sn "$render_snapshot" "$RENDER_SOURCE" 2>/dev/null || rm -rf "$render_snapshot"
fi
RENDER_SOURCE="$(cd "$RENDER_SOURCE" && pwd -P)" || return 1
export RENDER_REPO RENDER_SOURCE RENDER_CHEZMOI

# render_config PROFILE: その profile の fixture の絶対パスを出す
render_config() {
    local config="$RENDER_REPO/test/fixtures/chezmoi-$1.toml"
    if [ -z "$1" ] || [ ! -f "$config" ]; then
        echo "render: profile '$1' の fixture がありません: $config" >&2
        return 1
    fi
    printf '%s\n' "$config"
}

# render_template PROFILE TEMPLATE: TEMPLATE を PROFILE の fixture で描画して stdout に出す。
# テンプレートを stdin から渡すときは TEMPLATE に /dev/stdin を渡す
render_template() {
    local config
    config=$(render_config "$1") || return 1
    "$RENDER_CHEZMOI" execute-template --config "$config" --source "$RENDER_SOURCE" <"$2"
}
