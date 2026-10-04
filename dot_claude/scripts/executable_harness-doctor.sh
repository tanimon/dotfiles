#!/usr/bin/env bash
# Deterministic liveness check for the harness self-improvement loop.
# Run standalone (bash ~/.claude/scripts/harness-doctor.sh) or as step 1 of
# /harness-review. Prints PASS/FAIL/WARN per check; exits 1 if any FAIL.
set -euo pipefail

FAILED=0

check() { # <ok flag: 0 ok / nonzero fail> <label> <remedy>
    if [[ "$1" -eq 0 ]]; then
        printf 'PASS: %s\n' "$2"
    else
        printf 'FAIL: %s — %s\n' "$2" "$3"
        FAILED=1
    fi
}

SETTINGS="$HOME/.claude/settings.json"
TRIGGER_STALE_WARN_DAYS=7

ok=0
command -v jq >/dev/null 2>&1 || ok=1
check "$ok" "jq available" "brew install jq"
[[ "$ok" -ne 0 ]] && exit 1

# 週次ジョブの健全性の判定と状態ディレクトリの場所は lib にある。読めなければ以降の検査ができない。
# 素の source は無い・構文エラー・空の lib で黙って落ちるので、briefing と同じ順に確かめる
HEALTH_LIB="$(dirname "${BASH_SOURCE[0]}")/lib/harness-health.bash"
ok=0
if [[ -r "$HEALTH_LIB" ]] && "$BASH" -n "$HEALTH_LIB"; then
    # shellcheck source-path=SCRIPTDIR
    # shellcheck source=lib/harness-health.bash
    source "$HEALTH_LIB" || ok=1
    declare -F harness_health_dir harness_health_weekly >/dev/null || ok=1
else
    ok=1
fi
check "$ok" "lib/harness-health.bash deployed and loadable ($HEALTH_LIB)" "run 'chezmoi apply'"
[[ "$ok" -ne 0 ]] && exit 1
HARNESS_DIR=$(harness_health_dir)

ok=0
[[ -f "$SETTINGS" ]] && grep -q 'harness-reflect-trigger.sh' "$SETTINGS" || ok=1
check "$ok" "SessionEnd reflect-trigger hook wired in settings.json" "run 'chezmoi apply' (source: dot_claude/settings.json.tmpl)"

ok=0
[[ -f "$SETTINGS" ]] && grep -q 'harness-briefing.sh' "$SETTINGS" || ok=1
check "$ok" "SessionStart briefing hook wired in settings.json" "run 'chezmoi apply' (source: dot_claude/settings.json.tmpl)"

for script in harness-reflect-trigger.sh harness-briefing.sh; do
    ok=0
    [[ -x "$HOME/.claude/scripts/$script" ]] || ok=1
    check "$ok" "$script deployed and executable" "run 'chezmoi apply'"
done

for skill in harness-reflect harness-review; do
    ok=0
    [[ -f "$HOME/.claude/skills/$skill/SKILL.md" ]] || ok=1
    check "$ok" "skill $skill deployed" "run 'chezmoi apply'"
done

ok=0
mkdir -p "$HARNESS_DIR" 2>/dev/null || ok=1
if [[ "$ok" -eq 0 ]]; then
    probe="$HARNESS_DIR/.doctor-probe.$$"
    touch "$probe" 2>/dev/null && rm -f "$probe" || ok=1
fi
check "$ok" "harness dir writable ($HARNESS_DIR)" "check permissions on $HARNESS_DIR (inside the Claude Code Bash sandbox, confirm ~/.claude/harness is in sandbox.filesystem.allowWrite; under nono, check the claude-seal profile's write grants)"

if [[ -f "$HARNESS_DIR/state.json" ]]; then
    ok=0
    jq empty "$HARNESS_DIR/state.json" 2>/dev/null || ok=1
    check "$ok" "state.json parseable" "delete $HARNESS_DIR/state.json (it will re-bootstrap)"
fi

if [[ -f "$HARNESS_DIR/pending.jsonl" && -s "$HARNESS_DIR/pending.jsonl" ]]; then
    ok=0
    jq -c . <"$HARNESS_DIR/pending.jsonl" >/dev/null 2>&1 || ok=1
    check "$ok" "pending.jsonl lines parseable" "remove the malformed lines from $HARNESS_DIR/pending.jsonl"
fi

# Trigger recency is a WARN, not FAIL: no session may simply have ended lately.
if [[ -f "$HARNESS_DIR/state.json" ]] && jq empty "$HARNESS_DIR/state.json" 2>/dev/null; then
    LAST_TRIGGER=$(jq -r '.last_trigger_epoch // empty' "$HARNESS_DIR/state.json")
    if [[ -n "$LAST_TRIGGER" ]]; then
        if ! [[ "$LAST_TRIGGER" =~ ^[0-9]+$ ]]; then
            printf 'WARN: state.json has a non-numeric last_trigger_epoch\n'
        else
            AGE_DAYS=$((($(date +%s) - LAST_TRIGGER) / 86400))
            if [[ "$AGE_DAYS" -ge "$TRIGGER_STALE_WARN_DAYS" ]]; then
                printf 'WARN: SessionEnd trigger last ran %sd ago — if sessions ended since, the hook may be dead\n' "$AGE_DAYS"
            else
                printf 'PASS: SessionEnd trigger ran %sd ago\n' "$AGE_DAYS"
            fi
        fi
    else
        printf 'WARN: SessionEnd trigger has never recorded a run (fresh install?)\n'
    fi
fi

# 週次ジョブ(ADR 0012)。level をそのまま WARN / FAIL にする(判定は lib)
WEEKLY_OUT=""
if ! WEEKLY_OUT=$(harness_health_weekly); then
    check 1 "weekly job health judged" "run bash -x on $HEALTH_LIB to see where harness_health_weekly fails"
fi
while IFS=$'\t' read -r level message; do
    case $level in
    ok) printf 'PASS: %s\n' "$message" ;;
    warn) printf 'WARN: %s\n' "$message" ;;
    fail)
        printf 'FAIL: %s\n' "$message"
        FAILED=1
        ;;
    esac
done <<<"$WEEKLY_OUT"

exit "$FAILED"
