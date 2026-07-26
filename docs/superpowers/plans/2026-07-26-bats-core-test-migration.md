# Shell Script Test Migration to bats-core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the five hand-rolled shell test suites embedded in `Makefile` recipes with bats-core test suites under `test/`, one `.bats` file per script under test, while preserving every hard-won lesson (hermeticity against ambient env vars, mktemp/tmpdir safety, non-vacuous assertions) already documented for the old suite.

**Architecture:** The bats-core CLI (npm package name `bats` — the project is called bats-core, but that string is not a valid npm package; `bats-core` returns a 404 from the registry), `bats-support`, and `bats-assert` become pnpm devDependencies, matching how `secretlint`/`oxlint`/`oxfmt` are already managed. `test/helpers/setup.bash` loads the two assertion libraries once; every `.bats` file's `setup()` loads it. `Makefile` targets become thin `pnpm exec bats <file...>` wrappers so `.github/workflows/lint.yml` keeps calling `make test-<name>` unchanged — only four CI jobs gain the same `pnpm install` steps the JS-tooling jobs already have, since they now need a devDependency to run.

**Tech Stack:** bats (npm package for the bats-core CLI), bats-support (npm), bats-assert (npm), pnpm, existing `jq`/`bash`.

**Design doc:** `docs/superpowers/specs/2026-07-26-bats-core-test-migration-design.md`

## Global Constraints

- One `.bats` file per script under test, all directly under `test/` (no subdirectories except `test/helpers/`).
- Assertions use bats-assert (`assert_success`, `assert_failure`, `assert_output`, `refute_output`, `assert`, `refute`, `assert_equal`) — never raw `[ "$status" -eq 0 ]`.
- Every test file uses `$BATS_TEST_TMPDIR` for scratch files/dirs — never a manual `mktemp` call. bats creates and destroys this directory per `@test` automatically.
- Ambient-environment hermeticity: a test that needs a specific value for `ORCA_PANE_KEY`, `ORCA_AGENT_HOOK_PORT`, `ORCA_AGENT_HOOK_TOKEN`, `HARNESS_DISABLE`, or `CLAUDE_NOTIFY_BACKEND` sets it with an explicit `export` inside that `@test`'s own body — never rely on a value leaking in from the invoking shell.
- `package.json` `devDependencies` gain `bats` (the npm package name for the bats-core CLI — NOT `bats-core`, which 404s), `bats-support`, `bats-assert`, added via `pnpm add -D` so pnpm resolves and locks the current versions (do not hand-type version numbers).
- Every `Makefile` `test-*` target stays the single entrypoint CI calls (`make test-modify`, etc.) — each becomes `pnpm exec bats test/<file>.bats [test/<file2>.bats ...]`.
- No shellcheck/shfmt exclusion needs to be added for `*.bats`: the Makefile's existing `SHELL_FILES` discovery (`*.sh`, `*.bash`, `executable_*`) already never matches `.bats`.
- **Sandbox network prerequisite:** if executing this plan inside the nono-sandboxed `claude` wrapper described in this repo's `CLAUDE.md`, `pnpm add` needs to reach the npm registry, which is not in the current `claude-seal` profile's `network.allow_domain` list. Use the same profile-draft-and-promote workflow (`nono profile guide`, draft to `~/.config/nono/profile-drafts/claude-seal.json`, `nono profile promote claude-seal`) to add the registry host, or run `pnpm add` outside the sandbox, before starting Task 1.

---

### Task 1: Bootstrap the bats-core toolchain

**Files:**
- Modify: `package.json`
- Modify: `pnpm-lock.yaml` (auto-updated by `pnpm add`)
- Create: `test/helpers/setup.bash`
- Modify: `.chezmoiignore`

**Interfaces:**
- Produces: `test/helpers/setup.bash`, loaded by every later `.bats` file via `load 'helpers/setup'` in its `setup()`. After loading it, `assert_success`, `assert_failure`, `assert_output`, `refute_output`, `assert`, `refute`, and `assert_equal` are available in the test file.

- [ ] **Step 1: Install bats (the bats-core CLI), bats-support, bats-assert**

The bats-core project's npm package is named `bats`, not `bats-core` — `bats-core` is the
project/repo name only and does not exist as an npm package (confirmed: it 404s from the
registry).

Run:
```sh
pnpm add -D bats bats-support bats-assert
```

- [ ] **Step 2: Verify the bats binary runs and the companion libraries have the expected layout**

Run:
```sh
pnpm exec bats --version
ls node_modules/bats-support/load.bash
ls node_modules/bats-assert/load.bash
```
Expected: `bats --version` prints a version string (e.g. `Bats 1.11.0`); both `load.bash` files exist. If either `load.bash` path is missing, inspect the installed package's actual layout (`ls node_modules/bats-support/`) before proceeding — the rest of this plan assumes this exact path.

- [ ] **Step 3: Create the shared test helper**

Create `test/helpers/setup.bash`:

```bash
# Shared bats-support/bats-assert loader for every suite under test/.
# `load` always resolves relative to $BATS_TEST_DIRNAME (the directory of the
# .bats file that started the load chain), which is `test/` for every suite
# in this repo — so `../node_modules/...` is correct here even though this
# file itself lives in test/helpers/.
load '../node_modules/bats-support/load'
load '../node_modules/bats-assert/load'
```

- [ ] **Step 4: Add `test/` to `.chezmoiignore`**

`test/` is a repo-only directory (like `docs/`, `scripts/`, `Makefile`) and must never be deployed to `~/`. Edit `.chezmoiignore`, in the "repo-only files (not deployed to home)" block:

```diff
 # repo-only files (not deployed to home)
 .node-version
 .github/
 docs/
 scripts/
 renovate.json
 Makefile
+test/
```

- [ ] **Step 5: Verify `test/` is ignored by chezmoi**

Run:
```sh
chezmoi ignored --source "$(pwd)" | grep '^test$'
```
Expected: `test` is listed.

- [ ] **Step 6: Commit**

```bash
git add package.json pnpm-lock.yaml test/helpers/setup.bash .chezmoiignore
git commit -m "chore: bootstrap bats-core test toolchain"
```

---

### Task 2: Convert `modify_dot_claude.json` tests

**Files:**
- Create: `test/modify-dot-claude.bats`

**Interfaces:**
- Consumes: `test/helpers/setup.bash` (Task 1)
- Produces: nothing consumed by later tasks (this script has no other test file depending on it)

- [ ] **Step 1: Write the bats suite**

Create `test/modify-dot-claude.bats`:

