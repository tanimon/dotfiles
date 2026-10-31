# 描画の module(scripts/chezmoi-render.bash)の、bats suite 用の adapter。
# 写しの置き場所として BATS_RUN_TMPDIR を渡して初期化するだけで、描画・Machine Profile の一覧・chezmoi の解決は module が持つ。
# 写しは bats の実行 1 回につき 1 つで、suite と test のあいだで共有する。
#
# chezmoi が無いと読み込みごと失敗する(skip しない理由は module のヘッダ)。
# setup_file で読み込めば suite の test は 1 件も走らず、setup で読み込めば全 test が失敗する。
# setup_file で読み込んだ関数は @test から呼べない(bats は test ごとに別のプロセスで動く)。@test で render_* を呼ぶ suite は setup でも読み込む。
#
# profile ごとに描画して契約を見るのは .profile で分岐するテンプレートだけで、
# その一覧は test/gitconfig.bats の検知テストが固定している。

# shellcheck source=scripts/chezmoi-render.bash
source "$BATS_TEST_DIRNAME/../scripts/chezmoi-render.bash" || return 1
render_init "$BATS_RUN_TMPDIR" || return 1
export RENDER_REPO
