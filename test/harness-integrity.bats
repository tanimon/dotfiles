# 週次ジョブの Integrity Snapshot(lib/harness-integrity.bash)の interface の検査。lib を直接 source する。
# 週次ジョブの経路ごとの振る舞い(どの呼び出しが入口を通るか)は test/harness-weekly.bats が検査する。
setup() {
    load 'helpers/setup'
    # 偽の実行物が読む変数を、このマシンのシェルから漏らさない
    unset STUB_EXIT HARNESS_EVAL_BUDGET_USD
    LIB="$BATS_TEST_DIRNAME/../dot_claude/scripts/lib/harness-integrity.bash"
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    export HOME="$BATS_TEST_TMPDIR/home"
    SCRIPTS="$HOME/.claude/scripts"
    HDIR="$HOME/.claude/harness"
    mkdir -p "$SCRIPTS/harness-eval-plugin/.claude-plugin" "$SCRIPTS/harness-eval-plugin/hooks" \
        "$HDIR/failure-pattern-rates" "$HDIR/rule-ledger/exported"
    # 実行物は中身の決まった偽物にする(自分の名前と引数を出し、STUB_EXIT で終わる)
    for name in harness-failure-rates.sh harness-verdict.sh harness-rule-ledger.sh harness-eval-cases.sh; do
        cat >"$SCRIPTS/$name" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*"
exit "${STUB_EXIT:-0}"
EOF
    done
    printf '{}\n' >"$SCRIPTS/harness-failure-patterns.json"
    printf '{}\n' >"$SCRIPTS/harness-eval-plugin/.claude-plugin/plugin.json"
    printf '{}\n' >"$SCRIPTS/harness-eval-plugin/hooks/hooks.json"
    printf '{"date":"2026-10-10"}\n' >"$HDIR/failure-pattern-rates/2026-10-10.json"
    printf '{"id":"pr1-00000000"}\n' >"$HDIR/rule-ledger/pr1-00000000.json"
    printf '{"id":"pr1-00000000"}\n' >"$HDIR/rule-ledger/exported/pr1-00000000.json"
    printf '{"session_id":"s"}\n' >"$HDIR/classifications.jsonl"
    printf '{"session_id":"s","epoch":1,"counts":{}}\n' >"$HDIR/detections.jsonl"
    # shellcheck source=../dot_claude/scripts/lib/harness-integrity.bash
    source "$LIB"
}

teardown() {
    chmod -R u+rw "$HOME" 2>/dev/null || true
}

@test "スナップショットの後に何も変わらなければ、入口はスクリプトを実行して終了コードをそのまま返す" {
    harness_integrity_snapshot
    run harness_integrity_run "$SCRIPTS/harness-verdict.sh" unpublished --branch b
    assert_success
    assert_output 'harness-verdict.sh unpublished --branch b'
    STUB_EXIT=2 run harness_integrity_run "$SCRIPTS/harness-verdict.sh" adopted
    assert_failure 2
}

@test "スナップショットの後に実行物が書き換えられたら、入口は実行せずに予約コードを返し、パスだけを出す" {
    harness_integrity_snapshot
    printf '# tampered\n' >>"$SCRIPTS/harness-eval-cases.sh"
    digest=$(git hash-object -- "$SCRIPTS/harness-eval-cases.sh")
    run harness_integrity_run "$SCRIPTS/harness-verdict.sh" unpublished
    assert_failure "$HARNESS_INTEGRITY_FAILED"
    refute_output --partial 'harness-verdict.sh unpublished'
    assert_output --partial "changed: $SCRIPTS/harness-eval-cases.sh"
    assert_output --partial 'chezmoi apply'
    refute_output --partial "$digest"
}

@test "スナップショットの後に実行物が消されたら、入口は予約コードを返す" {
    harness_integrity_snapshot
    rm "$SCRIPTS/harness-eval-plugin/hooks/hooks.json"
    run harness_integrity_run "$SCRIPTS/harness-failure-rates.sh" trend
    assert_failure "$HARNESS_INTEGRITY_FAILED"
    assert_output --partial "missing: $SCRIPTS/harness-eval-plugin/hooks/hooks.json"
}

@test "スナップショットの時点で無かった実行物は、無いままなら一致として扱い、現れたら書き換えとして扱う" {
    rm "$SCRIPTS/harness-eval-plugin/hooks/hooks.json"
    harness_integrity_snapshot
    run harness_integrity_gate
    assert_success
    printf '{}\n' >"$SCRIPTS/harness-eval-plugin/hooks/hooks.json"
    run harness_integrity_gate
    assert_failure "$HARNESS_INTEGRITY_FAILED"
    assert_output --partial "added: $SCRIPTS/harness-eval-plugin/hooks/hooks.json"
}