```bash
setup() {
    load 'helpers/setup'
    SCRIPT="$BATS_TEST_DIRNAME/../modify_dot_claude.json"
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

modify() {
    printf '%s' "$1" | bash "$SCRIPT" 2>/dev/null
}

@test "preserves existing data and replaces mcpServers" {
    export CHEZMOI_SOURCE_DIR="$REPO_ROOT"
    run modify '{"existingKey":"value","mcpServers":{}}'
    assert_success
    assert jq -e '.existingKey == "value"' <<< "$output"
    assert jq -e '.mcpServers | has("codex")' <<< "$output"
}

@test "empty stdin produces valid JSON with mcpServers" {
    export CHEZMOI_SOURCE_DIR="$REPO_ROOT"
    run modify ''
    assert_success
    assert jq -e 'has("mcpServers")' <<< "$output"
}

@test "missing source file passes through stdin" {
    export CHEZMOI_SOURCE_DIR="/tmp/nonexistent-dir"
    input='{"existingKey":"keep","mcpServers":{"old":"data"}}'
    run modify "$input"
    assert_success
    assert_equal "$output" "$input"
}
```

- [ ] **Step 2: Run the suite directly**

Run:
```sh
pnpm exec bats test/modify-dot-claude.bats
```
Expected: `3 tests, 0 failures`.

- [ ] **Step 3: Commit**

```bash
git add test/modify-dot-claude.bats
git commit -m "test: convert modify_dot_claude.json tests to bats"
```

---

### Task 3: Convert `modify_karabiner.json` tests and retire the old `test-modify` recipe

**Files:**
- Create: `test/modify-karabiner.bats`
- Modify: `Makefile` (replace the `test-modify:` recipe)
- Modify: `.github/workflows/lint.yml` (`modify-scripts` job)

**Interfaces:**
- Consumes: `test/modify-dot-claude.bats` (Task 2), `test/helpers/setup.bash` (Task 1)

- [ ] **Step 1: Write the bats suite**

Create `test/modify-karabiner.bats`:

```bash
setup() {
    load 'helpers/setup'
    SCRIPT="$BATS_TEST_DIRNAME/../dot_config/karabiner/modify_karabiner.json"
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

modify() {
    printf '%s' "$1" | bash "$SCRIPT" 2>/dev/null
}

@test "machine_specific and profile metadata preserved, rules replaced and equal to source" {
    export CHEZMOI_SOURCE_DIR="$REPO_ROOT"
    input='{"machine_specific":{"krbn-test":{"external_editor_path":"/Applications/Code.app"}},"profiles":[{"complex_modifications":{"rules":[{"description":"old"}]},"name":"Default profile","selected":true,"virtual_hid_keyboard":{"keyboard_type_v2":"jis"}}]}'
    run modify "$input"
    assert_success
    assert jq -e '.machine_specific."krbn-test".external_editor_path == "/Applications/Code.app"' <<< "$output"
    assert jq -e '.profiles[0].name == "Default profile" and .profiles[0].selected == true' <<< "$output"
    assert jq -e '.profiles[0].virtual_hid_keyboard.keyboard_type_v2 == "jis"' <<< "$output"
    assert jq -e '.profiles[0].complex_modifications.rules | length == 1' <<< "$output"
    assert jq -e --slurpfile src "$REPO_ROOT/dot_config/karabiner/complex_modifications.json" '.profiles[0].complex_modifications.rules == $src[0]' <<< "$output"
}

@test "multi-profile rules replaced in both, name/selected/parameters preserved" {
    export CHEZMOI_SOURCE_DIR="$REPO_ROOT"
    input='{"profiles":[{"complex_modifications":{"rules":[]},"name":"P1","selected":true},{"complex_modifications":{"rules":[{"description":"old"}],"parameters":{"basic.simultaneous_threshold_milliseconds":100}},"name":"P2","selected":false}]}'
    run modify "$input"
    assert_success
    assert jq -e '.profiles | length == 2' <<< "$output"
    assert jq -e '.profiles[0].name == "P1" and .profiles[0].selected == true and .profiles[1].name == "P2" and .profiles[1].selected == false' <<< "$output"
    assert jq -e '.profiles[0].complex_modifications.rules | length == 1' <<< "$output"
    assert jq -e '.profiles[1].complex_modifications.rules | length == 1' <<< "$output"
    assert jq -e --slurpfile src "$REPO_ROOT/dot_config/karabiner/complex_modifications.json" '.profiles[0].complex_modifications.rules == $src[0] and .profiles[1].complex_modifications.rules == $src[0]' <<< "$output"
    assert jq -e '.profiles[1].complex_modifications.parameters."basic.simultaneous_threshold_milliseconds" == 100' <<< "$output"
}

@test "empty stdin produces valid JSON with rules equal to source and no machine_specific" {
    export CHEZMOI_SOURCE_DIR="$REPO_ROOT"
    run modify ''
    assert_success
    assert jq -e '.profiles | length == 1' <<< "$output"
    assert jq -e '.profiles[0].complex_modifications.rules | length == 1' <<< "$output"
    assert jq -e --slurpfile src "$REPO_ROOT/dot_config/karabiner/complex_modifications.json" '.profiles[0].complex_modifications.rules == $src[0]' <<< "$output"
    assert jq -e 'has("machine_specific") | not' <<< "$output"
}

@test "missing source file passes through stdin" {
    export CHEZMOI_SOURCE_DIR="/tmp/nonexistent-dir"
    input='{"profiles":[{"complex_modifications":{"rules":[]},"name":"Default profile","selected":true}]}'
    run modify "$input"
    assert_success
    assert jq -e --argjson i "$input" '. == $i' <<< "$output"
}

@test "non-array source file passes through stdin" {
    src="$BATS_TEST_TMPDIR/source"
    mkdir -p "$src/dot_config/karabiner"
    printf '{"not": "an array"}' > "$src/dot_config/karabiner/complex_modifications.json"
    export CHEZMOI_SOURCE_DIR="$src"
    input='{"profiles":[{"complex_modifications":{"rules":[]},"name":"Default profile","selected":true}]}'
    run modify "$input"
    assert_success
    assert jq -e --argjson i "$input" '. == $i' <<< "$output"
}

@test "invalid-JSON source file passes through stdin" {
    src="$BATS_TEST_TMPDIR/source"
    mkdir -p "$src/dot_config/karabiner"
    printf '{not valid json' > "$src/dot_config/karabiner/complex_modifications.json"
    export CHEZMOI_SOURCE_DIR="$src"
    input='{"profiles":[{"complex_modifications":{"rules":[]},"name":"Default profile","selected":true}]}'
    run modify "$input"
    assert_success
    assert jq -e --argjson i "$input" '. == $i' <<< "$output"
}

@test "stdin without .profiles key passes through stdin" {
    export CHEZMOI_SOURCE_DIR="$REPO_ROOT"
    input='{"unrelated":"shape","no_profiles_key":true}'
    run modify "$input"
    assert_success
    assert jq -e --argjson i "$input" '. == $i' <<< "$output"
}
```

- [ ] **Step 2: Run the suite directly**

Run:
```sh
pnpm exec bats test/modify-karabiner.bats
```
Expected: `7 tests, 0 failures`.

