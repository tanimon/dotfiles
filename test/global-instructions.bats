# グローバル指示(~/.claude/CLAUDE.md と ~/.codex/AGENTS.md)の合成テスト(#311)。
# 設計: docs/adr/0005-*.md
#
# seam は 1 つだけ: `chezmoi execute-template --config <test toml> --source <repo>`。
# harness/ は一切通らない(グローバル指示は chezmoi テンプレートだけで合成する)。
#
# chezmoi が無い場合は skip せず fail する。skip にすると「共有本文が両方に入っている」
# という不変条件が CI で緑のまま何も検証しない(fail-open)ため。CI は
# .github/workflows/lint.yml の global-instructions job で chezmoi を入れている。
setup() {
    load 'helpers/setup'
    REPO="$BATS_TEST_DIRNAME/.."
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"
    mkdir -p "$TMPDIR"
    CONFIG="$BATS_TEST_TMPDIR/chezmoi-test.toml"
    printf '[data]\n  profile = "personal"\n  ghOrg = "test-org"\n' >"$CONFIG"
    SHARED="$REPO/.chezmoitemplates/agent-instructions-common"
    RULES_DIR="$REPO/dot_claude/rules/common"
}

# render SOURCE_TMPL: テンプレートをレンダリングして stdout に出す
render() {
    chezmoi execute-template --config "$CONFIG" --source "$REPO" <"$1"
}

render_claude() {
    render "$REPO/dot_claude/CLAUDE.md.tmpl"
}

render_codex() {
    render "$REPO/dot_codex/AGENTS.md.tmpl"
}

@test "chezmoi が使える(この suite は skip しない)" {
    # skip にすると下の検査が CI で全部素通りして緑になる
    run command -v chezmoi
    assert_success
}

@test "共有本文が両方の出力に入っている" {
    # 共有テンプレートの全行(空行を除く)が CLAUDE.md にも AGENTS.md にも出ること。
    # 「見出し 1 つが一致」では、本文が片方から丸ごと落ちても通ってしまう
    local claude codex line
    claude=$(render_claude)
    codex=$(render_codex)
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf '%s\n' "$claude" | grep -qxF -- "$line" ||
            fail "CLAUDE.md に共有本文の行がありません: $line"
        printf '%s\n' "$codex" | grep -qxF -- "$line" ||
            fail "AGENTS.md に共有本文の行がありません: $line"
    done <"$SHARED"
}

@test "共有本文は製品名も製品固有のツール名も含まない" {
    # 共有テンプレートが無ければ grep は必ず失敗する = この検査が空振りする
    [ -s "$SHARED" ] || fail "共有テンプレートがありません: $SHARED"
    local word
    for word in Claude claude Codex codex Cursor cursor AskUserQuestion; do
        run grep -n -- "$word" "$SHARED"
        assert_failure
    done
}

@test "AGENTS.md に共有 rules の全ファイルが全行入っている" {
    # ファイルを 1 件ずつ、かつ全行で見る。「どれか 1 ファイルの見出しが出ている」で
    # 満足すると、include の並びから 1 行落ちても気づけない。
    # 列挙は Source ディレクトリの実体から行う(テンプレートの include 一覧からではない)
    # ので、新しい rules ファイルを足して include を忘れるとここで落ちる
    local codex file line count=0
    codex=$(render_codex)
    while IFS= read -r file; do
        count=$((count + 1))
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            printf '%s\n' "$codex" | grep -qxF -- "$line" ||
                fail "AGENTS.md に $file の行がありません: $line"
        done <"$file"
    done < <(find "$RULES_DIR" -type f -name '*.md' | sort)
    [ "$count" -gt 0 ] || fail "共有 rules が 1 件も見つかりません"
}

@test "AGENTS.md は連結の境目で見出しを前の段落にくっつけない" {
    # include はファイルの中身をそのまま返すので、末尾改行の無いファイルがあると
    # 次のファイルの見出しが前の行に続いてしまい、Markdown の見出しでなくなる
    # 境目は「前のファイルの最終行」と「次のファイルの先頭行」なので、両端が
    # それぞれ独立した 1 行として出ていることを確認する。grep -x(完全一致)で
    # 見ているので、連結されて 1 行になっていれば落ちる
    local codex file edge
    codex=$(render_codex)
    while IFS= read -r file; do
        for edge in "$(head -n1 "$file")" "$(grep -v '^[[:space:]]*$' "$file" | tail -n1)"; do
            [ -n "$edge" ] || continue
            printf '%s\n' "$codex" | grep -qxF -- "$edge" ||
                fail "AGENTS.md で $file の端の行が独立した行になっていません: $edge"
        done
    done < <(find "$RULES_DIR" -type f -name '*.md' | sort)
}

