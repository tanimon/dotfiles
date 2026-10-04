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

RENDER_REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
RENDER_CHEZMOI="$(command -v chezmoi)" || {
    echo "chezmoi が必要(描画を使う suite は skip しない)" >&2
    return 1
}
export RENDER_REPO RENDER_CHEZMOI

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
    "$RENDER_CHEZMOI" execute-template --config "$config" --source "$RENDER_REPO" <"$2"
}
