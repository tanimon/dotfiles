# 週次ジョブの Loop PR の本文の module(lib/harness-pr-body.bash)の interface の検査。lib を直接 source する。
# 本文の 3 種類の節の順序・節ごとの失敗の扱い・純増の表・失敗の検出と推移の節に渡す日付・選別の prompt の本文の指示はここで
# 検査する。失敗の検出と推移の節の中身(期間と表)は test/harness-failure-rates.bats が再発率のスクリプトで検査する。
# 週次ジョブがこの lib を読み込めないときに止まることと、PR を作る run の本文に節が付く配線は test/harness-weekly.bats、
# Metrics-only PR の入口が commit の後に件数を渡すことは test/harness-loop-pr.bats が検査する。
bats_require_minimum_version 1.5.0

setup() {
    load 'helpers/setup'
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    export HOME="$BATS_TEST_TMPDIR/home"
    HDIR="$HOME/.claude/harness"
    SCRIPTS="$HOME/.claude/scripts"
    mkdir -p "$SCRIPTS" "$HDIR"
    unset STUB_TREND_STATUS STUB_DETECTIONS_STATUS STUB_TAMPER_VERDICT STUB_ADOPTED STUB_ADOPTED_STATUS
    # 偽の再発率のスクリプト。引数を RATES_ARGS に 1 行ずつ書く。detections は失敗の検出の節を出し、STUB_DETECTIONS_STATUS が
    # あればその値で失敗する。trend は推移の節を出し、STUB_TREND_STATUS があればその値で失敗する。STUB_TAMPER_VERDICT が
    # あれば Verdict の CLI を書き換える(推移の照合を通った後に実行物が書き換えられた run の再現)
    export RATES_ARGS="$BATS_TEST_TMPDIR/failure-rates-args"
    cat >"$SCRIPTS/harness-failure-rates.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$RATES_ARGS"
case "$1" in
detections)
    [[ -z "${STUB_DETECTIONS_STATUS:-}" ]] || exit "$STUB_DETECTIONS_STATUS"
    printf '\n## 失敗の検出\n\n合計: 0\n'
    ;;
trend)
    [[ -z "${STUB_TAMPER_VERDICT:-}" ]] || printf '# tampered\n' >>"$HOME/.claude/scripts/harness-verdict.sh"
    [[ -z "${STUB_TREND_STATUS:-}" ]] || exit "$STUB_TREND_STATUS"
    printf '\n## 推移\n\n直近 4 週\n'
    ;;
*) exit 1 ;;
esac
EOF
    # 偽の Verdict の CLI。adopted は印が渡されたことを確かめて STUB_ADOPTED を出し、STUB_ADOPTED_STATUS があればその値で失敗する
    cat >"$SCRIPTS/harness-verdict.sh" <<'EOF'
#!/usr/bin/env bash
[[ "$1 $2" == 'adopted --run' && -n "$3" ]] || exit 1
[[ -z "${STUB_ADOPTED_STATUS:-}" ]] || exit "$STUB_ADOPTED_STATUS"
[[ -z "${STUB_ADOPTED:-}" ]] || printf '%s\n' "$STUB_ADOPTED"
EOF
    # 週次ジョブと同じ順に読む(Integrity Snapshot → Review Outcome → この lib)
    # shellcheck source=../dot_claude/scripts/lib/harness-integrity.bash
    source "$REPO_ROOT/dot_claude/scripts/lib/harness-integrity.bash"
    # shellcheck source=../dot_claude/scripts/lib/harness-review-outcome.bash
    source "$REPO_ROOT/dot_claude/scripts/lib/harness-review-outcome.bash"
    # shellcheck source=../dot_claude/scripts/lib/harness-pr-body.bash
    source "$REPO_ROOT/dot_claude/scripts/lib/harness-pr-body.bash"

    WT="$BATS_TEST_TMPDIR/worktree"
    git init -q "$WT"
    git -C "$WT" config user.email t@example.invalid
    git -C "$WT" config user.name t
    git -C "$WT" config commit.gpgsign false
    printf 'line1\nline2\n' >"$WT/README.md"
    git -C "$WT" add -A
    git -C "$WT" commit -qm base
    BASE=$(git -C "$WT" rev-parse HEAD)
    RESULT="$HDIR/review-result-2026-10-20.json"
    BODY="$HDIR/review-pr-body-2026-10-20.md"
    RUN_MARK="harness/review-2026-10-20 run 0f0e"
    printf '{"dropped":[],"deploy_only":[]}\n' >"$RESULT"
    harness_review_outcome_init --worktree "$WT" --review-result "$RESULT" --pr-body "$BODY" --run "$RUN_MARK" --date 2026-10-20 \
        --rates-repo-dir docs/harness/failure-pattern-rates --ledger-repo-dir docs/harness/rule-ledger
    init_body
}

