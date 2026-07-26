---
date: 2026-03-28
trigger: "Agent writes shell scripts without proper headers or safety patterns"
paths:
  - ".chezmoiscripts/**"
  - "scripts/**"
  - "dot_claude/scripts/**"
---

# Shell Scripts

Rules for `.chezmoiscripts/` and other shell scripts in this repository.

## Script Header

All scripts must start with:

```bash
#!/usr/bin/env bash
set -euo pipefail
```

## run_onchange_ Scripts

- Track content hashes in comments: `# brewfile hash: {{ include "darwin/Brewfile" | sha256sum }}`
- Place all `run_onchange_` scripts in `.chezmoiscripts/` (not the source tree root)
- Guard for missing tools gracefully — new machines may not have all tools on first apply:

```bash
command -v pnpm >/dev/null 2>&1 || { echo "WARNING: pnpm not found, skipping"; exit 0; }
```

## Template Scripts (.tmpl)

- `.tmpl` scripts are NOT compatible with shellcheck or shfmt (Go template syntax)
- Pre-commit hooks and CI exclude `.tmpl` files from shell linting
- Keep template logic minimal — prefer simple conditionals over complex template nesting

## Non-Template Scripts

- Must pass shellcheck and shfmt (`shfmt -i 4`)
- Place in `scripts/` for repo-only helpers
- Place in `.chezmoiscripts/` for chezmoi lifecycle scripts

## CI Enforcement

These rules are enforced automatically — not just advisory:

- **CI** (`.github/workflows/lint.yml`): Each CI job calls `Makefile` targets directly — local and CI run the exact same commands
- **Pre-commit** (`.pre-commit-config.yaml`): Runs shellcheck, shfmt, and secretlint automatically before each commit via prek
- **Local** (`Makefile`): `make lint` runs all checks. Individual targets: `make shellcheck`, `make shfmt`, `make secretlint`, `make test-modify`, `make test-scripts`, `make check-templates`

`.tmpl` files are excluded from shell linting because Go template syntax is incompatible with shell linters.


## Hook Scripts

Rules for Claude Code hook scripts (`dot_claude/scripts/`).

### Exit Code Contract

- `exit 0` — intentional skip (tool guard missing, non-project context, already ran)
- `exit 1` + stderr message — actionable error
- Never `exit 1` without stderr — produces confusing "No stderr output" message in Claude Code

### PostToolUse Hook Environment Variables

Claude Code sets `$CLAUDE_FILE` to the affected file path for `PostToolUse` hooks (e.g., after `Edit` or `Write` tool use). Use it to conditionally run formatters or linters based on file extension:

```bash
FILE="$CLAUDE_FILE"
case "$FILE" in *.go) gofmt -w "$FILE" ;; esac
```

### Session Identity

Extract session ID from stdin JSON (stable across all hook invocations in a session):

```bash
SESSION_ID=$(jq -r '.session_id // empty') || exit 0
[[ -z "$SESSION_ID" ]] && exit 0
```

Do not use `$PPID` or `$$` — these are unreliable in `bash -c` hook wrappers.

### One-Shot Flag Pattern

For hooks that should fire only once per session:

```bash
FLAG_FILE="/tmp/claude-<hook-name>-${SESSION_ID}"
[[ -f "$FLAG_FILE" ]] && exit 0

# ... context guards (directory exclusions, git checks) ...

# Set flag AFTER guards, not before — otherwise a non-project context
# consumes the flag and the hook silently skips in project contexts later.
touch "$FLAG_FILE"
```

### Tests Must Be Hermetic Against Ambient Environment

Hook scripts branch on environment variables that are **already set in this machine's normal
shell**. A test that does not neutralize them passes or fails for the wrong reason.

The concrete case: `dot_claude/scripts/executable_notify.sh` suppresses itself when
`ORCA_PANE_KEY`, `ORCA_AGENT_HOOK_PORT`, and `ORCA_AGENT_HOOK_TOKEN` are all set — and the
maintainer works inside orca-managed terminals, where they are. The first version of the test
suite passed in CI and failed on the maintainer's machine every time.

