# グローバル instructions の同期(#311)の振る舞いテスト。
# 設計: docs/superpowers/specs/2026-09-14-global-instruction-sync-design.md
#
# グローバル Target は $HOME 配下にあり commit されないので、このスイートは
# **fixture の root** に対して本物の harness/manifest.json を sync/check する。
# live の $HOME は読みも書きもしない(検査しているのは Source であって、
# このマシンの現状ではない)。すべて harness/bin/harness.sh を外部コマンドとして呼ぶ。
setup() {
    load 'helpers/setup'
    REPO="$BATS_TEST_DIRNAME/.."
    HARNESS="$REPO/harness/bin/harness.sh"
    MANIFEST="$REPO/harness/manifest.json"
    PROJECT_MANIFEST="$REPO/harness/project.json"
    export HOME="$BATS_TEST_TMPDIR/home"
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"
    # グローバル Target の書き先。live の $HOME とは別物
    GROOT="$BATS_TEST_TMPDIR/root"
    mkdir -p "$HOME" "$TMPDIR" "$GROOT"
    # harness.sh / adapter_path が実際に読む環境変数はすべてクリアする(.claude/rules/shell-scripts.md)
    unset HARNESS_ADAPTER_DIR HARNESS_HOME HARNESS_ROOT HARNESS_SOURCE_DIR HARNESS_MANIFEST
}

global_sync() {
    bash "$HARNESS" sync --manifest "$MANIFEST" --root "$GROOT" --source-dir "$REPO"
}

global_check() {
    bash "$HARNESS" check --manifest "$MANIFEST" --root "$GROOT" --source-dir "$REPO" --no-probe
}

# グローバル共有モジュールが届いているかの目印(3 節それぞれの見出し)
GLOBAL_MARKERS=('# 複数視点での意思決定' '# ルール構成' '# ユーザーへの確認')

# ---------- レンダリングと冪等性 ----------

@test "本物の manifest.json が Claude と Codex のグローバル Target を生成する" {
    run global_sync
    assert_success
    assert_output --partial '2 updated, 0 unchanged'
    [ -f "$GROOT/.claude/CLAUDE.md" ]
    [ -f "$GROOT/.codex/AGENTS.md" ]
}

@test "グローバル sync は 2 回目に何も変更しない(冪等)" {
    run global_sync
    assert_success
    run global_sync
    assert_success
    assert_output --partial '0 updated, 2 unchanged'
}

@test "sync 後の check --no-probe が drift 無しで通る" {
    run global_sync
    assert_success
    run global_check
    assert_success
    assert_output --partial 'harness check: 0 failures'
    assert_output --partial 'OK   target .claude/CLAUDE.md'
    assert_output --partial 'OK   target .codex/AGENTS.md'
}

@test "グローバル Target の手編集を drift として検出する(Contrast Pair)" {
    run global_sync
    assert_success
    printf 'hand edited\n' >"$GROOT/.claude/CLAUDE.md"
    run global_check
    assert_failure 1
    assert_output --partial 'DRIFT target .claude/CLAUDE.md'
    assert_output --partial 'owner: compose'
}

@test "生成された 2 Target が自動生成 banner を持つ" {
    run global_sync
    assert_success
    local f
    for f in "$GROOT/.claude/CLAUDE.md" "$GROOT/.codex/AGENTS.md"; do
        run head -n3 "$f"
        assert_output --partial '自動生成'
        assert_output --partial 'harness'
    done
}

# ---------- AC: Existing global Claude behavior is preserved ----------

@test "AC2: 旧 dot_claude/CLAUDE.md の全非空行がグローバル CLAUDE.md に逐語で残っている" {
    # baseline は test/fixtures/global-claude-baseline.md に凍結してある(移管前の
    # dot_claude/CLAUDE.md そのもの)。文面を書き換えれば必ずここで落ちる
    run global_sync
    assert_success
    local line
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        grep -qxF -- "$line" "$GROOT/.claude/CLAUDE.md" ||
            fail "baseline の行がグローバル CLAUDE.md にありません: ${line} — 意図した変更なら test/fixtures/global-claude-baseline.md も同時に更新し、PR で baseline を動かしたことを明記する"
    done <"$REPO/test/fixtures/global-claude-baseline.md"
}

@test "AC2: baseline fixture が空でない(検査が空虚でないことの確認)" {
    # 上のテストは baseline が空ならすべて通ってしまう
    run grep -c . "$REPO/test/fixtures/global-claude-baseline.md"
    assert_success
    [ "$output" -ge 6 ]
}

# ---------- AC: Codex no longer references a nonexistent global rules location ----------

@test "AC3: グローバル AGENTS.md が存在しない ~/.Codex/rules/ を参照しない" {
    run global_sync
    assert_success
    run grep -n '\.Codex/rules' "$GROOT/.codex/AGENTS.md"
    assert_failure
}

@test "AC3: グローバル AGENTS.md が実在する ~/.claude/rules/ を指している" {
    # 「消しただけ」で置き換えられていない状態を捕まえる(上のテストだけなら
    # rules への言及を全部消しても通る)
    run global_sync
    assert_success
    run grep -q '~/\.claude/rules/' "$GROOT/.codex/AGENTS.md"
    assert_success
}