- [ ] **Step 3: Replace the `test-modify` Makefile recipe**

In `Makefile`, find the block starting at `## Smoke test modify_ scripts` / `test-modify:` and ending right before `## Smoke test hook scripts` (currently lines 93–178). Replace the entire block with:

```make
## Smoke test modify_ scripts
test-modify:
	pnpm exec bats test/modify-dot-claude.bats test/modify-karabiner.bats
```

- [ ] **Step 4: Run the Makefile target**

Run:
```sh
make test-modify
```
Expected: bats output for both files, all tests passing.

- [ ] **Step 5: Add pnpm/node setup to the `modify-scripts` CI job**

In `.github/workflows/lint.yml`, find the `modify-scripts` job:

```yaml
  modify-scripts:
    name: modify_ script smoke tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6.1.0
        with:
          persist-credentials: false
      - run: make test-modify
```

Replace it with:

```yaml
  modify-scripts:
    name: modify_ script smoke tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6.1.0
        with:
          persist-credentials: false
      - uses: pnpm/action-setup@0ebf47130e4866e96fce0953f49152a61190b271 # v6.0.9
      - uses: actions/setup-node@249970729cb0ef3589644e2896645e5dc5ba9c38 # v6.5.0
        with:
          node-version-file: '.node-version'
          cache: pnpm
      - run: pnpm install --frozen-lockfile
      - run: make test-modify
```

- [ ] **Step 6: Validate the workflow file**

Run:
```sh
make actionlint
```
Expected: no errors reported for `lint.yml`.

- [ ] **Step 7: Commit**

```bash
git add test/modify-karabiner.bats Makefile .github/workflows/lint.yml
git commit -m "test: convert modify_karabiner.json tests to bats, retire inline Makefile recipe"
```

---

### Task 4: Convert `notify.sh` tests and retire the old `test-scripts` recipe

**Files:**
- Create: `test/notify.bats`
- Modify: `Makefile` (replace the `test-scripts:` recipe)
- Modify: `.github/workflows/lint.yml` (`harness-scripts` job)

**Interfaces:**
- Consumes: `test/helpers/setup.bash` (Task 1)

