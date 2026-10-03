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
    # #311 で共有本文を切り出したときに、元の CLAUDE.md から意図して変えたのは 2 点だけ:
    #   1. 「ユーザーへの確認」が製品非依存の文面になり、共有本文の一部として
    #      「ルール構成」より前に出る(共有本文は 1 つの連続ブロックなので、
    #      Claude 固有の「ルール構成」を間に挟んだ元の並びは再現できない)
    #   2. AskUserQuestion は Claude 固有なので末尾の「ユーザーへの確認に使うツール」へ
    #
    # このほか、#311 の後に共有本文へ加えた節(「主張の裏取り」「テストが検証するもの」
    # 「成果物に書かないもの」、「ルール構成」の claude-code/、末尾の「知見の記録先」)も
    # 期待値に含む。全文固定は維持し、本文を変えるときはこの期待値も同じ PR で更新する。
    run render_claude
    assert_success
    assert_output - <<'EOF'
# 複数視点での意思決定

- ユーザーの意見は数ある視点の一つとして扱い、他の視点やソースも検討する。単一の視点は、同意によって補強されても本人が気づいていない死角を生みやすく、代替案・既存のベストプラクティス・別のソースを参照することでその死角を拾える。
- 状況に応じて反論し、代替案を提案する。デフォルトで同意しない。黙って同意すると死角がそのまま残ってしまうため、率直に指摘して選択肢を示す。

# 主張の裏取り

- 「型検査が守る」「この経路にチェックが無い」「N+1 になる」のように仕組みを根拠にするときは、それがその場所で実際に効いているかを確かめてから言う。ファイルの言語モード(JS か TS か)、フレームワークの暗黙の層(ルートのミドルウェア、論理削除のグローバルスコープ、キャッシュ)を見落としたまま断定し、公開済みのレビューコメントを撤回した例がある。
- 「画面で〜できる」「ユーザーが〜を保存できる」と書くときは、API が受け付けるかだけでなく、その操作の入口になる UI の表示・活性条件(ボタンの表示・無効化の条件や、それを決める権限・機能フラグ)まで追う。確かめていない側は「サーバー側は受け付けるが、画面では未確認」と書き分ける。サーバー側の判定だけを根拠に「保存できる」と書き、検証環境で画面にボタンが出ず否定された例がある。

# テストが検証するもの

- テストは振る舞いを検証し、実装の仕組み(「ヘルパーに委譲する」など)を検証しない。テストのためだけにコードを切り出すと読みにくくなる場合は黙って適用せず、可読性とテスト容易性のトレードオフを示してユーザーに選んでもらう。

# 成果物に書かないもの

コミットされる成果物(設計書、設定ファイル、サービス名、PR 説明)に、ローカルのアカウント名・実名・worktree のディレクトリ名を書かない。worktree 名は衝突回避の乱数であり成果物の語彙ではないため、識別子はリポジトリ名や機能名から作り、例示はプレースホルダにする。

# ユーザーへの確認

ユーザーに意思決定の確認や選択肢からの選択を求めたいときは、自由記述の問いかけより、番号付きの選択肢を提示する形を優先する。構造化された選択可能な形にすることで意思決定を明確にできるため。選択肢では表現できないケース(自由記述の入力が必要な場合など)には、自由記述の問いかけを使う。

# ルール構成

コーディングの詳細なルールは `~/.claude/rules/` にあり、共通(`common/`)、Claude Code 専用(`claude-code/`。サブエージェントと Bash ツールの落とし穴)、ドメイン別ディレクトリ(`web/`、`typescript/`等。テスト方針・セキュリティガイドラインはドメイン別の側にある。プロジェクト固有のシンボリックリンクが追加される場合もある)で整理されている。このファイルには、プロジェクトを横断する振る舞いに関するガイドラインのみを記載する。

# ユーザーへの確認に使うツール

上の「ユーザーへの確認」で番号付きの選択肢を提示するときは、`AskUserQuestion` ツールを使う。Claude Code はこのツールで選択肢を構造化して提示できる。

# 知見の記録先

`llm-wiki` / `pr-review-wiki` 系のスキルは仕事用リポジトリの知識専用。それ以外のリポジトリでは提案も取り込みもしない。個人リポジトリの学びは、そのリポジトリの `docs/solutions/`・ルール・auto-memory に記録する。スキルの description にある「対象プロジェクトを問わず積極的に使う」よりこの節を優先する。
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

@test "合成後の CLAUDE.md はルールと指示の既定のサイズ上限に収まる" {
    # scripts/check-instruction-size.sh はテンプレートのソースをファイルごとに測るので、
    # 実際に読み込まれる合成後の出力はここで測る。上限は scripts/instruction-size-limits.txt の既定値
    local max_lines max_bytes lines bytes
    read -r _ max_lines max_bytes < <(grep -E '^\* ' "$REPO/scripts/instruction-size-limits.txt")
    [[ $max_lines =~ ^[0-9]+$ && $max_bytes =~ ^[0-9]+$ ]] ||
        fail "既定値の行を読めません: ${max_lines:-} ${max_bytes:-}"
    lines=$(render_claude | awk 'END { print NR }')
    bytes=$(render_claude | wc -c | tr -d ' ')
    # 0 行(レンダリング失敗)でも上限内は成り立つので下限も見る
    [ "$lines" -gt 10 ] || fail "CLAUDE.md が ${lines} 行しかありません"
    [ "$lines" -le "$max_lines" ] || fail "CLAUDE.md が ${lines} 行で上限 ${max_lines} を超えています"
    [ "$bytes" -le "$max_bytes" ] || fail "CLAUDE.md が ${bytes} バイトで上限 ${max_bytes} を超えています"
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

# 以下 3 件の `chezmoi managed` はネットワークを要求する: chezmoi は source state を
# 組み立てる際に .chezmoiexternal.toml の archive external(github.com の tarball)を
# 必ず取得しにいく。`--exclude=externals` も `--refresh-externals=never` も取得自体は
# 止められないことを実測済み。落ちたときのメッセージは external の tarball URL(affaan-m/ECC や
# openai/skills など .chezmoiexternal.toml にあるもの)になり、グローバル指示とは無関係に見えるので、
# この注記を頼りに切り分けること。
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

@test "ECC の rules/{typescript,web} は列挙した 10 ファイルだけが配置される" {
    # .chezmoiexternal.toml の include はファイルを列挙しているので、ECC の SHA 更新で
    # upstream のファイルが改名・削除されると黙って配置されなくなる(古いファイルは
    # ~/ に残って読み込まれ続ける)。hooks.md を外した理由は
    # docs/superpowers/specs/2026-09-24-ecc-minimal-install-design.md
    run chezmoi managed --config "$CONFIG" --source "$REPO" --include=files
    assert_success
    local ecc_rules
    ecc_rules=$(printf '%s\n' "$output" | grep -E '^\.claude/rules/(typescript|web)/')
    assert_equal "$ecc_rules" "$(
        cat <<'LIST'
.claude/rules/typescript/coding-style.md
.claude/rules/typescript/patterns.md
.claude/rules/typescript/security.md
.claude/rules/typescript/testing.md
.claude/rules/web/coding-style.md
.claude/rules/web/design-quality.md
.claude/rules/web/patterns.md
.claude/rules/web/performance.md
.claude/rules/web/security.md
.claude/rules/web/testing.md
LIST
    )"
}
