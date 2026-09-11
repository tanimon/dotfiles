# harness 同期・検証 seam 設計(#309)

日付: 2026-09-11
ステータス: 承認済み(#308 / #309 の Implementation Decisions・Acceptance criteria から蒸留)
親: [#308 feat: unify Claude Code, Codex, and Cursor harness configuration](https://github.com/tanimon/dotfiles/issues/308)
対象: [#309 feat(harness): establish the synchronization and verification seam](https://github.com/tanimon/dotfiles/issues/309)

## 背景・目的

#308 は Claude Code / Codex / Cursor の harness 設定を「意味的に同じ」状態に保つ仕組み(semantic core + Runtime Adapter + 単一 Target Owner)を 17 の tracer-bullet チケット(#309〜#325)に分割した。#309 はその基盤で、**唯一ブロックされていない**チケットである。

#309 が提供するのは「最初の end-to-end コマンド経路」だけである。

- Harness Manifest を読み、runtime と Target Owner を**明示的に**解決する
- 4 runtime(Claude Code / Codex / Cursor / APM)の存在・バージョン・必須 capability を報告する
- fixture に対して Atomic Sync(staging → 全体検証 → 置換)と drift 検出を実証する
- **live の harness(`~/` 配下・`dot_*`・`dot_apm/`)は一切変更しない**

instructions の実生成(#310/#311)、MCP 配布(#312)、権限ポリシー(#314〜)、`chezmoi apply` 統合(#324)は後続チケットの責務であり、本設計はそれらが載る seam だけを定義する。

## 決定事項サマリ

| 論点 | 決定 | 理由 |
|---|---|---|
| 実装言語 / テスト | bash + bats-core | #308 Testing Decisions「既存 Bats テストと chezmoi テンプレート検証が prior art」。リポの lint 基盤(shellcheck / shfmt / `just test-*`)がそのまま使える |
| Manifest 形式 | JSON(`jq` で解釈) | リポに YAML パーサが無い(`jq` のみ Brewfile にある)。`*.json` は `just oxfmt` の対象なので構文検証が無料で付く |
| 配置 | リポ直下 `harness/`(repo-only、`.chezmoiignore` で除外) | 17 チケット分の subsystem になるので `scripts/`(補助スクリプト置き場)に混ぜない。`~/` には配置しない(#309「live harness を変更しない」) |
| 入口 | `harness/bin/harness.sh {check\|sync\|init\|update}` | #308 の operational surface は initialize / synchronize / check / update の 4 つ。#309 では `check` と `sync` を実装し、`init` / `update` は「未実装(#322 / #323)」を明示して exit 64 |
| Target Owner | manifest の各 target が `owner` で adapter を 1 つ指名。同じ `path` を 2 つの target が持てば manifest 全体を reject | #308「Every Target has exactly one Target Owner」 |
| runtime 検出 | manifest に `runtimes` を明示必須。空・欠落・`"*"` キー・`bin: "auto"` は reject | #308「Target auto-detection will not determine committed output」、AC「rejects implicit runtime detection」 |
| Atomic Sync | 全 target を staging に render → 全体を検証 → target ディレクトリ内に一時ファイルを書いて `mv` で置換 | #308「render into a temporary location, validate the complete Target set, and replace existing Targets only after success」 |
| 冪等性 | staging と live が同一内容なら `mv` を省略(mtime も変えない) | AC「Running synchronization twice produces no second-run changes」を厳密に満たす |
| Capability Probe | `command -v` + `--version` の semver 抽出 + `--help` 出力の正規表現照合 | #308「compatibility based on behavior rather than version strings alone」。バージョン文字列だけでは capability の有無は分からない |
| バージョン判定 | `minVersion` 未満 → FAIL、`maxVerifiedVersion` 超 → WARN(exit 0) | #308「Unknown newer versions trigger warning and conformance revalidation」 |
| full check | manifest の全 runtime を対象にし、1 つでも欠ければ FAIL。`--runtime NAME` で単一 runtime を**明示**選択 | #308「A full check requires all three declared products. Runtime-specific checks are available only through explicit selection」 |
| drift | `check` が全 target を staging に render し live と比較。差分・欠落は `DRIFT` として **owner 名付き**で報告 | #308 Testing Decisions「drift test ... asserts that checking fails with the owning Source identified」 |
| `sync` 時の drift 拒否 | **#309 では実装しない**(sync は常に owner の render で上書き) | #308「reject unapproved drift」は state ファイルが必要。生成 Target を commit する Managed Project(#310/#322)の責務として先送り |

## 用語(CONTEXT.md に追加する)

#308 は「用語は glossary に記録済み」と述べているが、実際の `CONTEXT.md` には Risk Tier と Contrast Pair しか無い。#309 のコードが導入する以下 5 語を `CONTEXT.md` に追加する(ADR は #308 全体の決定なので本チケットでは書かない)。

- **Harness Manifest**: runtime・capability・Target とその Owner を機械検証可能に宣言する JSON。
- **Target Owner**: ある Target の最終内容を書く唯一のコンポーネント(adapter)。manifest で 1 target につき 1 owner。
- **Runtime Adapter**: Harness Policy を製品固有の表現に render する実行体。`harness/adapters/<owner>.sh`。
- **Atomic Sync**: staging に全 Target を render し、全体検証に通った後だけ live を置換する同期方式。
- **Capability Probe**: 製品のバージョン文字列ではなく、実際の挙動(help 出力等)で必須機能の有無を確かめる検査。

## ディレクトリ構成

```
harness/
  bin/harness.sh          # 入口(サブコマンド分岐・オプション解析)
  lib/report.bash         # OK/WARN/FAIL/DRIFT 行の出力と集計
  lib/manifest.bash       # manifest の読み込み・検証・問い合わせ(jq)
  lib/probe.bash          # Capability Probe(存在・バージョン・capability)
  lib/render.bash         # adapter 実行・staging・全体検証・置換・drift 比較
  adapters/file.sh        # 組み込み adapter: source ファイルをそのまま Target にする
  manifest.json           # 本物のグローバル manifest(runtimes 4 つ、targets は空)
test/
  harness-sync.bats       # 振る舞いテスト(すべて bin/harness.sh 経由)
```

- `harness/` は `.chezmoiignore` に追加する(そうしないと `~/harness/` へ配置される)。
- `*.sh` / `*.bash` は justfile の `shell_files` に自動で拾われ、shellcheck / shfmt(indent 4)の対象になる。
- `harness/manifest.json` とテスト fixture の `*.json` は `json_files` に拾われ、oxfmt の対象になる。

## Harness Manifest スキーマ(version 1)

```json
{
  "version": 1,
  "runtimes": {
    "claude": {
      "bin": "claude",
      "minVersion": "2.1.268",
      "maxVerifiedVersion": "2.1.268",
      "capabilities": [
        { "name": "settings-flag", "args": ["--help"], "pattern": "--settings" }
      ]
    }
  },
  "targets": [
    { "path": "AGENTS.md", "runtime": "codex", "owner": "file", "source": "modules/agents.md" }
  ]
}
```

| フィールド | 必須 | 意味 |
|---|---|---|
| `version` | 必須 | `1` 固定。それ以外は reject |
| `runtimes` | 必須 | 非空オブジェクト。キーが runtime 名 |
| `runtimes.<name>.bin` | 必須 | `PATH` から探す実行ファイル名。`"auto"` は reject |
| `runtimes.<name>.minVersion` | 必須 | semver。未満は FAIL |
| `runtimes.<name>.maxVerifiedVersion` | 任意 | semver。超えると WARN。省略時は上限なし |
| `runtimes.<name>.versionArgs` | 任意 | 既定 `["--version"]` |
| `runtimes.<name>.capabilities[]` | 任意 | `name` / `args`(配列)/ `pattern`(ERE)。`bin args` の stdout+stderr を `grep -E pattern` で照合 |
| `targets` | 必須 | 配列(空可) |
| `targets[].path` | 必須 | `--root` からの相対パス。**重複は reject** |
| `targets[].runtime` | 必須 | `runtimes` に存在するキー。無ければ reject |
| `targets[].owner` | 必須 | adapter 名。`<adapterDir>/<owner>.sh` が実行可能でなければ reject |
| `targets[].source` 等 | 任意 | adapter 固有。`file` adapter は `source`(`--source-dir` からの相対パス)を必須とする |

検証エラーはすべて `manifest: <理由>` 形式で stderr に出し exit 2。理由文はどのフィールド・どの値が問題かを含める(例: `manifest: targets[].path "AGENTS.md" の owner が重複しています (file, copy)`)。

## Runtime Adapter 契約

```
<adapterDir>/<owner>.sh render <staging-file> <target-json>
```

- 環境変数: `HARNESS_MANIFEST`(manifest の絶対パス)、`HARNESS_ROOT`(Target のルート)、`HARNESS_SOURCE_DIR`(Content Module 等の Source ルート)。
- adapter は `<staging-file>` に Target の完全な内容を書き、exit 0 で返す。
- 非 0 exit、または `<staging-file>` が生成されなかった場合は render 失敗。
- adapter ディレクトリの解決順: `HARNESS_ADAPTER_DIR`(設定時)→ `harness/adapters`。テストは前者で fixture adapter を差し込む。
- `file` adapter: `$HARNESS_SOURCE_DIR/<target.source>` を `<staging-file>` に `cp` する。`source` 欠落・ファイル無しは exit 1 とメッセージ。

## `sync` の手順(Atomic Sync)

1. manifest を読み検証する(失敗は exit 2、何も変更しない)。
2. `mktemp -d "${TMPDIR:-/tmp}/harness-sync-XXXXXX"` で staging を作り、`trap` で必ず削除する。
3. 全 target について adapter を実行し `staging/<index>` に render する。**1 つでも失敗したら**その target と owner と exit code を `FAIL` で報告し、live に触れず exit 1。
4. 全体検証: 全 `staging/<index>` が通常ファイルとして存在することを確認する。
5. 置換: target ごとに `cmp -s staging live` が一致なら `unchanged`。異なれば親ディレクトリを作成し、`live` と同じディレクトリに一時ファイルを書いて `mv -f` で置換(同一ファイルシステム内の rename なので原子的)、`updated` と報告。
6. `harness sync: N updated, M unchanged` を出して exit 0。

`init` / `update` は `harness <cmd>: 未実装です (#322 / #323 で実装)` を stderr に出して exit 64。

## `check` の手順

1. manifest を読み検証する(失敗は exit 2)。
2. 対象 runtime を決める: 既定は manifest の**全** runtime。`--runtime NAME` があればその 1 つ(manifest に無ければ exit 2)。
3. runtime ごとに Capability Probe:
   - `command -v bin` 失敗 → `FAIL runtime <name>: 見つかりません (bin: <bin>)`
   - version 抽出(stdout+stderr から最初の `[0-9]+\.[0-9]+\.[0-9]+`)失敗 → `FAIL runtime <name>: バージョンを解釈できません`
   - `< minVersion` → `FAIL runtime <name> <v>: minVersion <min> 未満`
   - `> maxVerifiedVersion` → `WARN runtime <name> <v>: maxVerifiedVersion <max> を超えています (再検証が必要)`
   - 各 capability: `bin args` の出力に `pattern` が無ければ `FAIL runtime <name>: capability <cap> がありません`
   - すべて通れば `OK   runtime <name> <v>`
4. drift: 対象 runtime に属する target を staging に render し live と比較。
   - live 無し → `DRIFT target <path>: 存在しません (owner: <owner>)`
   - 差分 → `DRIFT target <path>: 内容が Source と異なります (owner: <owner>)`
   - render 失敗 → `FAIL target <path>: adapter <owner> が exit <n>`
   - 一致 → `OK   target <path>`
   - **live を変更しない**(staging は trap で削除)。
5. `harness check: <F> failures, <W> warnings` を出す。FAIL / DRIFT が 1 つでもあれば exit 1、WARN のみなら exit 0。

## テスト方針(bats)

すべて `harness/bin/harness.sh` を外部コマンドとして呼ぶ。内部関数は直接呼ばない(#308 Testing Decisions「primary test seam is the external harness command surface」)。

- `HOME=$BATS_TEST_TMPDIR`、`PATH="$BATS_TEST_TMPDIR/bin:$PATH"` で stub 実行ファイル(`claude` / `codex` / `cursor` / `apm`)を生成し、`--version` と `--help` の出力を制御する。
- fixture adapter `flaky.sh` は環境変数 `HARNESS_FIXTURE_FAIL=1` のとき exit 1、それ以外は target の `content` フィールドを書く。
- Contrast Pair(#308「Every Safety Invariant that could fail open will have a Contrast Pair」):
  - Atomic Sync: `HARNESS_FIXTURE_FAIL=1` で全 live Target のハッシュが不変、フラグなしで同じ manifest が全 Target を更新する。
  - Target Owner: `path` 重複 manifest は reject、重複を除いた同じ manifest は通る。
  - runtime 明示: `runtimes` 欠落は reject、明示すれば通る。
- 冪等性: `sync` を 2 回実行し、2 回目が `0 updated` かつ全 Target の `stat` mtime が不変。
- drift: `sync` 後に 1 Target を手で書き換え、`check` が exit 1 で `DRIFT` 行に owner 名を含む。`check` 後に live が書き換えられていないこと。
- `just lint` に `test-harness-sync` を組み込む(AC「existing lint entry point runs the new behavior tests」)。CI は `lint.yml` に 1 job 追加(既存 `harness-loop-scripts` job と同型)。

## 本物の manifest(`harness/manifest.json`)

2026-09-11 にこのマシンで確認した値を `minVersion` = `maxVerifiedVersion` として記録する。`targets` は空(後続チケットが追加する)。

| runtime | bin | version | capability(`--help` の pattern) |
|---|---|---|---|
| claude | `claude` | 2.1.268 | `--settings`, `--mcp-config`, `--plugin-dir` |
| codex | `codex` | 0.147.0 | `^ +mcp `, `^ +exec `, `^ +sandbox ` |
| cursor | `cursor` | 3.17.21 | `--user-data-dir`, `--install-extension` |
| apm | `apm` | 0.30.0 | `^ +install `, `^ +audit `, `^ +prune ` |

`claude --version` は `2.1.268 (Claude Code)`、`codex --version` は `codex-cli 0.147.0`、`cursor --version` は 3 行(先頭が semver)、`apm --version` は `... version 0.30.0 (...)` を出す。いずれも「最初の semver」抽出で取れる。

## 後続チケットへの引き継ぎ

- `sync` の drift 拒否(unapproved drift)と state 記録は #310/#322 で扱う。
- `chezmoi apply` からの `harness sync` 呼び出し(fatal / escape hatch)は #324。`harness/` は repo-only なので `run_` スクリプトは `{{ .chezmoi.sourceDir }}/harness/bin/harness.sh` を呼べばよい。
- runtime-mixed ファイル(`~/.claude.json` 等)の snapshot 付き部分更新は本設計に含めない。
- ADR(semantic core / 単一 Target Owner の決定)は #308 の完了時に書く。