init_body() {
    harness_pr_body_init --pr-body "$BODY" --worktree "$WT" --review-result "$RESULT" \
        --date 2026-10-20 --run "$RUN_MARK" --ledger-repo-dir docs/harness/rule-ledger
}

# 選別の commit を 1 件足す
review_commit() { # <件名> <パス> <中身>
    mkdir -p "$(dirname "$WT/$2")"
    printf '%s' "$3" >>"$WT/$2"
    git -C "$WT" add -A
    git -C "$WT" commit -qm "$1"
}

claude_head() {
    printf '## 採用\n\n- entry(理由: 同じ失敗の再発を防ぐため)\n' >"$BODY"
}

review() { # [<評価の節>]
    harness_integrity_snapshot
    run --separate-stderr harness_pr_body_review "$BASE" "${1-$'\n## ルールの効果\n\n効果'}"
}

# 本文の見出しを出現順に出す
headings() {
    grep '^## ' "$BODY"
}

@test "採用のある PR の本文: 選別の本文の後ろに Review Outcome の節・検出件数・推移・評価・純増・Rule Ledger の節をこの順に足す" {
    claude_head
    printf '{"dropped":["entry 2(lint)"],"deploy_only":[]}\n' >"$RESULT"
    review_commit 'harness: add rule' rules/new.md $'a\nb\nc\n'
    export STUB_ADOPTED='entry'
    review
    assert_success
    run headings
    assert_output "$(printf '%s\n' '## 採用' '## 落とした変更' '## 失敗の検出' '## 推移' '## ルールの効果' '## 純増' '## Rule Ledger')"
    run grep -F '採用したルールの記録(docs/harness/rule-ledger)' "$BODY"
    assert_success
}

@test "純増: commit ごとの行と、ファイルごとの表と合計を載せる" {
    review_commit 'harness: add rule' rules/new.md $'a\nb\nc\n'
    printf 'line1\nchanged\n' >"$WT/README.md"
    printf 'x\n' >>"$WT/README.md"
    git -C "$WT" commit -qam 'harness: fix readme'
    review
    assert_success
    run cat "$BODY"
    assert_line '| harness: add rule | +3 | -0 |'
    assert_line '| harness: fix readme | +2 | -1 |'
    assert_line '| `rules/new.md` | +3 | -0 |'
    assert_line '| `README.md` | +2 | -1 |'
    assert_line '合計: +5 / -1(純増 +4 行)'
}

@test "純増: 同じファイルに触れる採用が複数あっても commit ごとに数え、件名の | をエスケープする" {
    review_commit 'harness: first | entry' rules/shared.md $'a\nb\n'
    review_commit 'harness: second entry' rules/shared.md $'c\nd\ne\n'
    review
    assert_success
    run cat "$BODY"
    assert_line '| harness: first \| entry | +2 | -0 |'
    assert_line '| harness: second entry | +3 | -0 |'
    assert_line '| `rules/shared.md` | +5 | -0 |'
    assert_line '合計: +5 / -0(純増 +5 行)'
}

@test "純増: 1 つの commit が複数のファイルに触れれば、削除も含めてその commit の行に合算する" {
    mkdir -p "$WT/rules"
    printf 'a\nb\nc\n' >"$WT/rules/new.md"
    printf 'line1\nchanged\n' >"$WT/README.md"
    git -C "$WT" add -A
    git -C "$WT" commit -qm 'harness: add rule'
    review
    assert_success
    run cat "$BODY"
    assert_line '| harness: add rule | +4 | -1 |'
    assert_line '合計: +4 / -1(純増 +3 行)'
}