@test "AC3: グローバル AGENTS.md が存在しない ralph-wiggum / ralph-loop skill を案内しない" {
    # 2026-09-14 に codex debug prompt-input の skill 一覧で不在を実測した陳腐化記述
    run global_sync
    assert_success
    local marker
    for marker in 'ralph-wiggum' 'ralph-loop'; do
        run grep -n -- "$marker" "$GROOT/.codex/AGENTS.md"
        assert_failure
    done
}

@test "AC3: グローバル AGENTS.md が Claude 専用ツールを自分のものとして案内しない" {
    run global_sync
    assert_success
    # AskUserQuestion 自体は共有モジュールに出てくるが、Claude Code のツールであることを
    # 先に断る Runtime Extension が無ければ Codex は自分に有ると読む
    run grep -q 'Claude Code' "$GROOT/.codex/AGENTS.md"
    assert_success
}

# ---------- AC: Global and project instruction scopes compose without duplicating ----------

@test "AC6: グローバル manifest がプロジェクトモジュールを取り込んでいない" {
    # 「0 件」の検査は母数が 0 でも通ってしまうので、先に母数を確かめる
    run jq -r '[.targets[].modules[]] | length' "$MANIFEST"
    assert_success
    [ "$output" -ge 1 ]
    run jq -r '[.targets[].modules[]] | map(select(startswith("harness/modules/project/"))) | length' "$MANIFEST"
    assert_success
    assert_output '0'
}

@test "AC6: プロジェクトの CLAUDE.md / AGENTS.md がグローバルモジュールを取り込んでいない" {
    # 取り込むと Claude / Codex が同じ文をグローバルとプロジェクトの 2 経路で読む。
    # path が manifest から消えても jq は 0 を返すので、母数を先に確かめないと
    # 「Target ごと無くなった」状態を合格と読んでしまう
    local path
    for path in 'CLAUDE.md' 'AGENTS.md'; do
        run jq -r --arg p "$path" '[.targets[] | select(.path == $p) | .modules[]] | length' "$PROJECT_MANIFEST"
        assert_success
        [ "$output" -ge 1 ] || fail "project.json に Target \"$path\" がありません(この検査が空虚になっています)"
        run jq -r --arg p "$path" \
            '[.targets[] | select(.path == $p) | .modules[]] | map(select(startswith("harness/modules/global/"))) | length' \
            "$PROJECT_MANIFEST"
        assert_success
        assert_output '0'
    done
}

@test "AC6: Cursor の .mdc がグローバルモジュールを配送する(Contrast Pair)" {
    # 上の 2 つは「グローバルモジュールがどこにも配送されていない」でも成立してしまう。
    # Cursor にはグローバル面が無いので、プロジェクトの .mdc が唯一の経路になる
    run jq -r '[.targets[] | select(.path == ".cursor/rules/dotfiles.mdc") | .modules[]] | map(select(startswith("harness/modules/global/"))) | length' \
        "$PROJECT_MANIFEST"
    assert_success
    [ "$output" -ge 1 ]
}

@test "AC6: 生成済みプロジェクト Target にグローバルモジュールの中身が入っていない" {
    # 宣言(上のテスト)だけでなく成果物でも確認する
    local f marker
    for f in "$REPO/CLAUDE.md" "$REPO/AGENTS.md"; do
        for marker in "${GLOBAL_MARKERS[@]}"; do
            run grep -qF -- "$marker" "$f"
            assert_failure
        done
    done
}

@test "AC6: 生成済みの .cursor/rules/dotfiles.mdc にグローバルモジュールの中身が入っている" {
    local marker
    for marker in "${GLOBAL_MARKERS[@]}"; do
        run grep -qF -- "$marker" "$REPO/.cursor/rules/dotfiles.mdc"
        assert_success
    done
}

@test "グローバル Target が 3 節すべてを運んでいる" {
    run global_sync
    assert_success
    local f marker
    for f in "$GROOT/.claude/CLAUDE.md" "$GROOT/.codex/AGENTS.md"; do
        for marker in "${GLOBAL_MARKERS[@]}"; do
            run grep -qF -- "$marker" "$f"
            assert_success
        done
    done
}

@test "Claude のグローバル Target には非 Claude 向けの訂正が入らない(Contrast Pair)" {
    # 同じ共有モジュールを使いつつ、Runtime Extension が Codex 側にだけ付くことの確認
    run global_sync
    assert_success
    run grep -q 'Claude Code 以外' "$GROOT/.claude/CLAUDE.md"
    assert_failure
    run grep -q 'Claude Code 以外' "$GROOT/.codex/AGENTS.md"
    assert_success
}

# ---------- manifest の整合 ----------

@test "グローバル Target の path が Target Owner と runtime を明示している" {
    run jq -r '.targets[] | "\(.path) \(.runtime) \(.owner)"' "$MANIFEST"
    assert_success
    assert_line '.claude/CLAUDE.md claude compose'
    assert_line '.codex/AGENTS.md codex compose'
}