@test "スナップショットの前に入口・関門・データの照合・封印を使うと、実行せずに予約コードを返す" {
    run harness_integrity_run "$SCRIPTS/harness-verdict.sh" unpublished
    assert_failure "$HARNESS_INTEGRITY_FAILED"
    assert_output --partial 'used before the snapshot'
    refute_output --partial 'harness-verdict.sh unpublished'
    run harness_integrity_gate
    assert_failure "$HARNESS_INTEGRITY_FAILED"
    run harness_integrity_check_data
    assert_failure "$HARNESS_INTEGRITY_FAILED"
    run harness_integrity_seal "$HDIR/classifications.jsonl"
    assert_failure "$HARNESS_INTEGRITY_FAILED"
    run harness_integrity_ready
    assert_failure
    harness_integrity_snapshot
    run harness_integrity_ready
    assert_success
}

@test "一覧に無いスクリプトは、照合が通っても入口から実行しない" {
    cat >"$SCRIPTS/harness-other.sh" <<'EOF'
#!/usr/bin/env bash
echo ran
EOF
    harness_integrity_snapshot
    run harness_integrity_run "$SCRIPTS/harness-other.sh"
    assert_failure "$HARNESS_INTEGRITY_FAILED"
    assert_output --partial 'not in the list of trusted executables'
    refute_output --partial 'ran'
}

@test "実行物のハッシュを取れなければ、入口は照合できないとして予約コードを返す" {
    harness_integrity_snapshot
    chmod 000 "$SCRIPTS/harness-failure-patterns.json"
    run harness_integrity_run "$SCRIPTS/harness-failure-rates.sh" trend
    assert_failure "$HARNESS_INTEGRITY_FAILED"
    assert_output --partial "could not hash $SCRIPTS/harness-failure-patterns.json"
    assert_output --partial 'chezmoi apply'
    refute_output --partial 'harness-failure-rates.sh trend'
}

@test "スナップショットの時点でハッシュを取れなければ、スナップショットは予約コードを返す" {
    chmod 000 "$HDIR/rule-ledger/pr1-00000000.json"
    run harness_integrity_snapshot
    assert_failure "$HARNESS_INTEGRITY_FAILED"
    assert_output --partial "could not hash $HDIR/rule-ledger/pr1-00000000.json"
}

@test "データの照合は書き換え・削除・追加・ハッシュの取得失敗を見つけ、変わらなければ通る" {
    harness_integrity_snapshot
    run harness_integrity_check_data
    assert_success

    printf '{"date":"2026-10-10","x":1}\n' >"$HDIR/failure-pattern-rates/2026-10-10.json"
    run harness_integrity_check_data
    assert_failure "$HARNESS_INTEGRITY_FAILED"
    assert_output --partial "changed: $HDIR/failure-pattern-rates/2026-10-10.json"
    printf '{"date":"2026-10-10"}\n' >"$HDIR/failure-pattern-rates/2026-10-10.json"

    rm "$HDIR/classifications.jsonl"
    run harness_integrity_check_data
    assert_failure "$HARNESS_INTEGRITY_FAILED"
    assert_output --partial "missing: $HDIR/classifications.jsonl"
    printf '{"session_id":"s"}\n' >"$HDIR/classifications.jsonl"

    printf '{"session_id":"t","epoch":2,"counts":{"repeat":9}}\n' >>"$HDIR/detections.jsonl"
    run harness_integrity_check_data
    assert_failure "$HARNESS_INTEGRITY_FAILED"
    assert_output --partial "changed: $HDIR/detections.jsonl"
    printf '{"session_id":"s","epoch":1,"counts":{}}\n' >"$HDIR/detections.jsonl"

    printf '{"id":"pr2-00000000"}\n' >"$HDIR/rule-ledger/pr2-00000000.json"
    run harness_integrity_check_data
    assert_failure "$HARNESS_INTEGRITY_FAILED"
    assert_output --partial "added: $HDIR/rule-ledger/pr2-00000000.json"
    rm "$HDIR/rule-ledger/pr2-00000000.json"

    chmod 000 "$HDIR/rule-ledger/exported/pr1-00000000.json"
    run harness_integrity_check_data
    assert_failure "$HARNESS_INTEGRITY_FAILED"
    assert_output --partial "could not hash $HDIR/rule-ledger/exported/pr1-00000000.json"
    chmod 644 "$HDIR/rule-ledger/exported/pr1-00000000.json"

    run harness_integrity_check_data
    assert_success
}

@test "データの照合は実行物を見ず、関門と入口はデータを見ない" {
    harness_integrity_snapshot
    printf '# tampered\n' >>"$SCRIPTS/harness-verdict.sh"
    run harness_integrity_check_data
    assert_success
    harness_integrity_snapshot
    printf 'x\n' >>"$HDIR/classifications.jsonl"
    run harness_integrity_gate
    assert_success
}

