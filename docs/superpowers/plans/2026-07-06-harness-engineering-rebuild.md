# Harness Engineering System Rebuild Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the dead ECC/CI-based harness self-improvement machinery with a minimal local loop: deterministic hooks record sessions, `/harness-reflect` extracts learnings into a queue, `/harness-review` triages the queue into human-reviewed PRs.

**Architecture:** Two skills (reflect, review) do all LLM work; three deterministic bash scripts (reflect-trigger, briefing, doctor) do all monitoring. Runtime state lives in `~/.claude/harness/` (chezmoi-ignored). The SessionStart briefing prints a status line every session so silence itself signals failure.

**Tech Stack:** bash + jq, chezmoi templates, Claude Code hooks (SessionEnd/SessionStart), SKILL.md skills, Makefile smoke tests.

**Spec:** `docs/superpowers/specs/2026-07-06-harness-engineering-rebuild-design.md`

## Global Constraints

- All shell scripts start with `#!/usr/bin/env bash` + `set -euo pipefail` and must pass `shellcheck` and `shfmt -d -i 4`.
- Hook exit code contract: intentional skip = `exit 0`; error = `exit 1` + stderr message. Hooks must NEVER break session start/end (wrap risky parsing, default to exit 0).
- New scripts are NOT `.tmpl` (no template vars needed — use `$HOME` at runtime) so they stay under shellcheck/shfmt coverage.
- Agent-facing docs (SKILL.md, rules, CLAUDE.md) in English. PR bodies in Japanese.
- Timestamps in runtime state are epoch seconds (`date +%s`), never ISO strings (macOS/Linux `date` parsing divergence).
- Runtime state dir: `~/.claude/harness/` — never chezmoi-managed.
- Never edit deployed targets under `~/` — edit chezmoi source only. Deployment/runtime verification happens after merge + `chezmoi apply`.
- Commit after every task. Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Working branch: current worktree branch (`claude/heuristic-tharp-9cfc56`).

---

### Task 1: SessionEnd reflect-trigger script

**Files:**
- Create: `dot_claude/scripts/executable_harness-reflect-trigger.sh`
- Modify: `Makefile` (add `test-harness-scripts` target; add to `.PHONY` and `lint` deps)

**Interfaces:**
- Consumes: SessionEnd hook stdin JSON (`{"session_id": "...", "transcript_path": "...", "cwd": "..."}`).
- Produces: appends `{"session_id","transcript_path","cwd","recorded_epoch"}` lines to `~/.claude/harness/pending.jsonl`; sets `.last_trigger_epoch` in `~/.claude/harness/state.json`. Tasks 2, 3, 5 read these files/fields by exactly these names.

- [ ] **Step 1: Write the failing smoke tests**

Add to `Makefile` — extend `.PHONY` (line 1) and the `lint` target (line 25) with `test-harness-scripts`, then append this target at the end of the file:

```make
## Smoke test harness loop scripts (reflect-trigger, briefing, doctor)
test-harness-scripts:
	@if ! command -v jq >/dev/null 2>&1; then echo "WARNING: jq not found, skipping"; exit 0; fi
	@echo "Testing harness-reflect-trigger.sh..."
	@SCRIPT="$$(pwd)/dot_claude/scripts/executable_harness-reflect-trigger.sh"; \
	tmphome=$$(mktemp -d /tmp/test-harness-trigger-XXXXXX); \
	cleanup() { rm -rf "$$tmphome"; }; \
	transcript="$$tmphome/big.jsonl"; \
	for i in $$(seq 1 12); do printf '{"type":"assistant","message":{}}\n' >> "$$transcript"; done; \
	echo "  Test 1: substantial session is recorded..."; \
	printf '{"session_id":"sess-big","transcript_path":"%s","cwd":"/tmp"}' "$$transcript" | HOME="$$tmphome" bash "$$SCRIPT" || { echo "  FAIL: non-zero exit"; cleanup; exit 1; }; \
	pending="$$tmphome/.claude/harness/pending.jsonl"; \
	if [ -f "$$pending" ] && jq -e 'select(.session_id == "sess-big") | .transcript_path and .recorded_epoch' "$$pending" >/dev/null 2>&1; then \
		echo "  PASS: pending.jsonl has sess-big entry"; \
	else \
		echo "  FAIL: expected sess-big in pending.jsonl"; cleanup; exit 1; \
	fi; \
	echo "  Test 2: state.json records last_trigger_epoch..."; \
	if jq -e '.last_trigger_epoch > 0' "$$tmphome/.claude/harness/state.json" >/dev/null 2>&1; then \
		echo "  PASS: last_trigger_epoch set"; \
	else \
		echo "  FAIL: last_trigger_epoch missing"; cleanup; exit 1; \
	fi; \
	echo "  Test 3: duplicate session_id is not appended twice..."; \
	printf '{"session_id":"sess-big","transcript_path":"%s","cwd":"/tmp"}' "$$transcript" | HOME="$$tmphome" bash "$$SCRIPT"; \
	count=$$(grep -c 'sess-big' "$$pending"); \
	if [ "$$count" -eq 1 ]; then \
		echo "  PASS: still exactly 1 entry"; \
	else \
		echo "  FAIL: expected 1 entry, got $$count"; cleanup; exit 1; \
	fi; \
	echo "  Test 4: short session is skipped..."; \
	shortt="$$tmphome/short.jsonl"; \
	printf '{"type":"assistant","message":{}}\n' > "$$shortt"; \
	printf '{"session_id":"sess-short","transcript_path":"%s","cwd":"/tmp"}' "$$shortt" | HOME="$$tmphome" bash "$$SCRIPT" || { echo "  FAIL: non-zero exit on short session"; cleanup; exit 1; }; \
	if grep -q 'sess-short' "$$pending"; then \
		echo "  FAIL: short session was recorded"; cleanup; exit 1; \
	else \
		echo "  PASS: short session skipped"; \
	fi; \
	echo "  Test 5: malformed stdin exits 0..."; \
	if printf 'not json at all' | HOME="$$tmphome" bash "$$SCRIPT"; then \
		echo "  PASS: exit 0 on malformed stdin"; \
	else \
		echo "  FAIL: expected exit 0 on malformed stdin"; cleanup; exit 1; \
	fi; \
	echo "  Test 6: missing transcript file exits 0 without recording..."; \
	before=$$(wc -l < "$$pending"); \
	printf '{"session_id":"sess-gone","transcript_path":"%s/nonexistent.jsonl","cwd":"/tmp"}' "$$tmphome" | HOME="$$tmphome" bash "$$SCRIPT" || { echo "  FAIL: non-zero exit"; cleanup; exit 1; }; \
	after=$$(wc -l < "$$pending"); \
	if [ "$$before" -eq "$$after" ]; then \
		echo "  PASS: nothing recorded for missing transcript"; \
	else \
		echo "  FAIL: entry recorded despite missing transcript"; cleanup; exit 1; \
	fi; \
	echo "  Test 7: HARNESS_DISABLE=1 skips..."; \
	printf '{"session_id":"sess-disabled","transcript_path":"%s","cwd":"/tmp"}' "$$transcript" | HOME="$$tmphome" HARNESS_DISABLE=1 bash "$$SCRIPT" || { echo "  FAIL: non-zero exit"; cleanup; exit 1; }; \
	if grep -q 'sess-disabled' "$$pending"; then \
		echo "  FAIL: recorded despite HARNESS_DISABLE"; cleanup; exit 1; \
	else \
		echo "  PASS: HARNESS_DISABLE respected"; \
	fi; \
	cleanup
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test-harness-scripts`
Expected: FAIL (script file does not exist yet — bash reports "No such file or directory").