@test "純増: バイナリファイルは行数の代わりにバイナリと書いて合計から外し、パスの | はエスケープする" {
    printf '\000\001\002' >"$WT/blob.bin"
    printf 'x\n' >"$WT/a|b.md"
    git -C "$WT" add -A
    git -C "$WT" commit -qm 'harness: binary'
    review
    assert_success
    run cat "$BODY"
    assert_line '| harness: binary(バイナリ 1 件を除く) | +1 | -0 |'
    assert_line '| `blob.bin` | バイナリ | バイナリ |'
    assert_line '| `a\|b.md` | +1 | -0 |'
    assert_line '合計: +1 / -0(純増 +1 行)'
    assert_line 'バイナリファイル 1 件は行数に含めない。'
}

@test "純増を数えられなければ 1 を返し、Rule Ledger の節に進まない" {
    review_commit 'harness: add rule' rules/new.md $'a\n'
    export STUB_ADOPTED='entry'
    harness_integrity_snapshot
    run --separate-stderr harness_pr_body_review 0000000000000000000000000000000000000000 ''
    assert_failure 1
    run grep -c '^## Rule Ledger' "$BODY"
    assert_output 0
}

@test "失敗の検出と推移の節には、どちらにも初期化で受け取った run の日付を渡す" {
    review
    assert_success
    run cat "$RATES_ARGS"
    assert_output "$(printf '%s\n' 'detections 2026-10-20' 'trend 2026-10-20 --weeks 4')"
}

@test "失敗の検出の節を組み立てられなければ(その日の Weekly Rate Record が無い、など)、WARN を出して節を省き、ほかの節は足す" {
    export STUB_DETECTIONS_STATUS=1
    review
    assert_success
    assert_equal "$stderr" "harness-weekly: WARN failed to build the failure detection counts; left it out of $BODY"
    run headings
    assert_output "$(printf '%s\n' '## 推移' '## ルールの効果' '## 純増')"
}

@test "Metrics-only PR の本文: 失敗の検出の節を組み立てられなくても、WARN を出して節を省き成功する" {
    export STUB_DETECTIONS_STATUS=1
    harness_integrity_snapshot
    run --separate-stderr harness_pr_body_metrics_only 4 0
    assert_success
    assert_equal "$stderr" "harness-weekly: WARN failed to build the failure detection counts; left it out of $BODY"
    run headings
    assert_output '## 推移'
}

@test "推移がほかの理由で作れなければ、WARN を出して節を省き、PR の公開は止めない" {
    export STUB_TREND_STATUS=1
    review
    assert_success
    assert_equal "$stderr" "harness-weekly: WARN failed to build the failure rate trend; left it out of $BODY"
    run grep -c '^## 推移' "$BODY"
    assert_output 0
    run grep -c '^## 純増' "$BODY"
    assert_output 1
}

@test "再発率のスクリプトが書き換えられていたら、PR を作らない理由を出して予約コードを返し、後ろの節を足さない" {
    harness_integrity_snapshot
    printf '# tampered\n' >>"$SCRIPTS/harness-failure-rates.sh"
    run --separate-stderr harness_pr_body_review "$BASE" $'\n## ルールの効果'
    assert_failure "$HARNESS_INTEGRITY_FAILED"
    # 失敗の検出の節が推移より先に呼ぶので、その照合で止まる
    local errors=$stderr
    run grep -F "harness-weekly: the failure detection counts could not be trusted; left it out of $BODY" <<<"$errors"
    assert_success
    run grep -F 'harness-weekly: no PR created; the failure detection counts could not be trusted' <<<"$errors"
    assert_success
    run grep -c '^## 失敗の検出\|^## 推移\|^## ルールの効果\|^## 純増' "$BODY"
    assert_output 0
}

@test "採用を読めなければ Rule Ledger の節を省いて WARN を出し、採用が無ければ節を足さない" {
    export STUB_ADOPTED_STATUS=1
    review
    assert_success
    assert_equal "$stderr" "harness-weekly: WARN could not read the adopted verdicts from $HDIR/queue-archive.md; left the Rule Ledger section out of $BODY"
    run grep -c '^## Rule Ledger' "$BODY"
    assert_output 0
    rm -f "$BODY"
    unset STUB_ADOPTED_STATUS
    review
    assert_success
    run grep -c '^## Rule Ledger' "$BODY"
    assert_output 0
}