@test "封印したファイルはデータの照合に加わり、封印の後の書き換えを見つける" {
    harness_integrity_snapshot
    results="$HDIR/eval-results-2026-10-10.json"
    run harness_integrity_sealed "$results"
    assert_failure
    printf '{"cases":[]}\n' >"$results"
    harness_integrity_seal "$results"
    run harness_integrity_sealed "$results"
    assert_success
    run harness_integrity_check_data
    assert_success
    printf '{"cases":[1]}\n' >"$results"
    run harness_integrity_check_data
    assert_failure "$HARNESS_INTEGRITY_FAILED"
    assert_output --partial "changed: $results"
}

@test "データの一覧に入るファイルを封印すれば、追加として扱わない" {
    harness_integrity_snapshot
    record="$HDIR/rule-ledger/pr42-00000000.json"
    printf '{"id":"pr42-00000000"}\n' >"$record"
    harness_integrity_seal "$record"
    run harness_integrity_check_data
    assert_success
}

@test "無いファイルとハッシュを取れないファイルは封印せず、予約コードを返す" {
    harness_integrity_snapshot
    run harness_integrity_seal "$HDIR/eval-results-none.json"
    assert_failure "$HARNESS_INTEGRITY_FAILED"
    printf 'x\n' >"$HDIR/unreadable.json"
    chmod 000 "$HDIR/unreadable.json"
    run harness_integrity_seal "$HDIR/unreadable.json"
    assert_failure "$HARNESS_INTEGRITY_FAILED"
}

@test "入口に渡した前置の環境変数はスクリプトに届く" {
    cat >"$SCRIPTS/harness-eval-cases.sh" <<'EOF'
#!/usr/bin/env bash
printf 'budget=%s\n' "${HARNESS_EVAL_BUDGET_USD:-}"
EOF
    harness_integrity_snapshot
    HARNESS_EVAL_BUDGET_USD=7 run harness_integrity_run "$SCRIPTS/harness-eval-cases.sh" run
    assert_success
    assert_output 'budget=7'
}

# 実行時の一覧(この lib)と CI の Guarded Path の一覧(scripts/guarded-paths.txt)は意味が違うので別々に持つ。
# 代わりに、実行時の一覧にある実行物の Source がすべて Guarded Path であることを確かめる

# <~/.claude の下のパス> の chezmoi の Source を出す。`.` で始まる段は dot_ に、ファイルが executable_ 付きで
# 在ればそれを選ぶ。Source が見つからなければ何も出さずに 1 を返す
source_of() { # <$HOME/.claude/ からの相対パス>
    local rel="dot_claude/$(sed -E 's#(^|/)\.#\1dot_#g' <<<"$1")" executable
    executable="$(dirname "$rel")/executable_$(basename "$rel")"
    if [[ -f "$REPO_ROOT/$executable" ]]; then
        printf '%s\n' "$executable"
    elif [[ -f "$REPO_ROOT/$rel" ]]; then
        printf '%s\n' "$rel"
    else
        return 1
    fi
}

# <Source> が <一覧> の行(完全一致か、末尾 / の行の配下。先頭の + は外す)に当たれば 0
guarded() { # <Source> <一覧のファイル>
    local line
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == '#'* ]] && continue
        line=${line#+}
        if [[ "$line" == */ ]]; then
            [[ "$1" == "$line"* ]] && return 0
        elif [[ "$1" == "$line" ]]; then
            return 0
        fi
    done <"$2"
    return 1
}

# 実行時の一覧の Source のうち、<一覧のファイル> に当たらないものを出す
unguarded_sources() { # <一覧のファイル>
    local path src
    while IFS= read -r path; do
        src=$(source_of "${path#"$HOME/.claude/"}") || {
            printf 'no source: %s\n' "$path"
            continue
        }
        guarded "$src" "$1" || printf '%s\n' "$src"
    done <<<"$(harness_integrity_executables)"
}

@test "実行時の一覧にある実行物の Source は、すべて Guarded Path に載っている" {
    run unguarded_sources "$REPO_ROOT/scripts/guarded-paths.txt"
    assert_success
    assert_output ''
}

@test "Guarded Path から実行物の行が抜けていれば、一覧の検査がそれを見つける" {
    grep -vxF 'dot_claude/scripts/executable_harness-verdict.sh' "$REPO_ROOT/scripts/guarded-paths.txt" \
        >"$BATS_TEST_TMPDIR/guarded.txt"
    run unguarded_sources "$BATS_TEST_TMPDIR/guarded.txt"
    assert_output 'dot_claude/scripts/executable_harness-verdict.sh'
}

@test "この lib とその bats は Guarded Path に載っている" {
    run guarded dot_claude/scripts/lib/harness-integrity.bash "$REPO_ROOT/scripts/guarded-paths.txt"
    assert_success
    run guarded test/harness-integrity.bats "$REPO_ROOT/scripts/guarded-paths.txt"
    assert_success
}