- [ ] **Step 3: Write the script**

Create `dot_claude/scripts/executable_harness-reflect-trigger.sh`:

```bash
#!/usr/bin/env bash
# SessionEnd hook: record the ended session for later harness reflection.
#
# Deterministic by design — no LLM here. Appends one JSON line per substantial
# session to ~/.claude/harness/pending.jsonl; the /harness-reflect skill
# consumes it in the next interactive session (deferred analysis, see
# docs/superpowers/specs/2026-07-06-harness-engineering-rebuild-design.md).
#
# Exit code contract: intentional skip = 0. This hook must never break
# session teardown, so every parse failure degrades to exit 0.
set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

# Opt-out guard (also keeps scripted/CI runs from polluting the queue)
[[ -n "${HARNESS_DISABLE:-}" ]] && exit 0

STDIN_JSON=$(cat) || exit 0
SESSION_ID=$(printf '%s' "$STDIN_JSON" | jq -r '.session_id // empty' 2>/dev/null) || exit 0
[[ -z "$SESSION_ID" ]] && exit 0
TRANSCRIPT=$(printf '%s' "$STDIN_JSON" | jq -r '.transcript_path // empty' 2>/dev/null) || exit 0
CWD=$(printf '%s' "$STDIN_JSON" | jq -r '.cwd // empty' 2>/dev/null) || CWD=""

HARNESS_DIR="$HOME/.claude/harness"
PENDING="$HARNESS_DIR/pending.jsonl"
STATE="$HARNESS_DIR/state.json"
mkdir -p "$HARNESS_DIR"

# Record the trigger attempt (atomic tmp+rename; corrupt state resets to {}).
NOW_EPOCH=$(date +%s)
STATE_JSON="{}"
[[ -f "$STATE" ]] && STATE_JSON=$(cat "$STATE" 2>/dev/null || printf '{}')
printf '%s' "$STATE_JSON" | jq empty 2>/dev/null || STATE_JSON="{}"
TMP_STATE=$(mktemp "$HARNESS_DIR/.state.XXXXXX")
printf '%s' "$STATE_JSON" | jq --argjson now "$NOW_EPOCH" '.last_trigger_epoch = $now' >"$TMP_STATE"
mv "$TMP_STATE" "$STATE"

[[ -z "$TRANSCRIPT" || ! -f "$TRANSCRIPT" ]] && exit 0

# Gate: only sessions with enough assistant turns plausibly contain learnings.
TURN_THRESHOLD=10
TURNS=$(grep -c '"type":"assistant"' "$TRANSCRIPT" 2>/dev/null || true)
TURNS=${TURNS:-0}
[[ "$TURNS" -lt "$TURN_THRESHOLD" ]] && exit 0

# Dedupe: a resumed session ends again under the same session_id.
if [[ -f "$PENDING" ]] && grep -q "\"session_id\":\"$SESSION_ID\"" "$PENDING"; then
    exit 0
fi

jq -cn \
    --arg sid "$SESSION_ID" \
    --arg tp "$TRANSCRIPT" \
    --arg cwd "$CWD" \
    --argjson at "$NOW_EPOCH" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, recorded_epoch: $at}' >>"$PENDING"

exit 0
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test-harness-scripts && make shellcheck shfmt`
Expected: all 7 `PASS` lines for the trigger; shellcheck/shfmt clean.

- [ ] **Step 5: Commit**

```bash
git add Makefile dot_claude/scripts/executable_harness-reflect-trigger.sh
git commit -m "feat(harness): add SessionEnd reflect-trigger script

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: SessionStart briefing script

**Files:**
- Create: `dot_claude/scripts/executable_harness-briefing.sh`
- Modify: `Makefile` (extend `test-harness-scripts`)

**Interfaces:**
- Consumes: `~/.claude/harness/state.json` (`.last_review_epoch`), `pending.jsonl` (`.recorded_epoch`), `queue.md` (entries are `^## ` headers) — as produced by Task 1 / Task 5 skills.
- Produces: one stdout status block per session (SessionStart stdout enters context). Bootstraps missing harness files. Always exits 0.

- [ ] **Step 1: Write the failing smoke tests**

Append inside the `test-harness-scripts` target (after the trigger block):

