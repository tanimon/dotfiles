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
    # Source を直接 grep せず、seam(execute-template)を通した結果を見る。
    # Source を見ていると、テンプレート側で製品名を注入する変更に気づけない
    local shared word
    shared=$(printf '{{ template "agent-instructions-common" }}' |
        chezmoi execute-template --config "$CONFIG" --source "$REPO")
    [ -n "$shared" ] || fail "共有本文が空です(grep が必ず失敗して空振りする)"
    for word in Claude claude Codex codex Cursor cursor AskUserQuestion; do
        printf '%s\n' "$shared" | grep -q -- "$word" &&
            fail "共有本文に製品固有の語があります: $word"
    done
    return 0
}

@test "AGENTS.md に共有 rules の全ファイルが全行入っている" {
    # ファイルを 1 件ずつ、かつ全行で見る。「どれか 1 ファイルの見出しが出ている」で
    # 満足すると、include の並びから 1 行落ちても気づけない。
    # 列挙は Source ディレクトリの実体から行う(テンプレートの include 一覧からではない)
    # ので、新しい rules ファイルを足して include を忘れるとここで落ちる。
    # 各ファイルの先頭行・末尾行も「全行」に含まれるので、末尾改行の無いファイルが
    # 次のファイルの見出しとくっついて 1 行になった場合も grep -x で落ちる
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

@test "AskUserQuestion は CLAUDE.md の出力にだけ現れる(Contrast Pair)" {
    run bash -c 'set -o pipefail; chezmoi execute-template --config "$1" --source "$2" <"$2/dot_claude/CLAUDE.md.tmpl" | grep -c AskUserQuestion' _ "$CONFIG" "$REPO"
    assert_success
    assert_output '1'
    run bash -c 'chezmoi execute-template --config "$1" --source "$2" <"$2/dot_codex/AGENTS.md.tmpl" | grep -n AskUserQuestion' _ "$CONFIG" "$REPO"
    assert_failure
}

@test "CLAUDE.md の出力が #311 で合意した全文と一致する" {
    # #311 の AC は「AskUserQuestion 節の言い換え以外、変更前と差分が無い」。
    # 「従来の各行が含まれる」だけを見る検査は、節の並べ替えにも節の追加にも
    # 反応しない — つまり実際に起きた逸脱をちょうど素通りする。全文で固定する。
    #
    # 変更前(dot_claude/CLAUDE.md)からの意図した差分はここに見えるとおり 2 点だけ:
    #   1. 「ユーザーへの確認」が製品非依存の文面になり、共有本文の一部として
    #      「ルール構成」より前に出る(共有本文は 1 つの連続ブロックなので、
    #      Claude 固有の「ルール構成」を間に挟んだ元の並びは再現できない)
    #   2. AskUserQuestion は Claude 固有なので末尾の「ユーザーへの確認に使うツール」へ
    run render_claude
    assert_success
    assert_output - <<'EOF'
# 複数視点での意思決定

- ユーザーの意見は数ある視点の一つとして扱い、他の視点やソースも検討する。単一の視点は、同意によって補強されても本人が気づいていない死角を生みやすく、代替案・既存のベストプラクティス・別のソースを参照することでその死角を拾える。
- 状況に応じて反論し、代替案を提案する。デフォルトで同意しない。黙って同意すると死角がそのまま残ってしまうため、率直に指摘して選択肢を示す。

# ユーザーへの確認

ユーザーに意思決定の確認や選択肢からの選択を求めたいときは、自由記述の問いかけより、番号付きの選択肢を提示する形を優先する。構造化された選択可能な形にすることで意思決定を明確にできるため。選択肢では表現できないケース(自由記述の入力が必要な場合など)には、自由記述の問いかけを使う。

# ルール構成

コーディングの詳細なルール、テスト方針、セキュリティガイドラインは `~/.claude/rules/` にあり、共通(`common/`)とドメイン別ディレクトリ(`web/`、`golang/`、`typescript/`等。プロジェクト固有のシンボリックリンクが追加される場合もある)で整理されている。このファイルには、プロジェクトを横断する振る舞いに関するガイドラインのみを記載する。

# ユーザーへの確認に使うツール

上の「ユーザーへの確認」で番号付きの選択肢を提示するときは、`AskUserQuestion` ツールを使う。Claude Code はこのツールで選択肢を構造化して提示できる。
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

@test "AGENTS.md のテンプレートは common/ 以外の rules を取り込まない" {
    # ~/.claude/rules/ には仕事リポジトリの rules が symlink で差し込まれるが、
    # Source は dot_claude/rules/common/ だけ。取り込まれていないことは出力からは
    # 言えない(symlink はこのリポジトリに存在しない)ので、ここだけは Source を見る。
    # 検査は 2 つ: (1) common/ 以外を指す include がゼロ、(2) include の数が
    # common/ の実ファイル数と一致(足したのに include し忘れた、を捕まえる)
    run grep -c 'include "dot_claude/rules/common/' "$REPO/dot_codex/AGENTS.md.tmpl"
    assert_success
    local common_includes=$output
    run grep -c 'include "dot_claude/rules/' "$REPO/dot_codex/AGENTS.md.tmpl"
    assert_success
    assert_equal "$output" "$common_includes"
    local files
    files=$(find "$RULES_DIR" -type f -name '*.md' | wc -l | tr -d ' ')
    assert_equal "$common_includes" "$files"
}

# 以下 2 件の `chezmoi managed` はネットワークを要求する: chezmoi は source state を
# 組み立てる際に .chezmoiexternal.toml の archive external(github.com の tarball)を
# 必ず取得しにいく。`--exclude=externals` も `--refresh-externals=never` も取得自体は
# 止められないことを実測済み。落ちたときのメッセージは gstack の tarball URL になり、
# グローバル指示とは無関係に見えるので、この注記を頼りに切り分けること。
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