@test "推移の節の後に Verdict の CLI が書き換えられていたら、PR を作らない理由を出して予約コードを返す" {
    # 入口は呼ぶたびに実行物の全部を照合するので、推移の照合を通った後に書き換える(推移のスクリプトの実行中)
    export STUB_TAMPER_VERDICT=1
    harness_integrity_snapshot
    run --separate-stderr harness_pr_body_review "$BASE" ''
    assert_failure "$HARNESS_INTEGRITY_FAILED"
    run grep -F 'harness-weekly: no PR created; the Verdict CLI could not be trusted' <<<"$stderr"
    assert_success
}

@test "Metrics-only PR の本文: 前の内容を捨て、件数の文・推移・検出件数の順に書く" {
    printf '前の run の本文\n' >"$BODY"
    harness_integrity_snapshot
    run --separate-stderr harness_pr_body_metrics_only 4 2
    assert_success
    run sed -n 1p "$BODY"
    assert_output '採用した変更は無い。origin/main に無い週の Failure Pattern の再発率の記録が 4 週分たまったので、記録だけを commit した。'
    run sed -n 3p "$BODY"
    assert_output 'マージ済みの PR の Rule Ledger の記録のうち、まだ載っていなかった 2 件も足した(docs/harness/rule-ledger)。'
    run headings
    assert_output "$(printf '%s\n' '## 推移' '## 失敗の検出')"
    run grep -c '前の run の本文' "$BODY"
    assert_output 0
}

@test "Metrics-only PR の本文: 持ち越した Rule Ledger の記録が無ければ、その文を書かない" {
    harness_integrity_snapshot
    run --separate-stderr harness_pr_body_metrics_only 4 0
    assert_success
    run grep -c 'Rule Ledger' "$BODY"
    assert_output 0
}

@test "Metrics-only PR の本文: 推移のスクリプトが書き換えられていたら、予約コードを返し検出件数の節を足さない" {
    harness_integrity_snapshot
    printf '# tampered\n' >>"$SCRIPTS/harness-failure-rates.sh"
    run --separate-stderr harness_pr_body_metrics_only 4 0
    assert_failure "$HARNESS_INTEGRITY_FAILED"
    # 次の run が $stderr を空にするので退避する
    local errors=$stderr
    run grep -F "harness-weekly: the failure rate trend could not be trusted; left it out of $BODY" <<<"$errors"
    assert_success
    run grep -F 'harness-weekly: no PR created; the failure rate trend could not be trusted' <<<"$errors"
    assert_success
    run grep -c '^## ' "$BODY"
    assert_output 0
}

@test "Metrics-only PR の本文: 件数の文を書けなければ、PR を作らない理由を出して 1 を返し、推移の節に進まない" {
    BODY="$BATS_TEST_TMPDIR/missing/review-pr-body.md"
    init_body
    export STUB_TAMPER_VERDICT=1
    harness_integrity_snapshot
    run --separate-stderr harness_pr_body_metrics_only 4 2
    assert_failure 1
    run grep -F "harness-weekly: failed to write the record counts to $BODY; no PR created" <<<"$stderr"
    assert_success
    # 推移のスクリプトが走っていれば Verdict の CLI を書き換えている
    run grep -c tampered "$SCRIPTS/harness-verdict.sh"
    assert_output 0
}

@test "Metrics-only PR の本文: 件数が数でなければ何も書かずに使い方の誤りで終わる" {
    run --separate-stderr harness_pr_body_metrics_only 4
    assert_failure 2
    run --separate-stderr harness_pr_body_metrics_only four 0
    assert_failure 2
    assert [ ! -e "$BODY" ]
}