```make
	@echo "Testing harness-briefing.sh..."
	@SCRIPT="$$(pwd)/dot_claude/scripts/executable_harness-briefing.sh"; \
	tmphome=$$(mktemp -d /tmp/test-harness-briefing-XXXXXX); \
	cleanup() { rm -rf "$$tmphome"; }; \
	hdir="$$tmphome/.claude/harness"; \
	echo "  Test 1: fresh install bootstraps and prints OK..."; \
	output=$$(HOME="$$tmphome" bash "$$SCRIPT") || { echo "  FAIL: non-zero exit"; cleanup; exit 1; }; \
	if echo "$$output" | grep -q '^Harness: OK' && [ -f "$$hdir/state.json" ] && [ -f "$$hdir/queue.md" ]; then \
		echo "  PASS: bootstrapped, prints OK with 'last review: never'"; \
	else \
		echo "  FAIL: expected OK line and bootstrapped files, got: $$output"; cleanup; exit 1; \
	fi; \
	echo "  Test 2: review overdue with queued work warns with remedy..."; \
	old=$$(( $$(date +%s) - 30*86400 )); \
	printf '{"version":1,"last_review_epoch":%s}' "$$old" > "$$hdir/state.json"; \
	printf '## [2026-07-01] some candidate\n- **Status:** pending\n' >> "$$hdir/queue.md"; \
	output=$$(HOME="$$tmphome" bash "$$SCRIPT"); \
	if echo "$$output" | grep -q 'ATTENTION' && echo "$$output" | grep -q 'overdue' && echo "$$output" | grep -q '/harness-review'; then \
		echo "  PASS: overdue warning with remediation command"; \
	else \
		echo "  FAIL: expected overdue warning, got: $$output"; cleanup; exit 1; \
	fi; \
	echo "  Test 3: fresh review prints OK with queue count..."; \
	now=$$(date +%s); \
	printf '{"version":1,"last_review_epoch":%s}' "$$now" > "$$hdir/state.json"; \
	output=$$(HOME="$$tmphome" bash "$$SCRIPT"); \
	if echo "$$output" | grep -q '^Harness: OK | queue: 1 | pending: 0 | last review: 0d ago'; then \
		echo "  PASS: OK line with counts"; \
	else \
		echo "  FAIL: expected OK line with counts, got: $$output"; cleanup; exit 1; \
	fi; \
	echo "  Test 4: pending pile-up warns..."; \
	for i in 1 2 3 4 5 6; do printf '{"session_id":"s%s","transcript_path":"/tmp/t","cwd":"/tmp","recorded_epoch":%s}\n' "$$i" "$$now" >> "$$hdir/pending.jsonl"; done; \
	output=$$(HOME="$$tmphome" bash "$$SCRIPT"); \
	if echo "$$output" | grep -q 'unreflected sessions' && echo "$$output" | grep -q '/harness-reflect'; then \
		echo "  PASS: pending pile-up warning"; \
	else \
		echo "  FAIL: expected pending warning, got: $$output"; cleanup; exit 1; \
	fi; \
	echo "  Test 5: corrupt state.json warns but exits 0..."; \
	printf 'not json' > "$$hdir/state.json"; \
	output=$$(HOME="$$tmphome" bash "$$SCRIPT") || { echo "  FAIL: non-zero exit on corrupt state"; cleanup; exit 1; }; \
	if echo "$$output" | grep -q 'corrupt'; then \
		echo "  PASS: corrupt state warned"; \
	else \
		echo "  FAIL: expected corrupt warning, got: $$output"; cleanup; exit 1; \
	fi; \
	cleanup
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test-harness-scripts`
Expected: trigger tests PASS, briefing Test 1 FAILs (script missing).

- [ ] **Step 3: Write the script**

Create `dot_claude/scripts/executable_harness-briefing.sh`:

```bash
#!/usr/bin/env bash
# SessionStart hook: print harness self-improvement loop status.
#
# Deterministic by design — no LLM. Prints exactly one status block every
# session: an OK one-liner when healthy, or ATTENTION warnings each carrying
# a remediation command. Repeated silence across sessions means this hook
# itself is dead — that is the signal; do not add a quiet mode.
set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

HARNESS_DIR="$HOME/.claude/harness"
STATE="$HARNESS_DIR/state.json"
PENDING="$HARNESS_DIR/pending.jsonl"
QUEUE="$HARNESS_DIR/queue.md"

REVIEW_OVERDUE_DAYS=7
PENDING_MAX=5
PENDING_OLDEST_MAX_DAYS=20
QUEUE_MAX=10

# Bootstrap on first run (new machine / after manual reset).
mkdir -p "$HARNESS_DIR"
[[ -f "$STATE" ]] || printf '{"version":1}\n' >"$STATE"
[[ -f "$PENDING" ]] || : >"$PENDING"
if [[ ! -f "$QUEUE" ]]; then
    printf '# Harness improvement queue\n\nAppended by /harness-reflect; processed by /harness-review.\n' >"$QUEUE"
fi

NOW=$(date +%s)
WARNINGS=()

STATE_OK=1
if ! jq empty "$STATE" 2>/dev/null; then
    STATE_OK=0
    WARNINGS+=("state.json is corrupt — delete $STATE and it will re-bootstrap")
fi

QUEUE_COUNT=$(grep -c '^## ' "$QUEUE" 2>/dev/null || true)
QUEUE_COUNT=${QUEUE_COUNT:-0}
PENDING_COUNT=$(grep -c . "$PENDING" 2>/dev/null || true)
PENDING_COUNT=${PENDING_COUNT:-0}

LAST_REVIEW_TEXT="never"
if [[ "$STATE_OK" -eq 1 ]]; then
    LAST_REVIEW=$(jq -r '.last_review_epoch // empty' "$STATE" 2>/dev/null) || LAST_REVIEW=""
    if [[ -n "$LAST_REVIEW" ]]; then
        DAYS=$(((NOW - LAST_REVIEW) / 86400))
        LAST_REVIEW_TEXT="${DAYS}d ago"
        if [[ "$DAYS" -ge "$REVIEW_OVERDUE_DAYS" && $((QUEUE_COUNT + PENDING_COUNT)) -gt 0 ]]; then
            WARNINGS+=("harness review overdue (${DAYS}d, ${QUEUE_COUNT} queued / ${PENDING_COUNT} pending) — run /harness-review")
        fi
    elif [[ $((QUEUE_COUNT + PENDING_COUNT)) -gt 0 ]]; then
        WARNINGS+=("harness review has never run and work is waiting — run /harness-review")
    fi
fi

if [[ "$PENDING_COUNT" -gt "$PENDING_MAX" ]]; then
    WARNINGS+=("unreflected sessions piling up (${PENDING_COUNT}) — run /harness-reflect")
elif [[ "$PENDING_COUNT" -gt 0 ]]; then
    OLDEST=$(jq -rs 'map(.recorded_epoch) | min // empty' "$PENDING" 2>/dev/null) || OLDEST=""
    if [[ -n "$OLDEST" && "$OLDEST" != "null" ]]; then
        OLDEST_DAYS=$(((NOW - OLDEST) / 86400))
        if [[ "$OLDEST_DAYS" -ge "$PENDING_OLDEST_MAX_DAYS" ]]; then
            WARNINGS+=("oldest unreflected session is ${OLDEST_DAYS}d old; its transcript may be auto-pruned soon — run /harness-reflect")
        fi
    fi
fi

if [[ "$QUEUE_COUNT" -gt "$QUEUE_MAX" ]]; then
    WARNINGS+=("improvement queue piling up (${QUEUE_COUNT} unprocessed) — run /harness-review")
fi

if [[ ${#WARNINGS[@]} -eq 0 ]]; then
    printf 'Harness: OK | queue: %s | pending: %s | last review: %s\n' \
        "$QUEUE_COUNT" "$PENDING_COUNT" "$LAST_REVIEW_TEXT"
else
    printf 'Harness: ATTENTION\n'
    for w in "${WARNINGS[@]}"; do
        printf ' - %s\n' "$w"
    done
fi

exit 0
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test-harness-scripts && make shellcheck shfmt`
Expected: all trigger + briefing tests PASS; linters clean.