This is the largest script under test (24 hand-rolled cases). Two of the original cases (terminal-notifier argv check, and the ghostty click-target check that reused the first case's leftover argv file) are merged into one `@test`, because bats gives each `@test` a fresh `$BATS_TEST_TMPDIR` — there is no shared state between test cases to read back, unlike the old single-shell-script Makefile recipe. This also removes the fragile "editing Test 19 changes what Test 20 proves" coupling the old suite's comments warned about.

- [ ] **Step 1: Write the bats suite**

Create `test/notify.bats`:

```bash
setup() {
    load 'helpers/setup'
    SCRIPT="$BATS_TEST_DIRNAME/../dot_claude/scripts/executable_notify.sh"
    unset ORCA_PANE_KEY ORCA_AGENT_HOOK_PORT ORCA_AGENT_HOOK_TOKEN
    export HOME="$BATS_TEST_TMPDIR"
    export CLAUDE_NOTIFY_DRY_RUN=1
}

notify() {
    printf '%s' "$1" | bash "$SCRIPT"
}

setup_fake_terminal_notifier() {
    FAKEBIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$FAKEBIN"
    TN_ARGS="$BATS_TEST_TMPDIR/tn-args.txt"
    export TN_ARGS
    cat > "$FAKEBIN/terminal-notifier" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$TN_ARGS"
EOF
    chmod +x "$FAKEBIN/terminal-notifier"
}

setup_fake_osascript() {
    FAKEBIN="${FAKEBIN:-$BATS_TEST_TMPDIR/bin}"
    mkdir -p "$FAKEBIN"
    OSA_MARKER="$BATS_TEST_TMPDIR/osa-called.txt"
    export OSA_MARKER
    cat > "$FAKEBIN/osascript" <<'EOF'
#!/bin/sh
echo called > "$OSA_MARKER"
EOF
    chmod +x "$FAKEBIN/osascript"
}

# --- suppression gates -------------------------------------------------

@test "all three orca env vars suppress the notification" {
    export ORCA_PANE_KEY=pane ORCA_AGENT_HOOK_PORT=1234 ORCA_AGENT_HOOK_TOKEN=tok
    payload=$(printf '{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash","session_id":"s1","cwd":"%s"}' "$HOME")
    run notify "$payload"
    assert_success
    assert_output ''
}

@test "ORCA_PANE_KEY alone does not suppress" {
    export ORCA_PANE_KEY=pane
    payload=$(printf '{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash","session_id":"s1","cwd":"%s"}' "$HOME")
    run notify "$payload"
    assert_success
    assert_output --partial 'subtitle=許可待ち'
}

# --- classification -----------------------------------------------------

@test "permission_prompt classifies as 許可待ち with Glass sound" {
    payload=$(printf '{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash","session_id":"s1","cwd":"%s"}' "$HOME")
    run notify "$payload"
    assert_success
    assert_output --partial 'subtitle=許可待ち'
    assert_output --partial 'sound=Glass'
}

@test "worker_permission_prompt also classifies as 許可待ち" {
    payload=$(printf '{"hook_event_name":"Notification","notification_type":"worker_permission_prompt","message":"worker needs network access to example.com","session_id":"s1","cwd":"%s"}' "$HOME")
    run notify "$payload"
    assert_success
    assert_output --partial 'subtitle=許可待ち'
    assert_output --partial 'sound=Glass'
}

@test "idle_prompt classifies as 入力待ち and is silent" {
    payload=$(printf '{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"Claude is waiting for your input","session_id":"s1","cwd":"%s"}' "$HOME")
    run notify "$payload"
    assert_success
    assert_output --partial 'subtitle=入力待ち'
    assert_line 'sound='
}

@test "agent_needs_input classifies as 入力待ち and is silent" {
    payload=$(printf '{"hook_event_name":"Notification","notification_type":"agent_needs_input","message":"reviewer needs your input","session_id":"s1","cwd":"%s"}' "$HOME")
    run notify "$payload"
    assert_success
    assert_output --partial 'subtitle=入力待ち'
    assert_line 'sound='
}

@test "unrecognized notification_type degrades to 入力待ち rather than silence" {
    payload=$(printf '{"hook_event_name":"Notification","notification_type":"future_unknown_type","message":"something new","session_id":"s1","cwd":"%s"}' "$HOME")
    run notify "$payload"
    assert_success
    assert_output --partial 'subtitle=入力待ち'
    assert_line 'sound='
}

@test "absent notification_type falls back to the message regex" {
    payload=$(printf '{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash","session_id":"s1","cwd":"%s"}' "$HOME")
    run notify "$payload"
    assert_success
    assert_output --partial 'subtitle=許可待ち'
    assert_output --partial 'sound=Glass'
}

@test "message-regex fallback matches approval, not just permission" {
    payload=$(printf '{"hook_event_name":"Notification","message":"Claude Code needs your approval for the plan","session_id":"s1","cwd":"%s"}' "$HOME")
    run notify "$payload"
    assert_success
    assert_output --partial 'subtitle=許可待ち'
    assert_output --partial 'sound=Glass'
}

@test "StopFailure without error classifies as エラー停止 with the fixed body" {
    payload=$(printf '{"hook_event_name":"StopFailure","session_id":"s1","cwd":"%s"}' "$HOME")
    run notify "$payload"
    assert_success
    assert_output --partial 'subtitle=エラー停止'
    assert_output --partial 'sound=Basso'
    assert_output --partial 'message=ターンが異常終了しました'
}

@test "StopFailure surfaces its error in the body" {
    payload=$(printf '{"hook_event_name":"StopFailure","error":"rate_limit","session_id":"s1","cwd":"%s"}' "$HOME")
    run notify "$payload"
    assert_success
    assert_output --partial 'subtitle=エラー停止'
    assert_line --partial 'message='
    assert_output --partial 'rate_limit'
}

@test "unknown event degrades to 入力待ち rather than silence" {
    payload=$(printf '{"hook_event_name":"SomeFutureEvent","message":"whatever","session_id":"s1","cwd":"%s"}' "$HOME")
    run notify "$payload"
    assert_success
    assert_output --partial 'subtitle=入力待ち'
}

# --- input edge cases -----------------------------------------------------

@test "empty stdin exits 0 with no output" {
    run notify ''
    assert_success
    assert_output ''
}

@test "malformed JSON exits 0 with no output" {
    run notify 'not json at all'
    assert_success
    assert_output ''
}

@test "group carries the session_id" {
    payload=$(printf '{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"hi","session_id":"sess-abc","cwd":"%s"}' "$HOME")
    run notify "$payload"
    assert_success
    assert_line 'group=claude-sess-abc'
}

@test "title carries the cwd basename" {
    base=$(basename "$HOME")
    payload=$(printf '{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"hi","session_id":"s1","cwd":"%s"}' "$HOME")
    run notify "$payload"
    assert_success
    assert_output --partial "$base"
}

@test "diagnostic log records kind, notification_type, and error" {
    payload1=$(printf '{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"logprobe","session_id":"s1","cwd":"%s"}' "$HOME")
    payload2=$(printf '{"hook_event_name":"StopFailure","error":"rate_limit","session_id":"s1","cwd":"%s"}' "$HOME")
    notify "$payload1" >/dev/null
    notify "$payload2" >/dev/null
    notifylog="$HOME/.claude/logs/notify.log"
    assert [ -f "$notifylog" ]
    assert grep -q 'kind=入力待ち.*notification_type=idle_prompt.*message=logprobe' "$notifylog"
    assert grep -q 'kind=エラー停止.*error=rate_limit' "$notifylog"
}

@test "missing cwd falls back to \$PWD" {
    payload='{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"hi","session_id":"s1"}'
    run notify "$payload"
    assert_success
    assert_output --partial "$(basename "$PWD")"
}

# --- delivery backends ------------------------------------------------------

@test "terminal-notifier receives group, subtitle, sound, and ghostty click target" {
    unset CLAUDE_NOTIFY_DRY_RUN
    setup_fake_terminal_notifier
    export PATH="$FAKEBIN:$PATH"
    payload=$(printf '{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash","session_id":"sess-xyz","cwd":"%s"}' "$HOME")
    TERM_PROGRAM=ghostty TMUX= TMUX_PANE= run notify "$payload"
    assert_success
    assert [ -f "$TN_ARGS" ]
    assert grep -qx -- '-group' "$TN_ARGS"
    assert grep -qx -- 'claude-sess-xyz' "$TN_ARGS"
    assert grep -qx -- '許可待ち' "$TN_ARGS"
    assert grep -qx -- 'Glass' "$TN_ARGS"
    assert grep -q 'com.mitchellh.ghostty' "$TN_ARGS"
}

@test "silent kinds omit -sound" {
    unset CLAUDE_NOTIFY_DRY_RUN
    setup_fake_terminal_notifier
    export PATH="$FAKEBIN:$PATH"
    payload=$(printf '{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"Claude is waiting for your input","session_id":"s1","cwd":"%s"}' "$HOME")
    TERM_PROGRAM=ghostty TMUX= TMUX_PANE= run notify "$payload"
    assert_success
    refute grep -qx -- '-sound' "$TN_ARGS"
}

@test "tmux click target jumps to the pane" {
    unset CLAUDE_NOTIFY_DRY_RUN
    setup_fake_terminal_notifier
    export PATH="$FAKEBIN:$PATH"
    payload=$(printf '{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"hi","session_id":"s1","cwd":"%s"}' "$HOME")
    TERM_PROGRAM=ghostty TMUX=/tmp/fake-tmux TMUX_PANE=%7 run notify "$payload"
    assert_success
    assert grep -q 'select-pane' "$TN_ARGS"
}

@test "CLAUDE_NOTIFY_BACKEND=osascript forces the fallback" {
    unset CLAUDE_NOTIFY_DRY_RUN
    setup_fake_terminal_notifier
    setup_fake_osascript
    export PATH="$FAKEBIN:$PATH"
    export CLAUDE_NOTIFY_BACKEND=osascript
    payload=$(printf '{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"hi","session_id":"s1","cwd":"%s"}' "$HOME")
    TERM_PROGRAM=ghostty TMUX= TMUX_PANE= run notify "$payload"
    assert_success
    assert [ -f "$OSA_MARKER" ]
    assert [ ! -f "$TN_ARGS" ]
}

@test "malformed TMUX_PANE does not reach -execute (injection guard)" {
    unset CLAUDE_NOTIFY_DRY_RUN
    setup_fake_terminal_notifier
    export PATH="$FAKEBIN:$PATH"
    payload=$(printf '{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"hi","session_id":"s1","cwd":"%s"}' "$HOME")
    TERM_PROGRAM=ghostty TMUX=/tmp/fake-tmux TMUX_PANE="%1'; touch $BATS_TEST_TMPDIR/injected #" run notify "$payload"
    assert_success
    refute grep -q 'select-pane' "$TN_ARGS"
    assert grep -q 'com.mitchellh.ghostty' "$TN_ARGS"
}
```

- [ ] **Step 2: Run the suite directly**

Run:
```sh
pnpm exec bats test/notify.bats
```
Expected: `23 tests, 0 failures`.

- [ ] **Step 3: Prove hermeticity with a simulated ambient-env leak**

Run:
```sh
ORCA_PANE_KEY=leak ORCA_AGENT_HOOK_PORT=1 ORCA_AGENT_HOOK_TOKEN=x pnpm exec bats test/notify.bats
```
Expected: identical `23 tests, 0 failures` — the `setup()` unset must neutralize this leak. If any test fails here but passed in Step 2, the leak is reaching a test that should have been immune; fix `setup()` before continuing.

- [ ] **Step 4: Replace the `test-scripts` Makefile recipe**

In `Makefile`, find the block starting at `## Smoke test hook scripts` / `test-scripts:` and ending right before `## Validate chezmoi templates` (currently lines 180–409). Replace the entire block with:

```make
## Smoke test hook scripts
test-scripts:
	pnpm exec bats test/notify.bats
```

- [ ] **Step 5: Run the Makefile target**

Run:
```sh
make test-scripts
```
Expected: all 23 tests passing.

- [ ] **Step 6: Add pnpm/node setup to the `harness-scripts` CI job**

In `.github/workflows/lint.yml`, find the `harness-scripts` job:

```yaml
  harness-scripts:
    name: harness script smoke tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6.1.0
        with:
          persist-credentials: false
      - run: make test-scripts
```

Replace it with:

```yaml
  harness-scripts:
    name: harness script smoke tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6.1.0
        with:
          persist-credentials: false
      - uses: pnpm/action-setup@0ebf47130e4866e96fce0953f49152a61190b271 # v6.0.9
      - uses: actions/setup-node@249970729cb0ef3589644e2896645e5dc5ba9c38 # v6.5.0
        with:
          node-version-file: '.node-version'
          cache: pnpm
      - run: pnpm install --frozen-lockfile
      - run: make test-scripts
```

- [ ] **Step 7: Validate the workflow file**

Run:
```sh
make actionlint
```
Expected: no errors.

- [ ] **Step 8: Commit**

```bash
git add test/notify.bats Makefile .github/workflows/lint.yml
git commit -m "test: convert notify.sh tests to bats, retire inline Makefile recipe"
```

---

### Task 5: Convert `harness-reflect-trigger.sh` tests

**Files:**
- Create: `test/harness-reflect-trigger.bats`

**Interfaces:**
- Consumes: `test/helpers/setup.bash` (Task 1)

- [ ] **Step 1: Write the bats suite**

Create `test/harness-reflect-trigger.bats`:

```bash
setup() {
    load 'helpers/setup'
    SCRIPT="$BATS_TEST_DIRNAME/../dot_claude/scripts/executable_harness-reflect-trigger.sh"
    export HOME="$BATS_TEST_TMPDIR"
    TRANSCRIPT="$BATS_TEST_TMPDIR/big.jsonl"
    for i in $(seq 1 12); do
        printf '{"type":"assistant","message":{"id":"msg_%s"}}\n' "$i" >> "$TRANSCRIPT"
    done
    PENDING="$HOME/.claude/harness/pending.jsonl"
    STATE="$HOME/.claude/harness/state.json"
}

trigger() {
    printf '%s' "$1" | bash "$SCRIPT"
}

@test "substantial session is recorded in pending.jsonl" {
    payload=$(printf '{"session_id":"sess-big","transcript_path":"%s","cwd":"/tmp"}' "$TRANSCRIPT")
    run trigger "$payload"
    assert_success
    assert [ -f "$PENDING" ]
    assert jq -e 'select(.session_id == "sess-big") | .transcript_path and .recorded_epoch' "$PENDING"
}

@test "state.json records last_trigger_epoch" {
    payload=$(printf '{"session_id":"sess-big","transcript_path":"%s","cwd":"/tmp"}' "$TRANSCRIPT")
    run trigger "$payload"
    assert_success
    assert jq -e '.last_trigger_epoch > 0' "$STATE"
}

@test "duplicate session_id is not appended twice" {
    payload=$(printf '{"session_id":"sess-big","transcript_path":"%s","cwd":"/tmp"}' "$TRANSCRIPT")
    trigger "$payload"
    trigger "$payload"
    count=$(grep -c 'sess-big' "$PENDING")
    assert_equal "$count" 1
}

@test "short session is skipped" {
    short="$BATS_TEST_TMPDIR/short.jsonl"
    printf '{"type":"assistant","message":{}}\n' > "$short"
    payload=$(printf '{"session_id":"sess-short","transcript_path":"%s","cwd":"/tmp"}' "$short")
    run trigger "$payload"
    assert_success
    refute grep -q 'sess-short' "$PENDING"
}

@test "malformed stdin exits 0" {
    run trigger 'not json at all'
    assert_success
}

@test "missing transcript file exits 0 without recording" {
    payload=$(printf '{"session_id":"sess-gone","transcript_path":"%s/nonexistent.jsonl","cwd":"/tmp"}' "$BATS_TEST_TMPDIR")
    run trigger "$payload"
    assert_success
    refute grep -q 'sess-gone' "$PENDING"
}

@test "HARNESS_DISABLE=1 skips recording" {
    export HARNESS_DISABLE=1
    payload=$(printf '{"session_id":"sess-disabled","transcript_path":"%s","cwd":"/tmp"}' "$TRANSCRIPT")
    run trigger "$payload"
    assert_success
    refute grep -q 'sess-disabled' "$PENDING"
}
```

- [ ] **Step 2: Run the suite directly**

Run:
```sh
pnpm exec bats test/harness-reflect-trigger.bats
```
Expected: `7 tests, 0 failures`.

- [ ] **Step 3: Commit**

```bash
git add test/harness-reflect-trigger.bats
git commit -m "test: convert harness-reflect-trigger.sh tests to bats"
```

---

### Task 6: Convert `harness-briefing.sh` tests

**Files:**
- Create: `test/harness-briefing.bats`

**Interfaces:**
- Consumes: `test/helpers/setup.bash` (Task 1)

- [ ] **Step 1: Write the bats suite**

Create `test/harness-briefing.bats`:

```bash
setup() {
    load 'helpers/setup'
    SCRIPT="$BATS_TEST_DIRNAME/../dot_claude/scripts/executable_harness-briefing.sh"
    export HOME="$BATS_TEST_TMPDIR"
    HDIR="$HOME/.claude/harness"
    mkdir -p "$HDIR"
}

briefing() {
    bash "$SCRIPT"
}

@test "fresh install bootstraps and prints OK" {
    run briefing
    assert_success
    assert_output --partial 'Harness: OK'
    assert_output --partial 'last review: never'
    assert [ -f "$HDIR/state.json" ]
    assert [ -f "$HDIR/queue.md" ]
}

@test "review overdue with queued work warns with remedy" {
    old=$(( $(date +%s) - 30*86400 ))
    printf '{"version":1,"last_review_epoch":%s}' "$old" > "$HDIR/state.json"
    printf '## [2026-07-01] some candidate\n- **Status:** pending\n' >> "$HDIR/queue.md"
    run briefing
    assert_success
    assert_output --partial 'ATTENTION'
    assert_output --partial 'overdue'
    assert_output --partial '/harness-review'
}

@test "fresh review prints OK with queue count" {
    now=$(date +%s)
    printf '{"version":1,"last_review_epoch":%s}' "$now" > "$HDIR/state.json"
    printf '## [2026-07-01] some candidate\n- **Status:** pending\n' >> "$HDIR/queue.md"
    run briefing
    assert_success
    assert_output --partial 'Harness: OK | queue: 1 | pending: 0 | last review: 0d ago'
}

@test "pending pile-up warns" {
    now=$(date +%s)
    printf '{"version":1,"last_review_epoch":%s}' "$now" > "$HDIR/state.json"
    for i in 1 2 3 4 5 6; do
        printf '{"session_id":"s%s","transcript_path":"/tmp/t","cwd":"/tmp","recorded_epoch":%s}\n' "$i" "$now" >> "$HDIR/pending.jsonl"
    done
    run briefing
    assert_success
    assert_output --partial 'unreflected sessions'
    assert_output --partial '/harness-reflect'
}

@test "corrupt state.json warns but exits 0" {
    printf 'not json' > "$HDIR/state.json"
    run briefing
    assert_success
    assert_output --partial 'corrupt'
}

@test "non-numeric last_review_epoch warns but exits 0" {
    printf '{"version":1,"last_review_epoch":"not-a-number"}' > "$HDIR/state.json"
    run briefing
    assert_success
    assert_output --partial 'non-numeric'
}

@test "malformed recorded_epoch in pending exits 0" {
    now=$(date +%s)
    printf '{"version":1,"last_review_epoch":%s}' "$now" > "$HDIR/state.json"
    printf '{"session_id":"bad","transcript_path":"/tmp/t","cwd":"/tmp","recorded_epoch":"oops"}\n' > "$HDIR/pending.jsonl"
    run briefing
    assert_success
}
```

- [ ] **Step 2: Run the suite directly**

Run:
```sh
pnpm exec bats test/harness-briefing.bats
```
Expected: `7 tests, 0 failures`.

- [ ] **Step 3: Commit**

```bash
git add test/harness-briefing.bats
git commit -m "test: convert harness-briefing.sh tests to bats"
```

---

### Task 7: Convert `harness-doctor.sh` tests and retire the old `test-harness-scripts` recipe

**Files:**
- Create: `test/harness-doctor.bats`
- Modify: `Makefile` (replace the `test-harness-scripts:` recipe)
- Modify: `.github/workflows/lint.yml` (`harness-loop-scripts` job)

**Interfaces:**
- Consumes: `test/harness-reflect-trigger.bats` (Task 5), `test/harness-briefing.bats` (Task 6), `test/helpers/setup.bash` (Task 1)

- [ ] **Step 1: Write the bats suite**

Create `test/harness-doctor.bats`:

```bash
setup() {
    load 'helpers/setup'
    SCRIPT="$BATS_TEST_DIRNAME/../dot_claude/scripts/executable_harness-doctor.sh"
    export HOME="$BATS_TEST_TMPDIR"
    mkdir -p "$HOME/.claude/scripts" "$HOME/.claude/skills/harness-reflect" \
        "$HOME/.claude/skills/harness-review" "$HOME/.claude/harness"
    printf '{"hooks":{"x":"harness-reflect-trigger.sh and harness-briefing.sh"}}' > "$HOME/.claude/settings.json"
    printf '#!/usr/bin/env bash\n' > "$HOME/.claude/scripts/harness-reflect-trigger.sh"
    printf '#!/usr/bin/env bash\n' > "$HOME/.claude/scripts/harness-briefing.sh"
    chmod +x "$HOME/.claude/scripts/harness-reflect-trigger.sh" "$HOME/.claude/scripts/harness-briefing.sh"
    printf -- '---\nname: harness-reflect\n---\n' > "$HOME/.claude/skills/harness-reflect/SKILL.md"
    printf -- '---\nname: harness-review\n---\n' > "$HOME/.claude/skills/harness-review/SKILL.md"
    printf '{"version":1,"last_trigger_epoch":%s}' "$(date +%s)" > "$HOME/.claude/harness/state.json"
    printf '{"session_id":"s1","transcript_path":"/tmp/t","cwd":"/tmp","recorded_epoch":1}\n' > "$HOME/.claude/harness/pending.jsonl"
    printf '# Harness improvement queue\n' > "$HOME/.claude/harness/queue.md"
}

doctor() {
    bash "$SCRIPT"
}

@test "healthy fixture passes with no FAIL lines" {
    run doctor
    assert_success
    refute_output --partial 'FAIL:'
}

@test "unwired hook is detected" {
    printf '{"hooks":{}}' > "$HOME/.claude/settings.json"
    run doctor
    assert_failure
}

@test "corrupt pending.jsonl is detected" {
    printf 'not json\n' >> "$HOME/.claude/harness/pending.jsonl"
    run doctor
    assert_failure
}
```

- [ ] **Step 2: Run the suite directly**

Run:
```sh
pnpm exec bats test/harness-doctor.bats
```
Expected: `3 tests, 0 failures`.

- [ ] **Step 3: Replace the `test-harness-scripts` Makefile recipe**

In `Makefile`, find the block starting at `## Smoke test harness loop scripts (reflect-trigger, briefing, doctor)` / `test-harness-scripts:` and ending right before `## Validate the nono sandbox profile` (currently lines 477–640). Replace the entire block with:

```make
## Smoke test harness loop scripts (reflect-trigger, briefing, doctor)
test-harness-scripts:
	pnpm exec bats test/harness-reflect-trigger.bats test/harness-briefing.bats test/harness-doctor.bats
```

- [ ] **Step 4: Run the Makefile target**

Run:
```sh
make test-harness-scripts
```
Expected: `17 tests, 0 failures` total across the three files (7 + 7 + 3).

- [ ] **Step 5: Add pnpm/node setup to the `harness-loop-scripts` CI job**

In `.github/workflows/lint.yml`, find the `harness-loop-scripts` job:

```yaml
  harness-loop-scripts:
    name: harness loop script smoke tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6.1.0
        with:
          persist-credentials: false
      - run: make test-harness-scripts
```

Replace it with:

```yaml
  harness-loop-scripts:
    name: harness loop script smoke tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6.1.0
        with:
          persist-credentials: false
      - uses: pnpm/action-setup@0ebf47130e4866e96fce0953f49152a61190b271 # v6.0.9
      - uses: actions/setup-node@249970729cb0ef3589644e2896645e5dc5ba9c38 # v6.5.0
        with:
          node-version-file: '.node-version'
          cache: pnpm
      - run: pnpm install --frozen-lockfile
      - run: make test-harness-scripts
```

- [ ] **Step 6: Validate the workflow file**

Run:
```sh
make actionlint
```
Expected: no errors.

- [ ] **Step 7: Commit**

```bash
git add test/harness-doctor.bats Makefile .github/workflows/lint.yml
git commit -m "test: convert harness-doctor.sh tests to bats, retire inline Makefile recipe"
```

---

### Task 8: Convert `scan-sensitive-info.sh` tests and retire the old `test-sensitive` recipe

**Files:**
- Create: `test/scan-sensitive-info.bats`
- Modify: `Makefile` (replace the `test-sensitive:` recipe)
- Modify: `.github/workflows/lint.yml` (`test-sensitive` job)

**Interfaces:**
- Consumes: `test/helpers/setup.bash` (Task 1)

- [ ] **Step 1: Write the bats suite**

Create `test/scan-sensitive-info.bats`:

```bash
setup() {
    load 'helpers/setup'
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/scan-sensitive-info.sh"
}

scan() {
    bash "$SCRIPT" "$@"
}

# The fixtures below are deliberately PII-shaped strings (that's what a PII
# scanner test needs). The '' splits are harmless bash string concatenation
# (adjacent quoted literals join with no separator, so the printf output is
# byte-identical) inserted only to keep this same PII-shaped text from
# tripping this repo's own `make scan-sensitive` check wherever this test
# file's content is quoted inside a .md document (e.g. the plan that
# specified this file). scan-sensitive-info.sh only scans *.md files, so
# this .bats file itself is never scanned — the split exists for the
# documentation trail, not for this file's own execution.

@test "clean file exits 0" {
    printf 'No sensitive data here\n' > "$BATS_TEST_TMPDIR/clean.md"
    run scan "$BATS_TEST_TMPDIR/clean.md"
    assert_success
}

@test "file with absolute path exits 1" {
    printf '/Users/''realname/some/path\n' > "$BATS_TEST_TMPDIR/pii.md"
    run scan "$BATS_TEST_TMPDIR/pii.md"
    assert_failure
}

@test "file with SSH key exits 1" {
    printf 'signingkey = ssh-''ed25519 AAAAC3Nza\n' > "$BATS_TEST_TMPDIR/sshkey.md"
    run scan "$BATS_TEST_TMPDIR/sshkey.md"
    assert_failure
}

@test "multiple files with mixed content exits 1 if any has PII" {
    printf 'Safe content only\n' > "$BATS_TEST_TMPDIR/safe.md"
    printf '12345''+user@users.noreply.github.com\n' > "$BATS_TEST_TMPDIR/email.md"
    run scan "$BATS_TEST_TMPDIR/safe.md" "$BATS_TEST_TMPDIR/email.md"
    assert_failure
}
```

- [ ] **Step 2: Run the suite directly**

Run:
```sh
pnpm exec bats test/scan-sensitive-info.bats
```
Expected: `4 tests, 0 failures`.

- [ ] **Step 3: Replace the `test-sensitive` Makefile recipe**

In `Makefile`, find the block starting at `## Smoke test scan-sensitive-info.sh` / `test-sensitive:` and ending right before `## Smoke test harness loop scripts` (currently lines 441–475). Replace the entire block with:

```make
## Smoke test scan-sensitive-info.sh
test-sensitive:
	pnpm exec bats test/scan-sensitive-info.bats
```

- [ ] **Step 4: Run the Makefile target**

Run:
```sh
make test-sensitive
```
Expected: all 4 tests passing.

- [ ] **Step 5: Add pnpm/node setup to the `test-sensitive` CI job**

In `.github/workflows/lint.yml`, find the `test-sensitive` job:

```yaml
  test-sensitive:
    name: sensitive scan smoke tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6.1.0
        with:
          persist-credentials: false
      - run: make test-sensitive
```

Replace it with:

```yaml
  test-sensitive:
    name: sensitive scan smoke tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6.1.0
        with:
          persist-credentials: false
      - uses: pnpm/action-setup@0ebf47130e4866e96fce0953f49152a61190b271 # v6.0.9
      - uses: actions/setup-node@249970729cb0ef3589644e2896645e5dc5ba9c38 # v6.5.0
        with:
          node-version-file: '.node-version'
          cache: pnpm
      - run: pnpm install --frozen-lockfile
      - run: make test-sensitive
```

- [ ] **Step 6: Validate the workflow file**

Run:
```sh
make actionlint
```
Expected: no errors.

- [ ] **Step 7: Commit**

```bash
git add test/scan-sensitive-info.bats Makefile .github/workflows/lint.yml
git commit -m "test: convert scan-sensitive-info.sh tests to bats, retire inline Makefile recipe"
```

---

### Task 9: Convert the nono profile validation and retire the old `test-nono-profile` recipe

**Files:**
- Create: `test/nono-profile.bats`
- Modify: `Makefile` (replace the `test-nono-profile:` recipe)

**Interfaces:**
- Consumes: `test/helpers/setup.bash` (Task 1)

No CI job change: `test-nono-profile` has never run in CI (nono is not installed there), and this migration does not add one.

- [ ] **Step 1: Write the bats suite**

Create `test/nono-profile.bats`:

```bash
setup() {
    load 'helpers/setup'
    PROFILE="$BATS_TEST_DIRNAME/../dot_config/nono/profiles/claude-seal.json"
}

@test "claude-seal.json validates against the nono profile schema" {
    if ! command -v nono >/dev/null 2>&1; then
        skip "nono not installed"
    fi
    run nono profile validate "$PROFILE"
    assert_success
}
```

- [ ] **Step 2: Run the suite directly**

Run:
```sh
pnpm exec bats test/nono-profile.bats
```
Expected: `1 test, 0 failures` if `nono` is installed, or `1 test, 0 failures, 1 skipped` otherwise. Either way, exit code 0.

- [ ] **Step 3: Replace the `test-nono-profile` Makefile recipe**

In `Makefile`, find the block starting at `## Validate the nono sandbox profile (local only — CI does not install nono)` / `test-nono-profile:` (currently lines 642–651, the end of the file). Replace the entire block with:

```make
## Validate the nono sandbox profile (local only — CI does not install nono)
test-nono-profile:
	pnpm exec bats test/nono-profile.bats
```

- [ ] **Step 4: Run the Makefile target**

Run:
```sh
make test-nono-profile
```
Expected: exit code 0, matching Step 2.

- [ ] **Step 5: Commit**

```bash
git add test/nono-profile.bats Makefile
git commit -m "test: convert nono profile validation to bats, retire inline Makefile recipe"
```

---

### Task 10: Update documentation for the bats-based test harness

**Files:**
- Modify: `.claude/rules/shell-scripts.md`
- Modify: `docs/solutions/integration-issues/makefile-mktemp-silent-pass-and-macos-tmpdir-sandbox.md`

**Interfaces:**
- None (documentation only)

- [ ] **Step 1: Replace the "Makefile Test Harness Gotchas" section in `.claude/rules/shell-scripts.md`**

Find this block:

```markdown
### Makefile Test Harness Gotchas

Two traps when writing shell test cases inside a Makefile recipe:

- **Never put `%s` in a `printf` format string** used to generate a fake binary or fixture —
  it collides with the outer `printf`'s own substitution and silently emits a literal `%s`.
  Build such files with `echo` instead: `{ echo '#!/bin/sh'; echo 'printf "%s\n" "$$@" > "$$OUT"'; } > fake`
- **Never test a fallback path by emptying `$PATH`.** Stripping `PATH` also hides `bash`,
  `jq`, and `git` from the script, so the test fails for an unrelated reason. Give the script
  an explicit override variable (e.g. `CLAUDE_NOTIFY_BACKEND=osascript`) and select the
  fallback with that.

Also verify each case is non-vacuous: an assertion like `grep -q 'title='` that every possible
output satisfies cannot fail, and a case asserting on a file a *previous* case created must
name that dependency in a comment.
```

Replace it with:

```markdown
### bats Test Suite Conventions

Shell script tests live under `test/*.bats` (one file per script under test), run via
`pnpm exec bats` and wrapped by `Makefile` targets (`make test-modify`, `make test-scripts`,
etc.) so CI and local runs call the exact same command. Companion libraries
(`bats-support`, `bats-assert`) are pnpm devDependencies, loaded once via `test/helpers/setup.bash`.

- **Never create a temp file/dir with `mktemp`.** Use `$BATS_TEST_TMPDIR`, which bats
  creates fresh and destroys automatically per `@test`. This structurally eliminates the
  silent-mktemp-failure and macOS-sandbox-TMPDIR class of bug — there is no longer a
  hand-written `mktemp` call whose failure could go unchecked (see
  `docs/solutions/integration-issues/makefile-mktemp-silent-pass-and-macos-tmpdir-sandbox.md`).
- **Build fake binaries with a heredoc, not `printf`.** A heredoc (`cat > "$fake" <<'EOF' ... EOF`)
  has no outer-command substitution to collide with, unlike the old Makefile-recipe `printf`
  pattern this replaces.
- **Never test a fallback path by emptying `$PATH`.** Stripping `PATH` also hides `bash`,
  `jq`, and `git` from the script, so the test fails for an unrelated reason. Give the script
  an explicit override variable (e.g. `CLAUDE_NOTIFY_BACKEND=osascript`) and select the
  fallback with that.
- Verify each `@test` is non-vacuous: an assertion like `assert_output --partial 'title='`
  that every possible output satisfies cannot fail. Each `@test` gets its own
  `$BATS_TEST_TMPDIR`, so — unlike the old Makefile recipe — a test can never read a file a
  *different* test case left behind; if two cases seem to depend on shared state, merge them
  into one `@test`.
```

- [ ] **Step 2: Update the "Tests Must Be Hermetic Against Ambient Environment" section**

Find this block:

```markdown
Clear every variable the script reads in a baseline helper, and let individual cases pass
their own values explicitly:

```make
run() { HOME="$$tmphome" ORCA_PANE_KEY= ORCA_AGENT_HOOK_PORT= ORCA_AGENT_HOOK_TOKEN= bash "$$SCRIPT"; }; \
```

**An env-prefix assignment inside the helper wins over one on the `run` call**, so a case
needing custom values must invoke `bash "$$SCRIPT"` directly with its own full environment
rather than going through the helper.

Prove hermeticity by running the suite twice — once normally, once with the leak simulated —
and requiring identical results:

```sh
make test-scripts
ORCA_PANE_KEY=leak ORCA_AGENT_HOOK_PORT=1 ORCA_AGENT_HOOK_TOKEN=x make test-scripts
```
```

Replace it with:

```markdown
Clear every variable the script reads in the `.bats` file's `setup()`, and let individual
`@test` cases `export` their own values explicitly:

```bash
setup() {
    load 'helpers/setup'
    unset ORCA_PANE_KEY ORCA_AGENT_HOOK_PORT ORCA_AGENT_HOOK_TOKEN
}

@test "ORCA_PANE_KEY alone does not suppress" {
    export ORCA_PANE_KEY=pane
    run notify "$payload"
    ...
}
```

Prove hermeticity by running the suite twice — once normally, once with the leak simulated —
and requiring identical results:

```sh
make test-scripts
ORCA_PANE_KEY=leak ORCA_AGENT_HOOK_PORT=1 ORCA_AGENT_HOOK_TOKEN=x make test-scripts
```
```

- [ ] **Step 3: Append a resolution note to the mktemp solution doc**

Append to the end of `docs/solutions/integration-issues/makefile-mktemp-silent-pass-and-macos-tmpdir-sandbox.md`:

```markdown

## Update: Structurally Resolved by the bats-core Migration (2026-07-26)

The Makefile recipes this document describes were rewritten as bats-core suites under
`test/` (see `docs/superpowers/specs/2026-07-26-bats-core-test-migration-design.md`). Every
manual `mktemp` call site was replaced with `$BATS_TEST_TMPDIR`, which bats creates and
destroys automatically per test case. The failure mode this document describes — an
unguarded `mktemp` whose failure went unnoticed — can no longer occur, because there is no
longer a hand-written `mktemp` call in the test suite for it to happen to. This document is
kept as a historical record of why bats' automatic tmpdir handling was worth adopting.
```

- [ ] **Step 4: Verify the doc changes render as valid markdown and contain no sensitive info**

Run:
```sh
make scan-sensitive
```
Expected: no findings.

- [ ] **Step 5: Commit**

```bash
git add .claude/rules/shell-scripts.md docs/solutions/integration-issues/makefile-mktemp-silent-pass-and-macos-tmpdir-sandbox.md
git commit -m "docs: update shell-scripts.md and mktemp solution doc for bats migration"
```

---

### Task 11: Full verification

**Files:** none (verification only)

**Interfaces:** none

- [ ] **Step 1: Run the full local lint suite**

Run:
```sh
make lint
```
Expected: every target passes, including all five `test-*` targets now backed by bats.

- [ ] **Step 2: Confirm no leftover inline test shell remains in the Makefile**

`check-templates` is out of scope for this migration and legitimately keeps its own
`mktemp`/`PASS:`/`FAIL:` usage, so do not grep the whole file for those strings. Instead,
check for `cleanup()`, a pattern used only by the five migrated recipes' hand-rolled
mktemp-and-trap dance (`test-scripts`, the three `test-harness-scripts` sub-recipes, and
`test-sensitive`) and never by `check-templates`:

```sh
grep -n 'cleanup()' Makefile
```
Expected: no matches.

- [ ] **Step 3: Confirm `test/` never gets deployed**

Run:
```sh
chezmoi apply --dry-run --source "$(pwd)"
```
Expected: no line touching `~/test`.

- [ ] **Step 4: Push and open a PR (only if the user asks for this step to run)**

This step is intentionally left for the user to trigger explicitly — do not push or open a PR as part of automated task execution.