@test "AskUserQuestion は CLAUDE.md の出力にだけ現れる(Contrast Pair)" {
    run bash -c 'set -o pipefail; chezmoi execute-template --config "$1" --source "$2" <"$2/dot_claude/CLAUDE.md.tmpl" | grep -c AskUserQuestion' _ "$CONFIG" "$REPO"
    assert_success
    assert_output '1'
    run bash -c 'chezmoi execute-template --config "$1" --source "$2" <"$2/dot_codex/AGENTS.md.tmpl" | grep -n AskUserQuestion' _ "$CONFIG" "$REPO"
    assert_failure
}

@test "CLAUDE.md の出力は従来の本文を失っていない" {
    # #311 で許した差分は AskUserQuestion 節の言い換えだけ。他の段落は 1 字も変えない
    local claude
    claude=$(render_claude)
    local line
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf '%s\n' "$claude" | grep -qxF -- "$line" ||
            fail "CLAUDE.md から従来の行が失われています: $line"
    done <<'EOF'
# 複数視点での意思決定
- ユーザーの意見は数ある視点の一つとして扱い、他の視点やソースも検討する。単一の視点は、同意によって補強されても本人が気づいていない死角を生みやすく、代替案・既存のベストプラクティス・別のソースを参照することでその死角を拾える。
- 状況に応じて反論し、代替案を提案する。デフォルトで同意しない。黙って同意すると死角がそのまま残ってしまうため、率直に指摘して選択肢を示す。
# ルール構成
コーディングの詳細なルール、テスト方針、セキュリティガイドラインは `~/.claude/rules/` にあり、共通(`common/`)とドメイン別ディレクトリ(`web/`、`golang/`、`typescript/`等。プロジェクト固有のシンボリックリンクが追加される場合もある)で整理されている。このファイルには、プロジェクトを横断する振る舞いに関するガイドラインのみを記載する。
EOF
}

@test "AGENTS.md は Codex に存在しない Claude の機構を実行可能な指示として出さない" {
    # 共有 rules(harness-engineering.md)は /harness-reflect などの Claude 専用
    # スラッシュコマンドを含んだまま連結される。前置きで当てはまらないことを明示する
    local codex
    codex=$(render_codex)
    printf '%s\n' "$codex" | grep -q 'Claude Code のスラッシュコマンド' ||
        fail "AGENTS.md に Claude 専用機構の disclaimer がありません"
}

@test "AGENTS.md は Codex の切り捨て(32 KiB)に収まる" {
    # codex は project_doc_max_bytes(既定 32768 バイト)で AGENTS.md を黙って切る
    local bytes
    bytes=$(render_codex | wc -c | tr -d ' ')
    # 0 バイト(レンダリング失敗)でも「32768 未満」は成り立つので下限も見る
    [ "$bytes" -gt 4096 ] || fail "AGENTS.md が ${bytes} バイトしかありません"
    [ "$bytes" -lt 32768 ] ||
        fail "AGENTS.md が ${bytes} バイトで 32768 を超えています"
}

@test "AGENTS.md には仕事用のマシン固有ルールが入らない" {
    # ~/.claude/rules/ には仕事リポジトリの rules が symlink で差し込まれるが、
    # Source は dot_claude/rules/common/ だけ。symlink 由来のディレクトリを
    # 参照していないことをテンプレート側で確認する
    run grep -n 'rules/[a-z-]*/' "$REPO/dot_codex/AGENTS.md.tmpl"
    assert_output --partial 'rules/common/'
    run grep -c 'include "dot_claude/rules/' "$REPO/dot_codex/AGENTS.md.tmpl"
    assert_success
    local includes=$output
    local files
    files=$(find "$RULES_DIR" -type f -name '*.md' | wc -l | tr -d ' ')
    assert_equal "$includes" "$files"
}

@test "chezmoi managed に .codex/AGENTS.md が出る" {
    run chezmoi managed --config "$CONFIG" --source "$REPO"
    assert_success
    assert_line '.codex/AGENTS.md'
}

@test "chezmoi managed に .claude/CLAUDE.md が残っている" {
    # .tmpl 化で Target のパスが変わっていないこと
    run chezmoi managed --config "$CONFIG" --source "$REPO"
    assert_success
    assert_line '.claude/CLAUDE.md'
}
