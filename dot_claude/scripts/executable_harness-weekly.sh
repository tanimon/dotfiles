#!/usr/bin/env bash
# 自己改善ループの週次ジョブの入口(ADR 0012)。launchd が週 1 回起動する。
#
# nono の内側で headless の `claude -p` を実行し、pending のセッションに対して
# 抽出の工程(/harness-reflect 相当)を行う。成功したら heartbeat(最後に成功した
# 時刻)を書き、briefing と doctor がその古さを表示する。
set -euo pipefail

HARNESS_DIR="$HOME/.claude/harness"
HEARTBEAT="$HARNESS_DIR/weekly-heartbeat"
BUDGET_USD="${HARNESS_WEEKLY_BUDGET_USD:-5}"
MAX_SESSIONS="${HARNESS_WEEKLY_MAX_SESSIONS:-30}"

mkdir -p "$HARNESS_DIR"
cd "$HARNESS_DIR"

# 同時実行を防ぐ lock。mkdir の成否で取り合い、持ち主の PID を中に置く。
# 持ち主が死んでいる lock(SIGKILL や電源断で trap が動かなかった実行の残骸)は
# 取り戻す。生きている実行がいれば、それに任せて何もせず終わる(失敗ではない)
LOCK="$HARNESS_DIR/weekly.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    LOCK_PID=$(cat "$LOCK/pid" 2>/dev/null || true)
    if [[ "$LOCK_PID" =~ ^[0-9]+$ ]] && kill -0 "$LOCK_PID" 2>/dev/null; then
        printf 'harness-weekly: already running (pid %s); skipping\n' "$LOCK_PID"
        exit 0
    fi
    rm -rf "$LOCK"
    mkdir "$LOCK"
fi
printf '%s\n' "$$" >"$LOCK/pid"

PENDING="$HARNESS_DIR/pending.jsonl"
JOB_SESSIONS="$HARNESS_DIR/weekly-sessions.txt"

# ジョブ自身のセッションを処理の対象から外す(ADR 0012 の Consequences)。
# 2 段構え: HARNESS_DISABLE で SessionEnd hook に積ませず、それでも積まれた
# (環境変数が nono や hook まで届かなかった)ときのために、起動前に記録した
# session id を pending から外す。外すのは実行の前と後の両方で、前に外すのは
# 前回の実行が後片付けの前に止まった場合の積み残しのため。
# pending は SessionEnd hook が並行に追記するので、読んだ時点の写しを書き戻さず、
# いまのファイルを grep -v で絞って mv する(/harness-reflect の Bookkeeping と同じ)
strip_job_sessions() {
    [[ -s "$JOB_SESSIONS" && -f "$PENDING" ]] || return 0
    local tmp
    tmp=$(mktemp "$HARNESS_DIR/.pending.XXXXXX")
    grep -vF -f <(sed 's/.*/"session_id":"&"/' "$JOB_SESSIONS") "$PENDING" >"$tmp" || true
    mv "$tmp" "$PENDING"
}

SESSION_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
# 記録は起動より前に行い、直近の分だけ残す
printf '%s\n' "$SESSION_ID" >>"$JOB_SESSIONS"
tail -n 20 "$JOB_SESSIONS" >"$JOB_SESSIONS.tmp" && mv "$JOB_SESSIONS.tmp" "$JOB_SESSIONS"
strip_job_sessions
cleanup() {
    strip_job_sessions
    rm -rf "$LOCK"
}
trap cleanup EXIT
export HARNESS_DISABLE=1

# 1 回で扱うセッション数に上限を置き、予算(--max-budget-usd)は歯止めに回す。
# 予算だけに頼ると、溜まった分を 1 回で捌けない週は毎回予算切れで失敗し、
# 進んでいても heartbeat が書かれない。
# セッションごとに「queue へ追記 → pending から外す」を済ませてから次へ進ませるのは、
# 途中で止まっても失うのが高々 1 セッション分で、queue に重複を作らないため
PROMPT="This is the unattended weekly harness job (no human is present, and this session itself is not an input).
Use the harness-reflect skill on the entries in ~/.claude/harness/pending.jsonl, following its rules, with these changes:
- Process at most ${MAX_SESSIONS} entries, oldest recorded_epoch first. Leave the rest in pending.jsonl for the next run.
- Do the Bookkeeping for each entry before starting the next one: append that session's queue entries (if any), then remove that session's line from pending.jsonl.
- Update last_reflect_epoch in state.json once at the end.
- Finish with a one-line summary: sessions analyzed, entries queued, entries dropped."

RESULT=$(nono run --profile claude-seal --allow-cwd -- \
    claude -p "$PROMPT" \
    --settings '{"sandbox":{"enabled":false}}' \
    --dangerously-skip-permissions \
    --max-budget-usd "$BUDGET_USD" \
    --session-id "$SESSION_ID" \
    --output-format json)
printf '%s\n' "$RESULT"

# 予算の上限などで止まった run も exit 0 で終わりうるので、終了コードだけでなく
# 結果の is_error も見る。読めない結果は失敗に倒す(heartbeat が嘘をつかないように)
if ! printf '%s' "$RESULT" | jq -e '.is_error == false' >/dev/null 2>&1; then
    printf 'harness-weekly: claude reported an error; heartbeat not updated\n' >&2
    exit 1
fi

TMP_HEARTBEAT=$(mktemp "$HARNESS_DIR/.weekly-heartbeat.XXXXXX")
date +%s >"$TMP_HEARTBEAT"
mv "$TMP_HEARTBEAT" "$HEARTBEAT"