`.bats` ファイルの `setup()` で読み込む各変数をクリアし、個々の `@test` ケースが必要な値を
明示的に `export` する:

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

hermeticity（環境からの独立性）を証明するには、スイートを2回実行する——1回は通常通り、もう1回は
漏れをシミュレートして——そして結果が一致することを要求する:

```sh
make test-scripts
ORCA_PANE_KEY=leak ORCA_AGENT_HOOK_PORT=1 ORCA_AGENT_HOOK_TOKEN=x make test-scripts
```

unset すべき変数は `ORCA_PANE_KEY`/`ORCA_AGENT_HOOK_PORT`/`ORCA_AGENT_HOOK_TOKEN` に限らない。
テスト対象スクリプトが実際に読んでいる環境変数はすべて対象で、他に `HARNESS_DISABLE`
（`executable_harness-reflect-trigger.sh` のオプトアウト）や `CLAUDE_NOTIFY_BACKEND`
（`executable_notify.sh` のフォールバック指定）が該当する。

### batsテストスイートの規約

シェルスクリプトのテストは `test/*.bats` 配下に置く（テスト対象スクリプトごとに1ファイル）。
`pnpm exec bats` で実行し、`Makefile` のターゲット（`make test-modify`, `make test-scripts`
など）がラップすることで、CIとローカルが全く同じコマンドを実行する。付随ライブラリ
（`bats-support`, `bats-assert`）は pnpm devDependency として管理し、`test/helpers/setup.bash`
で一度だけロードする。

- **`mktemp` で一時ファイル/ディレクトリを作らない。** `$BATS_TEST_TMPDIR` を使う。bats が
  `@test` ごとに自動生成・自動削除する。これにより mktemp の失敗を握りつぶすバグや macOS
  サンドボックスの TMPDIR 問題のクラスが構造的に解消される——手書きの `mktemp` 呼び出し自体が
  存在しないため、失敗をチェックし忘れることがあり得ない
  （`docs/solutions/integration-issues/makefile-mktemp-silent-pass-and-macos-tmpdir-sandbox.md` 参照）。
- **偽バイナリは `printf` ではなく heredoc で作る。** heredoc（`cat > "$fake" <<'EOF' ... EOF`）は
  外側のコマンド置換と衝突しない。これは今回置き換えた旧Makefileレシピの `printf` パターンとは
  異なる。
- **フォールバック経路を `$PATH` を空にしてテストしない。** `PATH` を空にすると `bash`/`jq`/`git`
  までスクリプトから見えなくなり、無関係な理由でテストが失敗する。スクリプトに明示的な上書き
  変数（例: `CLAUDE_NOTIFY_BACKEND=osascript`）を用意し、それでフォールバックを選択する。
- 各 `@test` が非空虚（vacuous でない）ことを確認する。`assert_output --partial 'title='` の
  ように、あらゆる出力が満たしてしまうアサーションは失敗し得ない。`@test` ごとに専用の
  `$BATS_TEST_TMPDIR` が与えられるため、旧Makefileレシピと異なり、*別の*テストケースが残した
  ファイルを読むことはできない。もし2つのケースが状態を共有しているように見えるなら、1つの
  `@test` に統合すること。
- **非ASCIIの `@test` 名は bats-core のロケール依存バグを踏むことがある。** `test/notify.bats`
  はテスト名に日本語（「許可待ち」など）を含むため、`LC_ALL=C` なしで実行すると登録名と検索名が
  食い違い、23件中16件しか実行されず exit 1 になる。`Makefile` の `test-scripts` レシピが
  `LC_ALL=C pnpm exec bats test/notify.bats` としているのはこの回避策であり、一見不要に見えても
  削除しないこと。

### Reference

- `docs/solutions/developer-experience/autonomous-harness-engineering-hooks-2026-03-28.md`
- `docs/solutions/integration-issues/claude-code-hook-exit-code-and-stderr-semantics.md`

## Avoiding Recursion

- Never call `chezmoi add` from `run_after_` scripts — this causes infinite recursion
- Instead, use `cp` + `sed` to write directly to the source directory