@test "手で公開する本文: データを信頼できれば Review Outcome の節・検出件数・推移を足して 0 を返す" {
    claude_head
    printf '{"dropped":["entry 2(lint)"],"deploy_only":[]}\n' >"$RESULT"
    harness_integrity_snapshot
    run --separate-stderr harness_pr_body_failed_review 1
    assert_success
    run headings
    assert_output "$(printf '%s\n' '## 採用' '## 落とした変更' '## 失敗の検出' '## 推移')"
}

@test "手で公開する本文: データを信頼できなければ Review Outcome の節だけを足して予約コードを返す" {
    printf '{"dropped":["entry 2(lint)"],"deploy_only":[]}\n' >"$RESULT"
    harness_integrity_snapshot
    run --separate-stderr harness_pr_body_failed_review 0
    assert_failure "$HARNESS_INTEGRITY_FAILED"
    run headings
    assert_output '## 落とした変更'
}

@test "手で公開する本文: 推移のスクリプトが書き換えられていたら予約コードを返す(信頼できる側の対)" {
    harness_integrity_snapshot
    printf '# tampered\n' >>"$SCRIPTS/harness-failure-rates.sh"
    run --separate-stderr harness_pr_body_failed_review 1
    assert_failure "$HARNESS_INTEGRITY_FAILED"
    run grep -c '^## 推移' "$BODY"
    assert_output 0
}

@test "手で公開する本文: 推移がほかの理由で作れないだけなら 0 を返す" {
    export STUB_TREND_STATUS=1
    harness_integrity_snapshot
    run --separate-stderr harness_pr_body_failed_review 1
    assert_success
}

@test "評価の節が空なら、評価の工程が失敗したとして効果を測っていないことを書いた節を足す" {
    review ''
    assert_success
    run cat "$BODY"
    assert_line '## ルールの効果'
    assert_line '評価の工程が失敗したため、この PR のルールの効果は測っていない(週次ジョブのログを参照)。'
}

@test "採用の見出しは、この run の印で Verdict の CLI に問い合わせて出す" {
    cat >"$SCRIPTS/harness-verdict.sh" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "adopted --run harness/review-2026-10-20 run 0f0e" ]] || exit 1
printf 'entry 1\nentry 2\n'
EOF
    harness_integrity_snapshot
    run --separate-stderr harness_pr_body_adopted_titles
    assert_success
    assert_output "$(printf '%s\n' 'entry 1' 'entry 2')"
}

@test "選別の prompt の本文の指示は、本文のパスと、ジョブが足すので書かせないものをすべて挙げる" {
    run harness_pr_body_review_instructions
    assert_success
    assert_output --partial "Write the PR body (in Japanese) to ${BODY}:"
    local item
    for item in 'line counts' 'failure detection counts' 'failure pattern rates' 'rule effects' 'dropped changes' 'deploy-only fixes'; do
        assert_output --partial "$item"
    done
}

@test "初期化は値が欠けているか知らない引数なら使い方の誤りで終わり、初期化の前の入口も使い方の誤りになる" {
    run harness_pr_body_init --pr-body "$BODY"
    assert_failure 2
    run harness_pr_body_init --pr-body "$BODY" --worktree "$WT" --review-result "$RESULT" --date 2026-10-20 \
        --run "$RUN_MARK" --ledger-repo-dir docs/harness/rule-ledger --detection-since 1760000000
    assert_failure 2
    assert_output --partial 'unknown argument --detection-since'
    # 初期化していない lib は、週次ジョブと同じ順に読み込み直した別の bash で作る
    run bash -c 'for lib in integrity review-outcome pr-body; do source "$1/harness-$lib.bash"; done
        harness_pr_body_metrics_only 4 0' _ "$REPO_ROOT/dot_claude/scripts/lib"
    assert_failure 2
    assert_output --partial 'harness-pr-body: call harness_pr_body_init first'
}

# <Source> が <一覧> の行(完全一致)に当たれば 0
guarded() { # <Source> <一覧のファイル>
    grep -qxF "$1" "$2"
}

@test "この lib とその bats は Guarded Path に載っている" {
    run guarded dot_claude/scripts/lib/harness-pr-body.bash "$REPO_ROOT/scripts/guarded-paths.txt"
    assert_success
    run guarded test/harness-pr-body.bats "$REPO_ROOT/scripts/guarded-paths.txt"
    assert_success
}