- [ ] **Step 5: Commit**

```bash
git add Makefile dot_claude/scripts/executable_harness-briefing.sh
git commit -m "feat(harness): add SessionStart briefing script

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: harness-doctor script

**Files:**
- Create: `dot_claude/scripts/executable_harness-doctor.sh`
- Modify: `Makefile` (extend `test-harness-scripts`)

**Interfaces:**
- Consumes: deployed layout under `$HOME`: `~/.claude/settings.json`, `~/.claude/scripts/harness-reflect-trigger.sh`, `~/.claude/scripts/harness-briefing.sh`, `~/.claude/skills/harness-reflect/SKILL.md`, `~/.claude/skills/harness-review/SKILL.md`, `~/.claude/harness/*`.
- Produces: `PASS:`/`FAIL:`/`WARN:` lines on stdout; exit 0 iff no FAIL. `/harness-review` (Task 6) runs this as its first step via `bash ~/.claude/scripts/harness-doctor.sh`.

- [ ] **Step 1: Write the failing smoke tests**

Append inside `test-harness-scripts`:

```make
	@echo "Testing harness-doctor.sh..."
	@SCRIPT="$$(pwd)/dot_claude/scripts/executable_harness-doctor.sh"; \
	tmphome=$$(mktemp -d /tmp/test-harness-doctor-XXXXXX); \
	cleanup() { rm -rf "$$tmphome"; }; \
	mkdir -p "$$tmphome/.claude/scripts" "$$tmphome/.claude/skills/harness-reflect" "$$tmphome/.claude/skills/harness-review" "$$tmphome/.claude/harness"; \
	printf '{"hooks":{"x":"harness-reflect-trigger.sh and harness-briefing.sh"}}' > "$$tmphome/.claude/settings.json"; \
	printf '#!/usr/bin/env bash\n' > "$$tmphome/.claude/scripts/harness-reflect-trigger.sh"; \
	printf '#!/usr/bin/env bash\n' > "$$tmphome/.claude/scripts/harness-briefing.sh"; \
	chmod +x "$$tmphome/.claude/scripts/harness-reflect-trigger.sh" "$$tmphome/.claude/scripts/harness-briefing.sh"; \
	printf -- '---\nname: harness-reflect\n---\n' > "$$tmphome/.claude/skills/harness-reflect/SKILL.md"; \
	printf -- '---\nname: harness-review\n---\n' > "$$tmphome/.claude/skills/harness-review/SKILL.md"; \
	printf '{"version":1,"last_trigger_epoch":%s}' "$$(date +%s)" > "$$tmphome/.claude/harness/state.json"; \
	printf '{"session_id":"s1","transcript_path":"/tmp/t","cwd":"/tmp","recorded_epoch":1}\n' > "$$tmphome/.claude/harness/pending.jsonl"; \
	printf '# Harness improvement queue\n' > "$$tmphome/.claude/harness/queue.md"; \
	echo "  Test 1: healthy fixture passes..."; \
	if output=$$(HOME="$$tmphome" bash "$$SCRIPT") && ! echo "$$output" | grep -q '^FAIL:'; then \
		echo "  PASS: healthy fixture exits 0 with no FAIL lines"; \
	else \
		echo "  FAIL: expected all-pass, got: $$output"; cleanup; exit 1; \
	fi; \
	echo "  Test 2: unwired hook is detected..."; \
	printf '{"hooks":{}}' > "$$tmphome/.claude/settings.json"; \
	if HOME="$$tmphome" bash "$$SCRIPT" >/dev/null 2>&1; then \
		echo "  FAIL: expected non-zero exit for unwired hooks"; cleanup; exit 1; \
	else \
		echo "  PASS: unwired hooks exit non-zero"; \
	fi; \
	echo "  Test 3: corrupt pending.jsonl is detected..."; \
	printf '{"hooks":{"x":"harness-reflect-trigger.sh and harness-briefing.sh"}}' > "$$tmphome/.claude/settings.json"; \
	printf 'not json\n' >> "$$tmphome/.claude/harness/pending.jsonl"; \
	if HOME="$$tmphome" bash "$$SCRIPT" >/dev/null 2>&1; then \
		echo "  FAIL: expected non-zero exit for corrupt pending"; cleanup; exit 1; \
	else \
		echo "  PASS: corrupt pending exits non-zero"; \
	fi; \
	cleanup
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test-harness-scripts`
Expected: trigger + briefing PASS; doctor Test 1 FAILs (script missing).

- [ ] **Step 3: Write the script**

Create `dot_claude/scripts/executable_harness-doctor.sh`:

```bash
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

ok=0; command -v jq >/dev/null 2>&1 || ok=1
check "$ok" "jq available" "brew install jq"
[[ "$ok" -ne 0 ]] && exit 1

ok=0; [[ -f "$SETTINGS" ]] && grep -q 'harness-reflect-trigger.sh' "$SETTINGS" || ok=1
check "$ok" "SessionEnd reflect-trigger hook wired in settings.json" "run 'chezmoi apply' (source: dot_claude/settings.json.tmpl)"

ok=0; [[ -f "$SETTINGS" ]] && grep -q 'harness-briefing.sh' "$SETTINGS" || ok=1
check "$ok" "SessionStart briefing hook wired in settings.json" "run 'chezmoi apply' (source: dot_claude/settings.json.tmpl)"

for script in harness-reflect-trigger.sh harness-briefing.sh; do
    ok=0; [[ -x "$HOME/.claude/scripts/$script" ]] || ok=1
    check "$ok" "$script deployed and executable" "run 'chezmoi apply'"
done

for skill in harness-reflect harness-review; do
    ok=0; [[ -f "$HOME/.claude/skills/$skill/SKILL.md" ]] || ok=1
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
    ok=0; jq empty "$HARNESS_DIR/state.json" 2>/dev/null || ok=1
    check "$ok" "state.json parseable" "delete $HARNESS_DIR/state.json (it will re-bootstrap)"
fi

if [[ -f "$HARNESS_DIR/pending.jsonl" && -s "$HARNESS_DIR/pending.jsonl" ]]; then
    ok=0; jq -c . <"$HARNESS_DIR/pending.jsonl" >/dev/null 2>&1 || ok=1
    check "$ok" "pending.jsonl lines parseable" "remove the malformed lines from $HARNESS_DIR/pending.jsonl"
fi

# Trigger recency is a WARN, not FAIL: no session may simply have ended lately.
if [[ -f "$HARNESS_DIR/state.json" ]] && jq empty "$HARNESS_DIR/state.json" 2>/dev/null; then
    LAST_TRIGGER=$(jq -r '.last_trigger_epoch // empty' "$HARNESS_DIR/state.json")
    if [[ -n "$LAST_TRIGGER" ]]; then
        AGE_DAYS=$((($(date +%s) - LAST_TRIGGER) / 86400))
        if [[ "$AGE_DAYS" -ge 7 ]]; then
            printf 'WARN: SessionEnd trigger last ran %sd ago — if sessions ended since, the hook may be dead\n' "$AGE_DAYS"
        else
            printf 'PASS: SessionEnd trigger ran %sd ago\n' "$AGE_DAYS"
        fi
    else
        printf 'WARN: SessionEnd trigger has never recorded a run (fresh install?)\n'
    fi
fi

exit "$FAILED"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test-harness-scripts && make shellcheck shfmt`
Expected: all tests PASS; linters clean.

- [ ] **Step 5: Commit**

```bash
git add Makefile dot_claude/scripts/executable_harness-doctor.sh
git commit -m "feat(harness): add deterministic harness-doctor liveness check

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Hook wiring + observer disable

**Files:**
- Modify: `dot_claude/settings.json.tmpl` (hooks section, lines 151–215)
- Modify: `dot_claude/continuous-learning-config.json`
- Modify: `dot_claude/scripts/executable_session-cleanup.sh` (line 8)

**Interfaces:**
- Consumes: scripts from Tasks 1–2 at their deployed paths `~/.claude/scripts/harness-reflect-trigger.sh`, `~/.claude/scripts/harness-briefing.sh`.
- Produces: live hook wiring after `chezmoi apply`. Doctor (Task 3) greps settings.json for exactly the strings `harness-reflect-trigger.sh` / `harness-briefing.sh`.

- [ ] **Step 1: Rewire hooks in `settings.json.tmpl`**

In the `"SessionStart"` block, add the briefing after session-cleanup (same `startup` matcher group):

```json
    "SessionStart": [
      {
        "matcher": "startup",
        "hooks": [
          {
            "type": "command",
            "command": "bash -c '\"$HOME/.claude/scripts/session-cleanup.sh\" 2>/dev/null || true'"
          },
          {
            "type": "command",
            "command": "bash -c 'mkdir -p \"$HOME/.claude/logs\" && \"$HOME/.claude/scripts/harness-briefing.sh\" 2>>\"$HOME/.claude/logs/harness-errors.log\" || true'"
          }
        ]
      }
    ],
```

Add a new top-level `"SessionEnd"` key inside `"hooks"` (after `"Stop"`):

```json
    "SessionEnd": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash -c 'mkdir -p \"$HOME/.claude/logs\" && \"$HOME/.claude/scripts/harness-reflect-trigger.sh\" 2>>\"$HOME/.claude/logs/harness-errors.log\" || true'"
          }
        ]
      }
    ],
```

Delete the entire `"UserPromptSubmit"` block (its only hook is the old `learning-briefing.sh`).

- [ ] **Step 2: Disable the ECC observer**

In `dot_claude/continuous-learning-config.json` set `"enabled": false`:

```json
{
  "version": "2.1",
  "observer": {
    "enabled": false,
    "run_interval_minutes": 5,
    "min_observations_to_analyze": 20
  }
}
```

Keep the `CLV2_CONFIG` env var in `settings.json.tmpl` unchanged — removing it would let plugin defaults re-enable the observer.

- [ ] **Step 3: Drop stale flag cleanup**

In `dot_claude/scripts/executable_session-cleanup.sh`, delete line 8 (the `find /tmp ... claude-learning-briefing-* ... claude-harness-checked-*` line) — the new briefing uses no per-session flag files. Keep the rest of the script intact.

- [ ] **Step 4: Verify**

Run: `make check-templates && make test-scripts && make shellcheck shfmt`
Expected: templates valid; existing script tests still pass (learning-briefing tests still exist until Task 7 — they test the old file, which still exists at this point); linters clean.

- [ ] **Step 5: Commit**

```bash
git add dot_claude/settings.json.tmpl dot_claude/continuous-learning-config.json dot_claude/scripts/executable_session-cleanup.sh
git commit -m "feat(harness): wire SessionEnd/SessionStart harness hooks, disable ECC observer

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: harness-reflect skill

**Files:**
- Create: `dot_claude/skills/harness-reflect/SKILL.md`

**Interfaces:**
- Consumes: `~/.claude/harness/pending.jsonl` (Task 1 format), current session context.
- Produces: appends entries to `~/.claude/harness/queue.md` in the exact format below; sets `.last_reflect_epoch` in `state.json`; removes processed lines from `pending.jsonl`. Task 6 (review) parses queue entries by their `^## ` headers and `- **Key:**` fields.

- [ ] **Step 1: Write the skill**

Create `dot_claude/skills/harness-reflect/SKILL.md`:

````markdown
---
name: harness-reflect
description: |
  Extract harness-worthy learnings from sessions into the improvement queue.
  Triggers: (1) /harness-reflect command, (2) invoked as the first step of
  /harness-review when unreflected sessions are pending, (3) SessionStart
  briefing warns about unreflected sessions piling up. Reads the current
  session and/or transcripts recorded in ~/.claude/harness/pending.jsonl,
  appends structured candidates to ~/.claude/harness/queue.md. Extraction
  only — dedup and adoption decisions belong to /harness-review.
---

# Harness Reflect

Extract learnings worth a permanent harness improvement (rule, CLAUDE.md
pitfall, docs/solutions entry) from sessions, and append them to the queue.

## Inputs

1. **The current session** (always, when invoked interactively): review the
   conversation so far with full context. This is the highest-quality input.
2. **Pending transcripts**: read `~/.claude/harness/pending.jsonl`. Each line
   is `{"session_id", "transcript_path", "cwd", "recorded_epoch"}`. For each
   entry, read the transcript file and analyze it. If the transcript file no
   longer exists, drop the entry (note it in your summary).

Skip an entry silently if its session_id matches the current session (it is
already covered by input 1).

## What to extract

- A wrong assumption the agent made, and its root cause
- A user correction or pushback on agent behavior (include the why)
- A repeated pattern that took multiple attempts to get right
- Drift between what rules/CLAUDE.md say and what is actually true

## What NOT to extract

- One-off circumstances unlikely to recur
- Things the codebase/docs already state (check before queueing)
- Conversation-local context with no cross-session value
- Vague platitudes — every entry needs a concrete, actionable proposed change

When in doubt, lean toward NOT queueing. A short high-signal queue beats a
long noisy one; the review step and human PR review both cost real attention.

## Queue entry format

Append to `~/.claude/harness/queue.md` (create parent entries exactly like
this; the review skill parses `^## ` headers and `- **Key:**` fields):

```markdown
## [YYYY-MM-DD] <short imperative title>

- **What happened:** <1-3 sentences, concrete>
- **Root cause:** <the wrong assumption / missing context / bad pattern>
- **Proposed change:** <exact rule text or doc change to make>
- **Scope:** global | dotfiles | project:<repo-name>
- **Source:** session <session_id>
```

Write entries in English (they feed English-language rules and docs).

## Bookkeeping (after appending)

1. Remove processed lines from `pending.jsonl` (rewrite the file without
   them; keep unprocessed lines intact).
2. Update state: `jq '.last_reflect_epoch = now | .last_reflect_epoch |= floor'`
   on `~/.claude/harness/state.json` (write via temp file + `mv`).
3. Report a summary: N sessions analyzed, M entries queued, dropped entries
   (missing transcripts) if any. If nothing was worth queueing, say so —
   an empty result is a valid outcome, not a failure.
````

- [ ] **Step 2: Verify formatting**

Run: `make scan-sensitive`
Expected: PASS (no PII in the new markdown).

- [ ] **Step 3: Commit**

```bash
git add dot_claude/skills/harness-reflect/SKILL.md
git commit -m "feat(harness): add harness-reflect skill

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: harness-review skill

**Files:**
- Create: `dot_claude/skills/harness-review/SKILL.md`

**Interfaces:**
- Consumes: `queue.md` entries (Task 5 format), `harness-doctor.sh` (Task 3), the chezmoi source repo, existing rules/docs.
- Produces: one PR per run against the dotfiles repo; processed entries moved to `~/.claude/harness/queue-archive.md` with a `- **Verdict:**` field; `.last_review_epoch` updated in `state.json`.

- [ ] **Step 1: Write the skill**

Create `dot_claude/skills/harness-review/SKILL.md`:

````markdown
---
name: harness-review
description: |
  Periodic harness health check and improvement-queue triage. Triggers:
  (1) /harness-review command, (2) SessionStart briefing warns the review is
  overdue (7-day cadence). Runs the deterministic doctor, reflects over any
  pending sessions, triages queued candidates against existing rules, then
  implements adopted changes as ONE pull request for human review. The human
  PR review is the only quality gate — this skill must present honest
  trade-offs, not advocacy.
---

# Harness Review

Operate on the chezmoi source repo: `cd "$(chezmoi source-path)"` (fallback:
`~/.local/share/chezmoi`). All rule/doc changes are made there, never on
deployed files under `~/`.

## Step 1: Liveness check

Run `bash ~/.claude/scripts/harness-doctor.sh`. If any FAIL line appears,
fixing the loop itself is this review's first-priority deliverable — include
the fix in the PR (or apply `chezmoi apply` if the fix is deploy-only) before
touching the queue.

## Step 2: Reflect over pending sessions

If `~/.claude/harness/pending.jsonl` is non-empty, execute the
harness-reflect skill (`~/.claude/skills/harness-reflect/SKILL.md`) first so
this review sees the full queue.

## Step 3: Triage the queue

For each `^## ` entry in `~/.claude/harness/queue.md`:

1. **Dedup:** search existing rules (`.claude/rules/`, `dot_claude/rules/`),
   `CLAUDE.md` Known Pitfalls, and `docs/solutions/` for the same guidance.
   Already covered → verdict `rejected (duplicate of <path>)`.
2. **Value test:** would this rule have prevented the original failure? Is it
   specific, actionable, and likely to recur? Vague or one-off → verdict
   `rejected (<reason>)`.
3. **Placement:** cross-project behavior → `dot_claude/rules/common/` (or
   `dot_claude/CLAUDE.md` for behavioral guidelines); this-repo pitfall →
   repo `CLAUDE.md` Known Pitfalls or `.claude/rules/`; incident record →
   `docs/solutions/`. Scope `project:<other-repo>` → verdict
   `handoff (belongs in <repo>)`; tell the user what to add there — do not
   modify other repos from this review.
4. Related queue entries may be merged into one change; record
   `merged into <title>` on the absorbed entries.

## Step 4: Staleness scan

Sample existing rules for rot (do all of `.claude/rules/` and
`dot_claude/rules/common/` when the queue is small; otherwise at least the
files touched by adopted changes plus one more):

- Referenced files, commands, and workflows still exist?
- Contradicted by newer learnings or by how work is actually done now?

Propose deletions/edits for stale rules in the same PR. Rules kept alive out
of caution are noise — deprecate aggressively; git history preserves them.

## Step 5: Implement and open ONE PR

1. Create a branch `harness/review-YYYY-MM-DD` off `main`.
2. Apply all adopted changes (new rules in English, following
   `~/.claude/rules/common/harness-engineering.md` writing guidelines).
3. Run `make lint` and fix findings.
4. Open one PR (body in Japanese) listing: adopted entries with their queue
   titles, rejected/handoff counts, staleness findings. Do NOT merge it.

If nothing was adopted and nothing is stale, skip the PR — record verdicts
and say so. An empty review is a valid outcome.

## Step 6: Bookkeeping

1. Move every processed entry from `queue.md` to
   `~/.claude/harness/queue-archive.md`, appending a verdict line to each:
   `- **Verdict:** adopted (PR <url>) | rejected (<reason>) | handoff (<repo>) | merged into <title>`
2. Update state (temp file + `mv`):
   `jq '.last_review_epoch = now | .last_review_epoch |= floor'` on
   `~/.claude/harness/state.json`.
3. Report: doctor result, N adopted / M rejected / K handoff, PR link,
   staleness findings.
````

- [ ] **Step 2: Verify formatting**

Run: `make scan-sensitive`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add dot_claude/skills/harness-review/SKILL.md
git commit -m "feat(harness): add harness-review skill

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Demolition

**Files:**
- Delete: `.github/workflows/harness-analysis.yml`, `.github/workflows/auto-promote.yml`, `.github/workflows/harness-auto-remediate.yml`
- Delete: `dot_claude/skills/propose-harness-improvement/`, `dot_claude/skills/validate-harness-proposal/`, `dot_claude/skills/compound-harness-knowledge/`, `dot_claude/skills/ecc-observer-diagnosis/`
- Delete: `dot_claude/commands/apply-harness-proposal.md`, `dot_claude/commands/capture-harness-feedback.md`, `dot_claude/commands/harness-health.md`, `dot_claude/commands/harness-rule-lifecycle.md`, `dot_claude/commands/promote-instincts.md`, `dot_claude/commands/resolve-harness-issues.md`
- Delete: `dot_claude/instinct-snapshots/`, `scripts/snapshot-instincts.sh`, `scripts/validate-instinct-snapshot.sh`, `dot_claude/scripts/executable_learning-briefing.sh`, `dot_claude/scripts/executable_pipeline-health.sh`
- Modify: `Makefile` (remove `test-pipeline-health`, `test-snapshot-instincts`, `test-validate-snapshot` targets + their `.PHONY`/`lint` mentions; remove the `Testing learning-briefing.sh` block from `test-scripts`)
- Modify: `.github/workflows/lint.yml` (remove jobs `pipeline-health`, `snapshot-instincts`, `validate-snapshot`; add job `harness-loop-scripts` running `make test-harness-scripts`)
- Modify: `.chezmoiignore` (add `.claude/harness` after the `.claude/homunculus` line; delete the `.claude/instinct-snapshots` line)

**Interfaces:**
- Consumes: nothing new.
- Produces: `make lint` and CI green without any reference to the removed machinery. Keep untouched: `security-alerts.yml`, `.github/actions/harness-issue-alert`, `lint.yml`'s other jobs, `claude.yml`, ECC plugin entry `"ecc@ecc": true` in settings.

- [ ] **Step 1: Delete files**

```bash
git rm -r .github/workflows/harness-analysis.yml .github/workflows/auto-promote.yml .github/workflows/harness-auto-remediate.yml \
  dot_claude/skills/propose-harness-improvement dot_claude/skills/validate-harness-proposal \
  dot_claude/skills/compound-harness-knowledge dot_claude/skills/ecc-observer-diagnosis \
  dot_claude/commands/apply-harness-proposal.md dot_claude/commands/capture-harness-feedback.md \
  dot_claude/commands/harness-health.md dot_claude/commands/harness-rule-lifecycle.md \
  dot_claude/commands/promote-instincts.md dot_claude/commands/resolve-harness-issues.md \
  dot_claude/instinct-snapshots scripts/snapshot-instincts.sh scripts/validate-instinct-snapshot.sh \
  dot_claude/scripts/executable_learning-briefing.sh dot_claude/scripts/executable_pipeline-health.sh
```

- [ ] **Step 2: Update Makefile**

- Line 1 `.PHONY`: remove `test-pipeline-health test-snapshot-instincts test-validate-snapshot`.
- Line 25 `lint:`: remove the same three targets (keep `test-harness-scripts` added in Task 1).
- Delete the three target bodies (`test-pipeline-health`, `test-snapshot-instincts`, `test-validate-snapshot`).
- In `test-scripts`: delete the `Testing learning-briefing.sh` block (from `@echo "Testing learning-briefing.sh..."` through the line before `@echo "Testing notify-wrapper.sh..."`), keeping the jq guard line and the notify-wrapper block.

- [ ] **Step 3: Update lint.yml**

Remove the `pipeline-health`, `snapshot-instincts`, `validate-snapshot` jobs. Add:

```yaml
  harness-loop-scripts:
    name: harness loop script smoke tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          persist-credentials: false
      - run: make test-harness-scripts
```

- [ ] **Step 4: Update .chezmoiignore**

After the `.claude/homunculus` line add `.claude/harness`; delete the `.claude/instinct-snapshots` line (its source dir no longer exists).

- [ ] **Step 5: Verify nothing dangles**

```bash
grep -rn "pipeline-health\|learning-briefing\|snapshot-instincts\|validate-instinct\|promote-instincts\|harness-analysis.yml\|auto-promote\|harness-auto-remediate\|propose-harness-improvement\|validate-harness-proposal" \
  --include='*.tmpl' --include='*.sh' --include='*.yml' --include='Makefile' . | grep -v node_modules
```

Expected: no hits outside `docs/` (historical docs stay as-is). Then run: `make lint`
Expected: all targets pass (CLAUDE.md still references old commands — fixed in Task 8; `scan-sensitive` doesn't check for that, so lint passes).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor(harness)!: remove ECC instinct pipeline and CI harness workflows

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: Rewrite knowledge docs

**Files:**
- Modify: `dot_claude/rules/common/harness-engineering.md`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: component names from Tasks 1–6 (`/harness-reflect`, `/harness-review`, `harness-doctor.sh`, `~/.claude/harness/`, `make test-harness-scripts`).
- Produces: docs that describe only the new system. Keep all Known Pitfalls and non-harness content intact.

- [ ] **Step 1: Rewrite `dot_claude/rules/common/harness-engineering.md`**

Keep sections: Core Principle, Failure-to-Rule Pipeline, Rule Writing Guidelines, Harness Maintenance, Anti-Patterns (verbatim). Replace "Feedback Loop Hierarchy" and delete "Instinct-Rule Relationship", inserting instead:

```markdown
## Feedback Loop Hierarchy

1. **Hooks** (automatic, immediate): Format, lint, secret detection — fires on every tool use
2. **Harness loop** (semi-automatic): SessionEnd hook records substantial sessions;
   `/harness-reflect` extracts learnings into `~/.claude/harness/queue.md`;
   `/harness-review` (7-day cadence, nudged by the SessionStart briefing) triages the
   queue into a single human-reviewed PR. Every harness change goes through PR review —
   there is no auto-apply tier.
3. **Rules** (contextual, persistent): Read at session start and guide decisions
   throughout the session
4. **CLAUDE.md** (project-scoped): Project architecture, commands, pitfalls
5. **docs/solutions/** (historical): Past problems and their resolutions

## Operating the Harness Loop

- The SessionStart briefing prints one status line every session. Silence across
  sessions means the briefing hook itself is dead — investigate immediately.
- A warning that stays for weeks is itself a harness bug: queue it.
- Diagnostics: `bash ~/.claude/scripts/harness-doctor.sh`.
- All monitoring is deterministic shell; LLM judgment runs only inside
  /harness-reflect and /harness-review, in interactive sessions where failures
  are visible.
```

- [ ] **Step 2: Rewrite CLAUDE.md harness content**

All edits to the repo-root `CLAUDE.md`:

1. **Common Commands block:** remove the `gh workflow run harness-analysis.yml` pair, `/resolve-harness-issues`, the entire "Harness improvement pipeline" command group, the entire "Continuous learning (ECC instinct system)" group, and `gh workflow run auto-promote.yml`. Keep the security-alerts lines. Add:

```sh
# Harness self-improvement loop (local, PR-gated)
/harness-reflect                     # Extract session learnings into ~/.claude/harness/queue.md
/harness-review                      # Health check + queue triage -> one PR (7-day cadence)
bash ~/.claude/scripts/harness-doctor.sh  # Deterministic liveness check
```

2. **Key Patterns:** delete the four sections "Scheduled harness analysis", "Autonomous harness improvement pipeline", "Continuous learning (ECC integration)", "Auto-promotion (Closed-Loop v1)". Replace the "Scheduled workflow failure alerting" section body with:

```markdown
**Scheduled workflow failure alerting** — The scheduled workflow
(`security-alerts.yml`) ends with an `if: failure()` step calling the local composite
action `.github/actions/harness-issue-alert`, which creates (or comments on) an issue
deduplicated by exact title. This prevents silent scheduled failures (an expired
`CLAUDE_CODE_OAUTH_TOKEN` once caused 401 failures for a month unnoticed). Any new
scheduled workflow must include the same step; the alerting steps need `issues: write`
permission.
```

Add one new section:

```markdown
**Harness self-improvement loop** — Local-only, PR-gated. A SessionEnd hook
(`harness-reflect-trigger.sh`) records substantial sessions (>= 10 assistant turns) to
`~/.claude/harness/pending.jsonl` — deterministic, no LLM. `/harness-reflect` extracts
learnings from the current session and pending transcripts into
`~/.claude/harness/queue.md`. `/harness-review` (nudged by the SessionStart briefing when
overdue >7 days) runs `harness-doctor.sh`, triages the queue against existing rules, and
opens one PR per run; humans review and merge — no auto-apply. Runtime state in
`~/.claude/harness/` is chezmoi-ignored; only rule changes are version-controlled. All
monitoring is deterministic shell — the briefing prints a status line every session, so
silence itself signals a dead hook. Design:
`docs/superpowers/specs/2026-07-06-harness-engineering-rebuild-design.md`.
```

3. **Verification section:** remove `make test-pipeline-health`, `make test-snapshot-instincts`, `make test-validate-snapshot` lines; add `make test-harness-scripts   # Smoke test harness loop scripts (trigger/briefing/doctor)`.

4. **Known Pitfalls — "Plugin marketplace renames" entry:** trim the ECC-learning-specific tail: replace "its hooks (e.g., the ECC observer) stop firing with no error, killing the learning pipeline" with "its hooks and agents stop working with no error", and drop the final sentence about `pipeline-health.sh`. Keep the rest of the pitfall.

- [ ] **Step 3: Verify and commit**

Run: `make lint`
Expected: pass (including `scan-sensitive` over the edited markdown).

```bash
git add dot_claude/rules/common/harness-engineering.md CLAUDE.md
git commit -m "docs(harness): describe new self-improvement loop, drop old system docs

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: Full verification sweep

**Files:** none (verification only; fix anything found).

- [ ] **Step 1: Full lint**

Run: `make lint`
Expected: every target passes.

- [ ] **Step 2: Stale-reference sweep**

```bash
grep -rn "instinct\|homunculus\|CLV2\|learning-briefing\|pipeline-health\|auto-promote\|harness-analysis" \
  --include='*.md' --include='*.tmpl' --include='*.sh' --include='*.yml' --include='Makefile' . \
  | grep -v node_modules | grep -v '^./docs/' | grep -v '.git/'
```

Expected remaining hits, all intentional: `CLV2_CONFIG` in `settings.json.tmpl` (observer kill-switch), `.claude/homunculus` in `.chezmoiignore` (runtime dir still exists on disk), `continuous-learning-config.json` content, `harness-analysis` label references inside `security-alerts.yml`/`harness-issue-alert` (label lives on for security alerting). Anything else → fix it.

- [ ] **Step 3: Dry-run apply check**

Run: `chezmoi apply --dry-run --source "$(pwd)" 2>&1 | head -50`
Expected: shows the new scripts/skills/settings as creates/changes; no destructive surprises. (Full apply happens post-merge from the real source dir.)

- [ ] **Step 4: Commit any fixes**

```bash
git add -A && git diff --cached --quiet || git commit -m "fix(harness): verification sweep fixes

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 10: Migration + PR

**Files:** none in-repo (GitHub issues, runtime queue seed, memory).

- [ ] **Step 1: Open the rebuild PR**

Push the branch and open a PR to `main` (body in Japanese) summarizing: new loop components, demolition list, docs rewrite, and the post-merge steps below. End the body with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.

- [ ] **Step 2: Triage old harness-analysis issues (needs `gh`, outward-facing — confirm with user before closing)**

```bash
gh issue view 128 --json title,body   # verify it matches "stale, already fixed" from the 2026-07-06 audit
gh issue close 128 --comment "監査(2026-07-06)で解決済みを確認。新harness loopではissue追跡を廃止しqueue管理に移行しました。"
gh issue view 130 --json title,body
gh issue view 158 --json title,body
```

Transcribe #130 and #158 into `~/.claude/harness/queue.md` as initial entries (reflect entry format from Task 5, `- **Source:** issue #130` etc.), then close each with a comment noting the queue migration.

- [ ] **Step 3: Post-merge checklist (hand to user / run after merge)**

```
1. cd ~/.local/share/chezmoi && git pull
2. chezmoi apply
3. bash ~/.claude/scripts/harness-doctor.sh   # expect all PASS
4. Optional cleanup of orphaned deployed files (chezmoi does not delete them):
   rm -rf ~/.claude/skills/{propose-harness-improvement,validate-harness-proposal,compound-harness-knowledge,ecc-observer-diagnosis}
   rm -f ~/.claude/commands/{apply-harness-proposal,capture-harness-feedback,harness-health,harness-rule-lifecycle,promote-instincts,resolve-harness-issues}.md
   rm -f ~/.claude/scripts/{learning-briefing.sh,pipeline-health.sh}
   rm -rf ~/.claude/homunculus ~/.claude/instinct-snapshots
5. Acceptance cycle: run one real session (>= 10 turns), end it, start a new
   session (briefing should show pending: 1), run /harness-reflect, then
   /harness-review through to a PR.
```

- [ ] **Step 4: Update agent memory**

Update `~/.claude/projects/-Users-tanikado--local-share-chezmoi/memory/harness-silent-failure-audit.md`: note the old system was replaced (not repaired) on the rebuild date, link the spec path, and mark the "regenerate CLAUDE_CODE_OAUTH_TOKEN for harness-analysis" follow-up obsolete (workflow deleted; token only matters if `claude.yml`/`security-alerts.yml` need it). Add a new memory `harness-loop-v2.md` describing the new system's shape and update `MEMORY.md`.
