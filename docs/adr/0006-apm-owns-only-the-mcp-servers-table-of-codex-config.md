---
status: accepted
date: 2026-09-18
---

# MCP は claude と codex の両方へ配り、APM は `~/.codex/config.toml` の `[mcp_servers.*]` テーブルだけを所有する

ADR 0005 は #308 の範囲を指示文の共有に縮小し、その一環で `~/.codex/config.toml` は「触らない」と決めた。しかし MCP は指示文と性質が違う — 指示文は製品ごとの語彙へ**意図を翻訳**する必要があり、翻訳先の無い製品向けに翻訳規則を先回りで設計することが #308 の重さの原因だったが、**MCP は同じサーバー定義をそのまま配るだけで翻訳が無い**。そこで MCP に限り ADR 0005 の再開条件（第 2 の製品を日常利用している事実）の外に置き、配布先を `claude` と `codex` の 2 つにする。`codex` を選んだのは利用の事実があるからで（`~/.codex/config.toml` には既に手で入れた `[mcp_servers.*]` が存在する）、`cursor` は `~/.cursor/mcp.json` が存在せず MCP を使った実績が無いため対象外とする。その代わり `~/.codex/config.toml` の不可侵を**テーブル単位に緩める**: `[mcp_servers.*]` だけは APM が書き、`[projects.*]` の trust 記録・model 設定・その他は従来どおり Runtime State として触らない。

## Considered Options

- **`~/.codex/config.toml` を丸ごと不可侵のままにし、MCP も claude だけに配る** — 却下。ADR 0005 が避けたかったのは「翻訳器の無い製品向けの先回り設計」であって、翻訳の要らない資産の配布まで止める理由は無い。codex 側には既に MCP を手で入れた実績があり、手で揃え続ける状態が残る。
- **`[mcp_servers.*]` を chezmoi の `modify_` スクリプトで部分所有する**（`modify_karabiner.json` と同じパターン） — 却下。所有は本物になり後述の in-place update 問題も同時に解けるが、`dot_apm/apm.yml` という Source が既にある以上、同じテーブルに 2 つ目の writer を入れることになり、ADR 0001 の「1 Target 1 Owner」を**今度は実際に破る**。現状は「APM だけが書く」ので writer は 1 つに保たれている。これをやるなら APM から MCP を剥がす全面移行で、範囲が違う。
- **`cursor` も配布先に含める** — 却下。`~/.cursor/mcp.json` は存在せず、Cursor で MCP を使った実績が無い。存在しない利用に向けて新しい Target ファイルを生やすのは、ADR 0005 が畳んだ失敗の形そのもの。

## Consequences

- **APM の所有は不完全であり、その境界は「APM が書いたかどうか」ではなく「lock に名前があるかどうか」である。** 実測（偽 `HOME` の fixture、`test/apm-mcp-distribution.bats` が固定）で確認した挙動は 4 つ:
  1. lock に**名前が無い**エントリ（Codex 自身が入れた `node_repl`）と `[projects.*]` の trust 記録は**保持される**。
  2. `apm.yml` から依存を消して再 install すると、**有効な全 Target から削除される**（prune は lock の `mcp_servers` を名前の台帳として動く）。
  3. **その prune は APM が書いていないエントリにも及ぶ。** 本 ADR に伴って `codex` サーバーを `apm.yml` から削除した際、`~/.codex/config.toml` に**手で**書かれていた `[mcp_servers.codex]`（`enabled = false` 付き）も `Removed stale MCP server 'codex' from Codex CLI config` として消えた。今回は無効化のためだけに存在していたエントリなので結果は意図どおりだが、**Codex 側に同名のサーバーを手で置くと、その名前を `apm.yml` から外した瞬間に巻き添えで消える**。Target に手で足すサーバーは `apm.yml` に載っている名前と衝突させないこと。
  4. **既に同名のエントリがある場合、定義が `apm.yml` と食い違っていても更新しない**（`already configured` と表示して素通りする）。この穴は codex 固有ではなく claude 経路にも元からある。回避策は「`apm.yml` から消して再 install し、prune させてから足し直す」。恒久対応は #349。
- **配布先はサーバー単位で選べない。** MCP 依存ごとの `targets:` キーは APM 0.30 では非対応で、書いても `unknown key(s) preserved in extra: targets` と警告したうえで**そのゴミキーを両製品の設定に書き込む**。よって配布は all-or-nothing になる。これに伴い、Codex 自身を MCP として Codex に配る再帰を避けるため、未使用だった `codex` MCP サーバーを `apm.yml` から削除した（将来 Claude 側で必要になったら、再帰配布の扱いと併せて再検討する）。
- **配布先の宣言は `apm.yml` の `targets:` と install script の `--target` に意図的に二重化する。** 片方だけにすると、キー名の変更や書式ミスで**黙って auto-detect にフォールバックし、Gemini CLI・Kiro など検出された全ランタイムへ fan-out する**（`--target` を省略した場合の既知の挙動）。フェイルオープンの向きが悪いため冗長さを買う。
- `apm.lock.yaml` は `~/.apm/` の Runtime State のままとし、version control しない。prune は配備先の lock で動くので、Source に持つ必要が無い。APM パッケージ（`dependencies.apm`）は 2026-08-10 に撤回済みで固定すべき revision が存在しない。
