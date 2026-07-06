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

HARNESS_DIR="$HOME/.claude/harness"
SETTINGS="$HOME/.claude/settings.json"

ok=0
command -v jq >/dev/null 2>&1 || ok=1
check "$ok" "jq available" "brew install jq"
[[ "$ok" -ne 0 ]] && exit 1

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
check "$ok" "harness dir writable ($HARNESS_DIR)" "check permissions on $HARNESS_DIR"

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
            if [[ "$AGE_DAYS" -ge 7 ]]; then
                printf 'WARN: SessionEnd trigger last ran %sd ago — if sessions ended since, the hook may be dead\n' "$AGE_DAYS"
            else
                printf 'PASS: SessionEnd trigger ran %sd ago\n' "$AGE_DAYS"
            fi
        fi
    else
        printf 'WARN: SessionEnd trigger has never recorded a run (fresh install?)\n'
    fi
fi

exit "$FAILED"
