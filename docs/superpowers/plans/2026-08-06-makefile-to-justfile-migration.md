# Makefile to justfile Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the repo's GNU `Makefile` task runner with a `justfile`, updating every call site (CI, `package.json`, permission config, docs) so no `make` reference remains outside historical `docs/plans/`/`docs/solutions/`.

**Architecture:** A new root `justfile` ports all 15 Make targets 1:1 as just recipes (same names, same logic). Simple recipes stay one-liners; multi-line conditional recipes become `#!/usr/bin/env bash` shebang scripts. `just` itself is installed locally via Homebrew and in CI via its official install script (same pattern CI already uses for `shfmt`/`actionlint`). Every place that shells out to `make` is updated to `just` in lockstep; `Makefile` is deleted once parity is verified.

**Tech Stack:** [just](https://github.com/casey/just) (task runner), bash (recipe bodies), GitHub Actions, Homebrew.

## Global Constraints

- Full migration, no dual-running period: every call site in scope moves to `just` in this same body of work (spec Decision 1).
- Recipe names and behavior must match the existing Make targets exactly — same 15 names, same logic (spec Decision 2).
- `just` is installed via its official install script (`https://just.systems/install.sh`), pinned to version `1.58.0`, not a third-party GitHub Action or mise (spec Decision 3).
- Each CI job that needs `just` repeats its own install step; no shared composite action is introduced (spec Decision 4).
- Multi-line conditional recipes (`shellcheck`, `shfmt`, `oxlint`, `oxfmt`, `check-templates`, `scan-sensitive`) are rewritten as `#!/usr/bin/env bash` shebang scripts, not ported with Make-style backslash line continuations (spec Decision 5).
- `docs/plans/**` and `docs/solutions/**` are left referencing `make` as historical record — do not edit them (spec Decision 6).
- Full design reference: `docs/superpowers/specs/2026-08-06-makefile-to-justfile-migration-design.md`.

---

### Task 1: Create the justfile and add `just` to Brewfile

**Files:**
- Create: `justfile`
- Modify: `darwin/Brewfile`
- Read (do not modify yet): `Makefile` — used as the parity reference; deleted in Task 7.

**Interfaces:**
- Produces: a `justfile` at the repo root exposing recipes `lint`, `secretlint`, `shellcheck`, `shfmt`, `oxlint`, `oxfmt`, `actionlint`, `zizmor`, `test-modify`, `test-scripts`, `check-templates`, `scan-sensitive`, `test-sensitive`, `test-harness-scripts`, `test-nono-profile` — these exact names are consumed by Task 2 (CI), Task 3 (`package.json`), and Task 6 (docs).

- [ ] **Step 1: Add `just` to Brewfile and install it locally**

Edit `darwin/Brewfile`, inserting one line in alphabetical position (between `brew "jq"` and `brew "lazygit"`):

```diff
 brew "jq"
+brew "just"
 brew "lazygit"
```

Then install it locally so later steps in this task can run `just`:

```bash
brew install just
just --version
```

Expected: prints `just 1.58.0` (or newer if you deliberately bump the Brewfile pin — keep both in sync).

- [ ] **Step 2: Create the justfile**

Create `justfile` at the repo root with this exact content:

```just
# File discovery — mirrors .github/workflows/lint.yml and .pre-commit-config.yaml
# `| tr '\n' ' '` is required: unlike GNU Make's $(shell ...), just's backtick
# variables do NOT collapse embedded newlines to spaces, so without this a
# multi-match `find` would put each path on its own line inside the recipe
# body text instead of space-separating them on one command line.
shell_files := `find . -type f \( -name '*.sh' -o -name '*.bash' -o -name 'executable_*' \) \
    ! -name '*.tmpl' ! -name '*.mts' ! -name '*.ts' ! -name '*.mjs' \
    ! -path './node_modules/*' 2>/dev/null | tr '\n' ' '`

tmpl_files := `find . -name '*.tmpl' \
    ! -path './node_modules/*' \
    ! -name '.chezmoi.toml.tmpl' 2>/dev/null | tr '\n' ' '`

js_ts_files := `find . -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.mts' -o -name '*.ts' \) \
    ! -name '*.tmpl' \
    ! -path './node_modules/*' 2>/dev/null | tr '\n' ' '`

json_files := `find . -type f -name '*.json' \
    ! -path './node_modules/*' \
    ! -name 'pnpm-lock.yaml' \
    ! -name 'modify_*' 2>/dev/null | tr '\n' ' '`

all_md_files := `find . \( -path './node_modules' -o -path './.git' -o -path './.superpowers' \) -prune -o \
    -type f -name '*.md' -print 2>/dev/null | tr '\n' ' '`

# Run all checks (mirrors CI)
lint: secretlint shellcheck shfmt oxlint oxfmt actionlint zizmor test-modify test-scripts check-templates scan-sensitive test-sensitive test-harness-scripts test-nono-profile

# Scan for leaked secrets
@secretlint:
    pnpm exec secretlint '**/*'

# Lint shell scripts
@shellcheck:
    #!/usr/bin/env bash
    if command -v shellcheck >/dev/null 2>&1; then
        if [ -n "{{shell_files}}" ]; then
            echo "Running shellcheck..."
            shellcheck {{shell_files}}
        else
            echo "No shell files found"
        fi
    else
        echo "WARNING: shellcheck not found, skipping"
    fi

# Check shell script formatting
@shfmt:
    #!/usr/bin/env bash
    if command -v shfmt >/dev/null 2>&1; then
        if [ -n "{{shell_files}}" ]; then
            echo "Running shfmt..."
            shfmt -d -i 4 {{shell_files}}
        else
            echo "No shell files found"
        fi
    else
        echo "WARNING: shfmt not found, skipping"
    fi

# Lint JS/TS files
@oxlint:
    #!/usr/bin/env bash
    if [ -n "{{js_ts_files}}" ]; then
        echo "Running oxlint..."
        pnpm exec oxlint {{js_ts_files}}
    else
        echo "No JS/TS files found"
    fi

# Check JS/TS and JSON formatting
@oxfmt:
    #!/usr/bin/env bash
    if [ -n "{{js_ts_files}}{{json_files}}" ]; then
        echo "Running oxfmt..."
        pnpm exec oxfmt --check {{js_ts_files}} {{json_files}}
    else
        echo "No JS/TS or JSON files found"
    fi

# Lint GitHub Actions workflows (syntax + types)
@actionlint:
    #!/usr/bin/env bash
    if command -v actionlint >/dev/null 2>&1; then
        echo "Running actionlint..."
        actionlint
    else
        echo "WARNING: actionlint not found, skipping"
    fi

# Security audit GitHub Actions workflows
@zizmor:
    #!/usr/bin/env bash
    if command -v zizmor >/dev/null 2>&1; then
        echo "Running zizmor..."
        zizmor .github/workflows/
    else
        echo "WARNING: zizmor not found, skipping"
    fi

# Smoke test modify_ scripts
@test-modify:
    pnpm exec bats test/modify-karabiner.bats

# Smoke test hook scripts
# LC_ALL=C works around a bats-core locale bug: under some locales, @test names
# containing non-ASCII characters (this file's test names are in Japanese)
# register under a different name than they're looked up by, causing spurious
# "unknown test name" failures (23 -> 16 executed). See .claude/rules/shell-scripts.md.
@test-scripts:
    LC_ALL=C pnpm exec bats test/notify.bats

# Validate chezmoi templates
@check-templates:
    #!/usr/bin/env bash
    if command -v chezmoi >/dev/null 2>&1; then
        echo "Validating chezmoi templates..."
        tmpconfig=$(mktemp "${TMPDIR:-/tmp}/chezmoi-test-XXXXXX.toml") || { echo "FAIL: mktemp failed"; exit 1; }
        printf '[data]\n  profile = "personal"\n  ghOrg = "test-org"\n' > "$tmpconfig"
        fail=0
        for file in {{tmpl_files}}; do
            chezmoi execute-template \
                --config "$tmpconfig" \
                --source "$(pwd)" \
                < "$file" > /dev/null || { echo "FAIL: $file"; fail=1; }
        done
        rm -f "$tmpconfig"
        if [ "$fail" -eq 1 ]; then exit 1; fi
        echo "PASS: all templates valid"
    else
        echo "WARNING: chezmoi not found, skipping template validation"
    fi

# Scan all .md files for sensitive information (PII, credentials, absolute paths)
@scan-sensitive:
    #!/usr/bin/env bash
    if [ -n "{{all_md_files}}" ]; then
        echo "Running scan-sensitive-info..."
        bash scripts/scan-sensitive-info.sh {{all_md_files}}
    else
        echo "No .md files found"
    fi

# Smoke test scan-sensitive-info.sh
@test-sensitive:
    pnpm exec bats test/scan-sensitive-info.bats

# Smoke test harness loop scripts (reflect-trigger, briefing, doctor)
@test-harness-scripts:
    pnpm exec bats test/harness-reflect-trigger.bats test/harness-briefing.bats test/harness-doctor.bats

# Validate the nono sandbox profile (local only — CI does not install nono)
@test-nono-profile:
    pnpm exec bats test/nono-profile.bats
```

- [ ] **Step 3: Verify the justfile parses and lists all recipes**

```bash
just --list
```

Expected: lists all 15 recipes (`lint`, `secretlint`, `shellcheck`, `shfmt`, `oxlint`, `oxfmt`, `actionlint`, `zizmor`, `test-modify`, `test-scripts`, `check-templates`, `scan-sensitive`, `test-sensitive`, `test-harness-scripts`, `test-nono-profile`) with the `#` doc comments shown as descriptions. No parse errors.

- [ ] **Step 4: Run each recipe standalone and diff against its Make target**

Run each pair and confirm matching exit code and equivalent output (ignore purely cosmetic differences like just's lack of a `make: *** [target] Error N` trailer):

```bash
make secretlint;        echo "make exit: $?"
just secretlint;        echo "just exit: $?"

make shellcheck;        echo "make exit: $?"
just shellcheck;        echo "just exit: $?"

make shfmt;              echo "make exit: $?"
just shfmt;              echo "just exit: $?"

make oxlint;              echo "make exit: $?"
just oxlint;              echo "just exit: $?"

make oxfmt;               echo "make exit: $?"
just oxfmt;               echo "just exit: $?"

make actionlint;          echo "make exit: $?"
just actionlint;          echo "just exit: $?"

make zizmor;               echo "make exit: $?"
just zizmor;               echo "just exit: $?"

make test-modify;          echo "make exit: $?"
just test-modify;          echo "just exit: $?"

LC_ALL=C make test-scripts; echo "make exit: $?"
just test-scripts;          echo "just exit: $?"

make check-templates;      echo "make exit: $?"
just check-templates;      echo "just exit: $?"

make scan-sensitive;       echo "make exit: $?"
just scan-sensitive;       echo "just exit: $?"

make test-sensitive;       echo "make exit: $?"
just test-sensitive;       echo "just exit: $?"

make test-harness-scripts; echo "make exit: $?"
just test-harness-scripts; echo "just exit: $?"

make test-nono-profile;    echo "make exit: $?"
just test-nono-profile;    echo "just exit: $?"
```

Expected: every `just <target>` exit code matches its `make <target>` counterpart (both `0`), and output is equivalent (PASS/WARNING lines, file counts). If `nono` is not installed locally, both `make test-nono-profile` and `just test-nono-profile` should skip identically (check `test/nono-profile.bats`'s own skip behavior — this is unaffected by this migration).

- [ ] **Step 5: Run the aggregate `just lint` and confirm it matches `make lint`**

```bash
make lint;  echo "make lint exit: $?"
just lint;  echo "just lint exit: $?"
```

Expected: both exit `0` (or both fail on the same checks, if any pre-existing lint failures exist in the working tree — that would be a pre-existing condition unrelated to this migration).

- [ ] **Step 6: Commit**

```bash
git add justfile darwin/Brewfile
git commit -m "feat: add justfile to replace Makefile

Ports all 15 make targets to just recipes 1:1. Makefile itself and all
call sites (CI, package.json, docs) are updated in follow-up commits.

Issue: tanimon/dotfiles#232"
```

---

### Task 2: Migrate CI workflow from `make` to `just`

**Files:**
- Modify: `.github/workflows/lint.yml`

**Interfaces:**
- Consumes: the 15 recipe names produced by Task 1 (`justfile`).

- [ ] **Step 1: Replace the file**

Replace the full contents of `.github/workflows/lint.yml` with:

```yaml
name: Lint
permissions:
  contents: read

on:
  push:
    branches: [main]
  pull_request:

jobs:
  secretlint:
    name: Secretlint
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: pnpm/action-setup@0977fd99725f1db4007ccb2928dbb4e90d06cc86 # v6.0.10
      - uses: actions/setup-node@820762786026740c76f36085b0efc47a31fe5020 # v7.0.0
        with:
          node-version-file: '.node-version'
          cache: pnpm
      - run: pnpm install --frozen-lockfile
      - name: Install just
        run: curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --tag 1.58.0 --to /usr/local/bin
      - run: just secretlint

  shellcheck:
    name: ShellCheck
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - name: Install just
        run: curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --tag 1.58.0 --to /usr/local/bin
      - run: just shellcheck

  shfmt:
    name: shfmt
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - name: Install shfmt
        run: |
          SHFMT_VERSION=3.11.0
          curl -fsSL "https://github.com/mvdan/sh/releases/download/v${SHFMT_VERSION}/shfmt_v${SHFMT_VERSION}_linux_amd64" -o /usr/local/bin/shfmt
          chmod +x /usr/local/bin/shfmt
      - name: Install just
        run: curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --tag 1.58.0 --to /usr/local/bin
      - run: just shfmt

  oxlint:
    name: oxlint
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: pnpm/action-setup@0977fd99725f1db4007ccb2928dbb4e90d06cc86 # v6.0.10
      - uses: actions/setup-node@820762786026740c76f36085b0efc47a31fe5020 # v7.0.0
        with:
          node-version-file: '.node-version'
          cache: pnpm
      - run: pnpm install --frozen-lockfile
      - name: Install just
        run: curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --tag 1.58.0 --to /usr/local/bin
      - run: just oxlint

  oxfmt:
    name: oxfmt
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: pnpm/action-setup@0977fd99725f1db4007ccb2928dbb4e90d06cc86 # v6.0.10
      - uses: actions/setup-node@820762786026740c76f36085b0efc47a31fe5020 # v7.0.0
        with:
          node-version-file: '.node-version'
          cache: pnpm
      - run: pnpm install --frozen-lockfile
      - name: Install just
        run: curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --tag 1.58.0 --to /usr/local/bin
      - run: just oxfmt

  modify-scripts:
    name: modify_ script smoke tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: pnpm/action-setup@0977fd99725f1db4007ccb2928dbb4e90d06cc86 # v6.0.10
      - uses: actions/setup-node@820762786026740c76f36085b0efc47a31fe5020 # v7.0.0
        with:
          node-version-file: '.node-version'
          cache: pnpm
      - run: pnpm install --frozen-lockfile
      - name: Install just
        run: curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --tag 1.58.0 --to /usr/local/bin
      - run: just test-modify

  harness-scripts:
    name: harness script smoke tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: pnpm/action-setup@0977fd99725f1db4007ccb2928dbb4e90d06cc86 # v6.0.10
      - uses: actions/setup-node@820762786026740c76f36085b0efc47a31fe5020 # v7.0.0
        with:
          node-version-file: '.node-version'
          cache: pnpm
      - run: pnpm install --frozen-lockfile
      - name: Install just
        run: curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --tag 1.58.0 --to /usr/local/bin
      - run: just test-scripts

  harness-loop-scripts:
    name: harness loop script smoke tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: pnpm/action-setup@0977fd99725f1db4007ccb2928dbb4e90d06cc86 # v6.0.10
      - uses: actions/setup-node@820762786026740c76f36085b0efc47a31fe5020 # v7.0.0
        with:
          node-version-file: '.node-version'
          cache: pnpm
      - run: pnpm install --frozen-lockfile
      - name: Install just
        run: curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --tag 1.58.0 --to /usr/local/bin
      - run: just test-harness-scripts

  actionlint:
    name: actionlint
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - name: Install actionlint
        run: |
          ACTIONLINT_VERSION=1.7.12
          curl -fsSL "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz" \
            | tar xz -C /usr/local/bin actionlint
      - name: Install just
        run: curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --tag 1.58.0 --to /usr/local/bin
      - run: just actionlint

  zizmor:
    name: zizmor
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - name: Install zizmor
        run: pip install zizmor==1.23.1
      - name: Install just
        run: curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --tag 1.58.0 --to /usr/local/bin
      - run: just zizmor

  scan-sensitive:
    name: Scan sensitive info
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - name: Install just
        run: curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --tag 1.58.0 --to /usr/local/bin
      - run: just scan-sensitive

  test-sensitive:
    name: sensitive scan smoke tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: pnpm/action-setup@0977fd99725f1db4007ccb2928dbb4e90d06cc86 # v6.0.10
      - uses: actions/setup-node@820762786026740c76f36085b0efc47a31fe5020 # v7.0.0
        with:
          node-version-file: '.node-version'
          cache: pnpm
      - run: pnpm install --frozen-lockfile
      - name: Install just
        run: curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --tag 1.58.0 --to /usr/local/bin
      - run: just test-sensitive

  chezmoi-templates:
    name: chezmoi templates
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - name: Install chezmoi
        run: sh -c "$(curl -fsLS get.chezmoi.io)" -- -b /usr/local/bin
      - name: Install just
        run: curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --tag 1.58.0 --to /usr/local/bin
      - run: just check-templates
```

- [ ] **Step 2: Lint the workflow file itself**

```bash
just actionlint
just zizmor
```

Expected: both PASS (no syntax or security findings introduced by this edit).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/lint.yml
git commit -m "ci: switch lint workflow from make to just

Each job installs just 1.58.0 via the official install script
(matching the existing shfmt/actionlint install pattern) before
running its just recipe.

Issue: tanimon/dotfiles#232"
```

---

### Task 3: Update `package.json` lint script

**Files:**
- Modify: `package.json`

- [ ] **Step 1: Edit the `lint` script**

```diff
   "scripts": {
     "secretlint": "secretlint '**/*'",
-    "lint": "make lint",
+    "lint": "just lint",
     "verify": "pnpm run lint"
   },
```

- [ ] **Step 2: Verify**

```bash
pnpm run lint
```

Expected: runs `just lint` (visible in the command echo) and exits `0` (matching Task 1 Step 5's `just lint` result).

- [ ] **Step 3: Commit**

```bash
git add package.json
git commit -m "chore: point package.json lint script at just

Issue: tanimon/dotfiles#232"
```

---

### Task 4: Update Claude Code permission config (`settings.json.tmpl`)

**Files:**
- Modify: `dot_claude/settings.json.tmpl`

- [ ] **Step 1: Swap the allow-list entry**

At line 62, change:

```diff
-      "Bash(make:*)",
+      "Bash(just:*)",
```

Keep it in the same alphabetically-sensitive position in the list (between `Bash(lsof:*)` and `Bash(mise:*)`) — do not resort the whole list; just replace this one line in place even though `just` would alphabetically sort near `Bash(jq:*)`/`Bash(ls:*)`. (Rationale: this list is not strictly alphabetized throughout the file already; minimize diff noise instead of drive-by resorting.)

- [ ] **Step 2: Update the accompanying comment**

Find the long template comment block starting `{{/* Package/module install gate: ...`. Within it, replace:

```diff
-`make lint` (Bash(make:*), still in allow) invokes pnpm without prompting; acceptable because make targets are version-controlled and reviewable.
+`just lint` (Bash(just:*), still in allow) invokes pnpm without prompting; acceptable because just recipes are version-controlled and reviewable.
```

(Match this against the exact current wording inside the comment — it currently reads with backticks around `make lint` and parenthetical `Bash(make:*)`; preserve the surrounding sentence structure, only substitute `make`/`Makefile` vocabulary for `just`/`justfile` vocabulary.)

- [ ] **Step 3: Verify the template still renders**

```bash
just check-templates
```

Expected: `PASS: all templates valid` (confirms the `.tmpl` edit didn't break Go template syntax).

- [ ] **Step 4: Verify JSON formatting**

```bash
just oxfmt
```

Expected: passes (settings.json.tmpl is not itself a `.json` file so this only matters if formatting of the surrounding structure changed — run it anyway as a safety net for adjacent files).

- [ ] **Step 5: Commit**

```bash
git add dot_claude/settings.json.tmpl
git commit -m "chore: update Claude Code permissions from make to just

Issue: tanimon/dotfiles#232"
```

---

### Task 5: Update `security-alerts.yml` workflow references

**Files:**
- Modify: `.github/workflows/security-alerts.yml`

- [ ] **Step 1: Edit the instructional prompt text**

At line 177:

```diff
-            - Run `make lint` before any commits
+            - Run `just lint` before any commits
```

- [ ] **Step 2: Edit the allowed-tools list**

At line 180:

```diff
-          claude_args: '--allowedTools "Bash(git *),Bash(gh *),Bash(make *),Bash(pnpm *),Bash(cat *),Read,Write,Edit,Glob,Grep"'
+          claude_args: '--allowedTools "Bash(git *),Bash(gh *),Bash(just *),Bash(pnpm *),Bash(cat *),Read,Write,Edit,Glob,Grep"'
```

- [ ] **Step 3: Lint the workflow**

```bash
just actionlint
just zizmor
```

Expected: both PASS.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/security-alerts.yml
git commit -m "ci: update security-alerts workflow from make to just

Issue: tanimon/dotfiles#232"
```

---

### Task 6: Update documentation references

**Files:**
- Modify: `CLAUDE.md`
- Modify: `.claude/rules/shell-scripts.md`
- Modify: `dot_config/nono/CLAUDE.md`
- Modify: `dot_claude/skills/harness-review/SKILL.md`

- [ ] **Step 1: Update `CLAUDE.md` "Common Commands" section**

```diff
 # Linting (mirrors CI — also runs on commit via prek)
-make lint                      # Run all checks (secretlint + shellcheck + shfmt + oxlint + oxfmt + actionlint + zizmor + modify_ + script tests + templates + sensitive scan + nono profile)
+just lint                      # Run all checks (secretlint + shellcheck + shfmt + oxlint + oxfmt + actionlint + zizmor + modify_ + script tests + templates + sensitive scan + nono profile)
 pnpm exec secretlint '**/*'   # Scan for leaked secrets only
```

- [ ] **Step 2: Update `CLAUDE.md` "Verification" section**

```diff
 ## Verification

 ```sh
-make lint                      # Run ALL checks locally (mirrors CI)
+just lint                      # Run ALL checks locally (mirrors CI)
 chezmoi apply --dry-run        # Preview changes before applying

 # Individual targets (same as CI jobs):
-make secretlint                # Scan for leaked secrets
-make shellcheck                # Lint non-.tmpl shell scripts
-make shfmt                     # Check shell script formatting (indent=4)
-make oxlint                    # Lint JS/TS files (.js, .mjs, .mts, .ts)
-make oxfmt                     # Check JS/TS and JSON formatting
-make actionlint                # Lint GitHub Actions workflows (syntax + types)
-make zizmor                    # Security audit GitHub Actions workflows
-make test-modify               # Smoke test modify_ scripts
-make test-scripts              # Smoke test harness scripts
-make test-harness-scripts      # Smoke test harness loop scripts (trigger/briefing/doctor)
-make check-templates           # Validate chezmoi .tmpl files
-make scan-sensitive            # Scan all .md files for PII and sensitive info
-make test-sensitive             # Smoke test sensitive info scanner
-make test-nono-profile         # Validate the nono sandbox profile (skipped if nono absent)
+just secretlint                # Scan for leaked secrets
+just shellcheck                # Lint non-.tmpl shell scripts
+just shfmt                     # Check shell script formatting (indent=4)
+just oxlint                    # Lint JS/TS files (.js, .mjs, .mts, .ts)
+just oxfmt                     # Check JS/TS and JSON formatting
+just actionlint                # Lint GitHub Actions workflows (syntax + types)
+just zizmor                    # Security audit GitHub Actions workflows
+just test-modify               # Smoke test modify_ scripts
+just test-scripts              # Smoke test harness scripts
+just test-harness-scripts      # Smoke test harness loop scripts (trigger/briefing/doctor)
+just check-templates           # Validate chezmoi .tmpl files
+just scan-sensitive            # Scan all .md files for PII and sensitive info
+just test-sensitive             # Smoke test sensitive info scanner
+just test-nono-profile         # Validate the nono sandbox profile (skipped if nono absent)
 ```

-Note: shellcheck, shfmt, oxlint, and oxfmt cannot lint `.tmpl` files (Go template syntax is incompatible). CI (`.github/workflows/lint.yml`) and local use the same `make` targets — if it passes locally, CI will pass too. For similar past issues, search `docs/solutions/`.
+Note: shellcheck, shfmt, oxlint, and oxfmt cannot lint `.tmpl` files (Go template syntax is incompatible). CI (`.github/workflows/lint.yml`) and local use the same `just` recipes — if it passes locally, CI will pass too. For similar past issues, search `docs/solutions/`.
```

Also search the rest of `CLAUDE.md` for any other `make ` occurrence and update it the same way:

```bash
grep -n '`make \|make lint\|make test-\|make check-\|make scan-\|make secretlint\|make shellcheck\|make shfmt\|make oxlint\|make oxfmt\|make actionlint\|make zizmor' CLAUDE.md
```

Expected after edits: no output.

- [ ] **Step 3: Update `.claude/rules/shell-scripts.md`**

Line 49:

```diff
-- **CI** (`.github/workflows/lint.yml`): Each CI job calls `Makefile` targets directly — local and CI run the exact same commands
+- **CI** (`.github/workflows/lint.yml`): Each CI job calls `justfile` recipes directly — local and CI run the exact same commands
```

Line 51:

```diff
-- **Local** (`Makefile`): `make lint` runs all checks. Individual targets: `make shellcheck`, `make shfmt`, `make secretlint`, `make test-modify`, `make test-scripts`, `make check-templates`
+- **Local** (`justfile`): `just lint` runs all checks. Individual recipes: `just shellcheck`, `just shfmt`, `just secretlint`, `just test-modify`, `just test-scripts`, `just check-templates`
```

Lines 131-132:

```diff
-make test-scripts
-ORCA_PANE_KEY=leak ORCA_AGENT_HOOK_PORT=1 ORCA_AGENT_HOOK_TOKEN=x make test-scripts
+just test-scripts
+ORCA_PANE_KEY=leak ORCA_AGENT_HOOK_PORT=1 ORCA_AGENT_HOOK_TOKEN=x just test-scripts
```

Line 143:

```diff
-`pnpm exec bats` で実行し、`Makefile` のターゲット（`make test-modify`, `make test-scripts`
+`pnpm exec bats` で実行し、`justfile` のレシピ（`just test-modify`, `just test-scripts`
```

(Line 144 continues "など）がラップすることで..." — unchanged, only the line-143 fragment above changes.)

- [ ] **Step 4: Update `dot_config/nono/CLAUDE.md`**

Find and replace these three fragments (each appears once in the file, embedded in longer paragraphs — match on the exact substring shown, leave the rest of each paragraph untouched):

```diff
-so `make oxfmt` checks its syntax and `make test-nono-profile` checks it semantically.
+so `just oxfmt` checks its syntax and `just test-nono-profile` checks it semantically.
```

```diff
-scanned by `make lint`'s secretlint pass, which is precisely the "may embed secrets" premise the group assumes.
+scanned by `just lint`'s secretlint pass, which is precisely the "may embed secrets" premise the group assumes.
```

```diff
-so `make lint` (`Bash(make:*)`, still in `allow`) invokes `pnpm` without a prompt — acceptable because `make` targets are version-controlled and reviewable;
+so `just lint` (`Bash(just:*)`, still in `allow`) invokes `pnpm` without a prompt — acceptable because `just` recipes are version-controlled and reviewable;
```

- [ ] **Step 5: Update `dot_claude/skills/harness-review/SKILL.md`**

Line 68:

```diff
-3. Run `make lint` and fix findings.
+3. Run `just lint` and fix findings.
```

- [ ] **Step 6: Verify no live doc still references `make`**

```bash
grep -rn 'make lint\|make secretlint\|make shellcheck\|make shfmt\|make oxlint\|make oxfmt\|make actionlint\|make zizmor\|make test-modify\|make test-scripts\|make check-templates\|make scan-sensitive\|make test-sensitive\|make test-harness-scripts\|make test-nono-profile\|`Makefile`\|Bash(make' \
  CLAUDE.md .claude/rules/shell-scripts.md dot_config/nono/CLAUDE.md dot_claude/skills/harness-review/SKILL.md dot_claude/settings.json.tmpl .github/workflows/lint.yml .github/workflows/security-alerts.yml
```

Expected: no output.

- [ ] **Step 7: Run the sensitive-info and markdown checks**

```bash
just scan-sensitive
```

Expected: no new findings (these are prose edits only, no new paths/PII introduced).

- [ ] **Step 8: Commit**

```bash
git add CLAUDE.md .claude/rules/shell-scripts.md dot_config/nono/CLAUDE.md dot_claude/skills/harness-review/SKILL.md
git commit -m "docs: update make references to just across live docs

docs/plans/** and docs/solutions/** are historical records and are
intentionally left referencing make.

Issue: tanimon/dotfiles#232"
```

---

### Task 7: Delete the Makefile and run the final verification sweep

**Files:**
- Delete: `Makefile`

- [ ] **Step 1: Delete the Makefile**

```bash
git rm Makefile
```

- [ ] **Step 2: Repo-wide sweep for any remaining live `make` call site**

```bash
git grep -nE '\bmake (lint|secretlint|shellcheck|shfmt|oxlint|oxfmt|actionlint|zizmor|test-modify|test-scripts|check-templates|scan-sensitive|test-sensitive|test-harness-scripts|test-nono-profile)\b|Bash\(make' \
  -- ':!docs/plans' ':!docs/solutions'
```

Expected: no output. (If anything shows up, it's a call site Tasks 2-6 missed — fix it before proceeding.)

- [ ] **Step 3: Confirm `.pre-commit-config.yaml` is unaffected**

```bash
grep -n 'make\|just' .pre-commit-config.yaml
```

Expected: no output — this file invokes tools directly (`pnpm exec secretlint`, `shellcheck`, etc.), never through `make`/`just`, so it needs no change (spec "Out of Scope").

- [ ] **Step 4: Full end-to-end verification**

```bash
just lint
```

Expected: exits `0`, same as `make lint` did before deletion (Task 1 Step 5 baseline).

```bash
pnpm run lint
```

Expected: exits `0` (this now shells out through `just lint` per Task 3).

```bash
just --list
```

Expected: still lists all 15 recipes correctly (confirms deleting `Makefile` didn't affect `justfile` parsing — they're independent files).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore: remove Makefile, migration to justfile complete

All call sites (CI, package.json, settings.json.tmpl, docs) now use
just exclusively. Verified via 'just lint' and 'pnpm run lint'.

Closes tanimon/dotfiles#232"
```
