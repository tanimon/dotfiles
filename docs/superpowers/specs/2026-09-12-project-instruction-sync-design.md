# このリポジトリを最初の Managed Project にする設計(#310)

日付: 2026-09-12
ステータス: 承認済み(#308 / #310 の Acceptance criteria と、Cursor の AGENTS.md 対応調査から蒸留)
親: [#308 feat: unify Claude Code, Codex, and Cursor harness configuration](https://github.com/tanimon/dotfiles/issues/308)
対象: [#310 feat(harness): synchronize this repository's project instructions](https://github.com/tanimon/dotfiles/issues/310)
前提: [#309 harness 同期・検証 seam](2026-09-11-harness-sync-seam-design.md)(実装済み)

## 背景・目的

このリポジトリの `CLAUDE.md`(235 行)と `AGENTS.md`(8 行)は手で二重管理されていて、実際に食い違っている。`AGENTS.md` は「`CLAUDE.md` を全文読め」と指示したうえで例外を散文で列挙しているだけなので、Codex には `/harness-reflect` のような Claude Code 専用のスラッシュコマンドや `~/.claude/` 配下のパスがそのまま渡る。Cursor にはプロジェクト指示が一切無い。#308 が解こうとしているドリフトの実例がこのリポジトリ自身にある。

#310 は、このリポジトリを最初の **Managed Project** にして、1 つの Source(Content Module 群)から 3 製品のネイティブな instruction Target を生成し、直接編集を drift として検出できる状態にする。

#309 が作った seam(Harness Manifest / Runtime Adapter / Atomic Sync / drift 検出)の上に載せるので、新規に作るのは **Content Module の Source・`compose` adapter・プロジェクト用 manifest・CI 導線** の 4 つだけである。

## 決定事項サマリ

| 論点 | 決定 | 理由 |
|---|---|---|
| Cursor の Target 形 | `AGENTS.md` に相乗りし、`.cursor/rules/dotfiles.mdc` には Cursor 固有の Runtime Extension だけを置く | Cursor は **project root の `AGENTS.md` をネイティブに読む**(後述の調査)。`.mdc` にも共有内容を入れると Cursor だけが同じ内容を 2 回ロードする。#308 が hook で拒否した重複ロードと同型 |
| `AGENTS.md` の runtime 拡張 | Codex 専用ではなく「Claude 以外のエージェント共通」の注記にする | 同じファイルを Codex と Cursor が読むので、片方にしか当てはまらない記述を入れられない |
| Content Module の置き場 | `harness/modules/`(repo-only、`.chezmoiignore` の `harness` で除外済み) | `harness/` は既に repo-only の subsystem。Managed Project 一般の置き場の規約は #322(enroll)で決める |
| プロジェクト manifest | `harness/project.json`(`harness/manifest.json` とは別ファイル) | `manifest.json` の `targets[].path` は `--root`(= `$HOME`)からの相対で、#311 がグローバル Target を足す。プロジェクト Target は repo root からの相対なので、同じ `--root` に混ぜられない |
| adapter | 新規 `compose`(複数 Content Module の連結 + 任意の frontmatter + banner) | 既存の `file` adapter は 1 ファイルの `cp` しかできない。Target ごとに異なるモジュール構成と `.mdc` frontmatter が要る |
| CI での drift 検出 | `check` に `--no-probe` を追加し、Capability Probe を飛ばして Target の drift だけを見る | #308「Static CI does not claim successful runtime loading when the product is absent」。CI には claude / codex / cursor が無いので、probe 付きの `check` は常に FAIL になり使えない |
| `--no-probe` の可視化 | 省略したことを 1 行出力する(黙って通さない) | このリポジトリの方針(`scan-sensitive` の resolver skip と同じ): 静かな pass は「clean」に見える |
| `sync` の drift 拒否 | **#310 でも実装しない**(#322 に持ち越す) | 生成 Target を commit する以上、手編集は `git diff` と CI の `check` で必ず見える。承認済み drift の state を持つ機構は enroll(#322)と一緒に設計する |
| 生成物の banner | 各 Target の先頭に「自動生成・直接編集するな」の HTML コメントを入れる | drift 検出は事後。編集しようとした時点で気づける方が安い |
| 言語 | 既存 `CLAUDE.md` の英文はそのまま移送し、新規に書く部分だけ日本語 | `~/.claude/rules/common/documentation-language.md`「既存の英語ドキュメントの一括翻訳は行わない。1 ファイル内の混在を許容する」 |

## Cursor の AGENTS.md 対応(調査結果)

`https://cursor.com/docs/context/rules`(2026-09-12 時点)より:

- Cursor の rule は 4 種類: Project Rules(`.cursor/rules/*.mdc`)・User Rules・Team Rules・**AGENTS.md**。
- > AGENTS.md is a simple markdown file for defining agent instructions. Place it in your project root as an alternative to `.cursor/rules` for straightforward use cases.
- > Cursor supports AGENTS.md in the project root and subdirectories.
- `.cursor/rules` の `.md` は**無視される**(frontmatter が無いため)。`.mdc` 必須。
- frontmatter は `alwaysApply` / `description` / `globs` の 3 つで挙動が決まり、`alwaysApply: true` なら常に読み込まれ `description` と `globs` は無視される。

つまり `.mdc` に共有内容を入れると、Cursor は `AGENTS.md` と `.mdc` の両方から同じ内容を受け取る。よって `.mdc` は Cursor 固有の Runtime Extension 専用にする。

Claude Code が `AGENTS.md` を読まないことは実測で確認した(後述の検証表)。したがって Claude 側に重複ロードは無い。

## Target 構成

| Target | runtime | 内容 | ネイティブな発見経路 |
|---|---|---|---|
| `CLAUDE.md` | claude | Claude 前文 + 共有モジュール + Claude Runtime Extension(末尾) | Claude Code が repo root の `CLAUDE.md` を読む |
| `AGENTS.md` | codex | Codex/Cursor 共通前文 + **非 Claude 注記(先頭)** + 共有モジュール | Codex と Cursor が repo root の `AGENTS.md` を読む |
| `.cursor/rules/dotfiles.mdc` | cursor | frontmatter(`alwaysApply: true`)+ Cursor Runtime Extension のみ | Cursor が `.cursor/rules/*.mdc` を読む |

### `AGENTS.md` だけ Runtime Extension が先頭にある理由

**Codex は `project_doc_max_bytes`(既定 32 KiB)で `AGENTS.md` を黙って切り捨てる。** 生成後の `AGENTS.md` は約 43 KB なので、Claude 側と同じく Runtime Extension を末尾に置くと、製品固有の注意書きがまるごと Codex に届かない。

`codex debug prompt-input`(codex 0.147.0、2026-09-12)で実測した経緯:

1. Runtime Extension を末尾に置いた最初の生成では、prompt に現れる最後の行は `AGENTS.md` の 187 行目(先頭から 29,499 バイト)で、「Notes for non-Claude agents」節と `## Agent docs` 節、および Known Pitfalls の nono 節が欠落していた。
2. `codex -c project_doc_max_bytes=200000 debug prompt-input` では同じ文字列が現れる。よって切り捨ての原因は `project_doc_max_bytes` で確定。
3. Runtime Extension を前文の直後へ移した後は、既定設定のままで注意書きと切り捨て警告の両方が prompt に現れる。

この制約への対処は 4 段構えにした。散文を削って 32 KiB 未満に収める案は採らない — Claude 側の指示を薄めることになり、#310 の範囲も超える。代わりに **`modules` が Target ごとに独立している** という既存の機構だけで、「何が落ちるか」を宣言・検査できる状態にする。

- **モジュール分割**: 旧 `30-architecture.md` の中で圧倒的に長い「Key Patterns」(17.5 KB)を `35-key-patterns.md` として独立させた。残りの構造的な記述(Template Variables / `.chezmoiignore` / `.chezmoiexternal.toml` / Directory Layout / Pre-commit Hooks)は 3.7 KB に収まる。
- **順序**: `AGENTS.md` だけ `modules` の並びが違う。Runtime Extension を先頭に、`35-key-patterns.md` を末尾に置く。これで **切り捨ては 1 つの宣言されたモジュールの内側でだけ起きる**。実測(`codex debug prompt-input`)で、`## What This Is` / `## Common Commands` / `## chezmoi Naming Conventions` / `## Architecture` / `## Verification` / `## Known Pitfalls` / `## Agent docs` はすべて Codex に届き、落ちるのは Key Patterns の後半だけになった(この並べ替え前は Template Syntax・Script Safety・External Constraints・nono Sandbox の Known Pitfalls と `## Agent docs` がまるごと落ちていた)。
- **検査**: bats が「先頭 32,768 バイトに上記の見出しが全部ある」ことと、「`Harness sync seam`(Key Patterns の後半)は先頭 32 KiB に**無い**」ことの両方を見る。後者が Contrast Pair で、切り捨てが実際に起きていない状態なら前者は自明に成り立つだけになるため。共有モジュールが太れば前者が落ち、並べ替えを促す。
- **可視化**: Runtime Extension の冒頭で、切り捨てられるのが Key Patterns の後半であること、全文は `harness/modules/project/35-key-patterns.md` をリポジトリルートから読めばよいこと、セッション単位で上げるなら `codex -c project_doc_max_bytes=200000` であることを明記する。
- **恒久対応は先送り**: `project_doc_max_bytes` を上げるには `~/.codex/config.toml` を変更する必要があり、Codex のグローバル設定はこのリポジトリがまだ所有していない(#311 の担当)。

`.cursor/` は chezmoi から**完全に不可視**である(chezmoi は source ディレクトリ直下の `.` 始まりのエントリを、`.chezmoi*` を除いて source state に入れない)。`chezmoi managed` にも `chezmoi ignored` にも現れないことを空の source ディレクトリで確認済み。よって `.chezmoiignore` に `.cursor` を足す必要はない(足しても no-op で、読む人に「chezmoi の管理対象だが除外している」と誤解させる)。

## Content Module の分割

分割の原則は **「このリポジトリについての事実」= 共有 / 「あなた(この製品)がここでどう動くか」= Runtime Extension**。

`dot_claude/` や `~/.claude/` への言及は、それがリポジトリの中身の説明であるかぎり共有側に残す(Codex がこのリポジトリを編集するには知っている必要がある)。Claude Code の操作方法・Claude 専用のツール名・Claude の起動経路の話だけを Runtime Extension に出す。

```
harness/modules/
  project/                     # 共有(3 製品すべてに入る)
    00-overview.md             # What This Is
    10-commands.md             # Common Commands(製品非依存のものだけ)
    20-chezmoi-conventions.md  # chezmoi Naming Conventions
    30-architecture.md         # Template Variables / .chezmoiignore / .chezmoiexternal / Directory Layout / Pre-commit Hooks (3.7 KB)
    35-key-patterns.md         # Key Patterns(長い「なぜ」の散文。17.5 KB。AGENTS.md ではここが切り捨て境界になる)
    40-verification.md         # Verification
    50-pitfalls.md             # Known Pitfalls
    60-agent-docs.md           # Issue tracker / Triage labels / Domain docs
  runtime/
    claude-preamble.md         # CLAUDE.md の見出しと 1 行説明
    claude-extension.md        # Claude Code 専用(スラッシュコマンド・~/.claude/ の操作・nono ラッパー・hook・gstack /browse)
    codex-preamble.md          # AGENTS.md の見出しと 1 行説明(Codex と Cursor の両方に向けた文面)
    codex-extension.md         # Claude 専用機構が当てはまらないことの明示と代替手段
    cursor-extension.md        # .cursor/rules/dotfiles.mdc の本文(共有内容は AGENTS.md 側にあると案内する)
```

現行 `CLAUDE.md` から Runtime Extension へ移すもの:

- Common Commands の `/harness-reflect` / `/harness-review` / `bash ~/.claude/scripts/harness-doctor.sh`(Claude Code のスラッシュコマンドとその補助)
- `## gstack` 節(`/browse` skill と `mcp__claude-in-chrome__*` — Claude Code のツール名)
- Known Pitfalls の `~/.claude/rules/common/github-actions.md` への参照 → Source 側のパス `dot_claude/rules/common/github-actions.md` に書き換えて共有に残す(3 製品すべてで有効)

「Claude Code sandbox (nono)」「Notification hook ownership」「Worktree seeding hook」「Harness self-improvement loop」は **共有側に残す**。いずれも「このリポジトリが何を管理しているか」の説明であり、Codex がこのリポジトリを編集するときに必要な事実だから。「あなたは nono の中で動いている」という起動経路の話だけを Claude Runtime Extension に書く。

## `compose` adapter

契約は #309 の Runtime Adapter 契約どおり `compose.sh render <staging-file> <target-json>`。target の追加フィールド:

| フィールド | 必須 | 意味 |
|---|---|---|
| `modules` | 必須 | `--source-dir` からの相対パスの配列(空配列は失敗)。`file` adapter の `source` と同じ拒否ルール(`lib/path.bash`)を全要素に適用する。**この検査は読み込みループの前に jq でまとめて行う**: ループが行単位なので、改行を含む 1 エントリを先に弾かないと 1 宣言が複数パスへ分裂する |
| `frontmatter` | 任意 | **空でない**オブジェクト。`---` で囲んだ YAML として先頭に出す。値は文字列 / 真偽値 / 数値のみ、キーは `[A-Za-z0-9_.-]+` のみ(改行や `:` を含むキーは `---` ブロックを途中で閉じ、`alwaysApply` を本文へ落として rule を黙って非常時適用にする)。`{}` も失敗にする — frontmatter の無い `.cursor/rules` ファイルは Cursor に無視されるため |
| `banner` | 任意 | 1 行の文字列。frontmatter の直後に `<!-- ... -->` として出す。制御文字と `-->` は失敗 |

モジュールの読み込みは `content=$(cat "$path") \|\| fail ...` の形で **`cat` の終了ステータスを必ず見る**。`printf '%s\n' "$(cat ...)"` だと `cat` が失敗しても `printf` は成功するので、読めないモジュールが「空のセクション」として静かに Target へ入り、`sync` は `updated` と報告して exit 0 してしまう。

出力の順序は frontmatter → banner → `modules` の順で連結。各モジュールは末尾を改行 1 つに正規化してから空行 1 つで連結する(末尾改行の有無で見出しが繋がるのを防ぐ)。

banner は**決定論的**でなければならない — タイムスタンプ・絶対パス・ホスト名を入れると、別のマシンで `check` が必ず DRIFT になり、`just scan-sensitive` が `/Users/...` を拾う。よって banner は manifest に書いた固定文字列をそのまま出すだけにする。

## `check --no-probe`

```
harness check --manifest harness/project.json --root <repo> --no-probe
```

- Capability Probe(runtime の存在・バージョン・capability)を実行しない。
- 代わりに `SKIP runtime probe (--no-probe: 製品のロードは検証していません)` を 1 行出す(`report_skip`。失敗にも警告にも数えない)。
- summary 行にも注記を付けて `harness check: 0 failures, 0 warnings (Capability Probe 省略)` にする。`^harness check:` だけを見る呼び出し側(#324 の chezmoi 統合)が、何も検証していない実行を綺麗な合格と読み違えないため。文言は bats で固定する。
- `--runtime NAME` の妥当性検査は probe を省略しても行う(綴り違いを黙って全件扱いにしない)。
- Target の render と live 比較(drift)は通常どおり行う。
- `sync` には付けられない(sync は probe しないので意味が無い)→ 使い方エラー exit 64。

full check(probe あり)が「3 製品すべてを要求する」契約(#308)は変えない。`--no-probe` は製品が存在しない環境で *Target だけ* を検査するための明示オプションであり、「同期済み」の主張には使えないことを出力で示す。

## 検証(ネイティブな発見挙動)

AC「Each product's native discovery behavior is verified for this repository」に対する証拠。

| 製品 | 検証手段 | 実行時期 | 結果 |
|---|---|---|---|
| Claude Code | このリポジトリで起動したセッションのシステムプロンプトに `<repo>/CLAUDE.md` の内容が含まれ、`AGENTS.md` は含まれない | 手動(macOS conformance) | 2026-09-12 確認。CLAUDE.md はロードされ、AGENTS.md はロードされない |
| Codex | `codex debug prompt-input`(モデルに渡る prompt を JSON で出す。**LLM 呼び出し無し**)の出力に、cwd の `AGENTS.md` の内容と `AGENTS.md instructions for <cwd>` の行が現れる | 手動(macOS conformance) | 2026-09-12 確認。このリポジトリの生成済み `AGENTS.md` について、非 Claude 注記・切り捨て警告・共有モジュールの目印がいずれも prompt に現れ、`CLAUDE.md` 固有の見出しは現れない。**32 KiB での切り捨てもこの手段で発見した**(上記) |
| Cursor | GUI のみで自動検査できない。`.cursor/rules/*.mdc` という配置と `alwaysApply: true` の frontmatter を構造的に検証する(bats)+ 公式ドキュメントの記述 | 構造検査は CI、ロードの確認は手動 | 構造は bats で常時検査。実ロードは手動確認 |

Cursor の「実際にロードされたこと」は自動化できない。これを CI の緑で主張しないことが、[verification through the wrong resolution path](../../solutions/workflow-issues/verification-through-the-wrong-resolution-path.md) が記録している失敗を避けるための線引きである。

## テスト

`test/harness-instructions.bats`(新規)。前半は fixture、後半はこのリポジトリの実ファイルを見る。

**`compose` adapter(fixture、すべて `harness.sh` 経由)**

- `modules` の順に連結される / 末尾改行が無いモジュールでも見出しが繋がらない
- `modules` 欠落・空配列・存在しないファイルは render 失敗(live を変更しない)
- `modules` に `../` を含む値は拒否(`HARNESS_SOURCE_DIR` の外を読ませない)
- `modules` に改行を含む値は拒否(1 宣言が複数パスに分裂しない)
- 読めないモジュール(`chmod 000`)は render 失敗。live を空セクション付きで上書きしない
- `frontmatter` が `---` 囲みで先頭に出る / 真偽値がクォートされない / オブジェクト値・壊れたキー・`{}` は失敗
- `banner` が frontmatter の直後に出る
- 同じ manifest で `sync` を 2 回 → 2 回目は `0 updated`

**`--no-probe`(Contrast Pair)**

- runtime の stub を置かない状態で `--no-probe` 付き → exit 0、`FAIL runtime` 行が無い、省略の告知行がある
- 同じ状態で `--no-probe` 無し → exit 1 で `FAIL runtime` が出る

**このリポジトリの Target**

- `harness check --manifest harness/project.json --root <repo> --no-probe` が 0 failures(= commit 済み Target が Source と一致している)
- `--no-probe` の SKIP 行と summary の注記の文言が固定されている
- `harness/modules/` の全 `*.md` がどれかの Target の `modules` に入っている(参照されないモジュールは、存在するのに誰にも届かず、Source と Target は一致したままなので他では検出できない)
- `harness/project.json` の `runtimes.claude/codex/cursor` が `harness/manifest.json` の同名エントリと完全一致(手で二重管理されているのを検出する)
- `CLAUDE.md` には `/harness-reflect`・`mcp__claude-in-chrome`・`/browse` が**ある**
- `AGENTS.md` には上記が**無い**(AC「no longer describes obsolete commands, paths, or sandbox mechanisms」の機械的な確認)
- `AGENTS.md` と `CLAUDE.md` の両方に共有モジュールの目印(`chezmoi Naming Conventions`)が**ある**
- `.cursor/rules/dotfiles.mdc` が `---` で始まり `alwaysApply: true` を含み、共有モジュールの目印を**含まない**
- 3 Target すべてが banner を先頭付近に持つ

`just` レシピ: `harness-sync`(再生成)と `check-instructions`(drift、`lint` に組み込む)、`test-harness-instructions`(bats、`lint` に組み込む)。CI は `lint.yml` に既存 job と同型で 1 つ追加する。

## 後続チケットへの引き継ぎ

- **`sync` の drift 拒否と承認済み drift の state**: #322(enroll)。生成 Target を commit しているので、それまでは `git diff` と CI の `check` が実質的な拒否点になる。
- **`runtimes` の二重管理**: `harness/manifest.json` と `harness/project.json` に同じ runtime 宣言がある。bats で一致を強制しているだけで、機構としては解決していない。manifest の include / extends は #322 で Managed Project の manifest 規約を決めるときに扱う。
- **グローバル instructions**(`~/.claude/CLAUDE.md` / `~/.codex/AGENTS.md`): #311。共有モジュールをグローバルスコープにも流用するときの重複回避(#311 AC「Global and project instruction scopes compose without duplicating the same content」)は #311 の責務。
- **Managed Project の置き場の規約**: 本設計は `harness/modules/` と `harness/project.json` をこのリポジトリ固有の配置として選んだ。他リポジトリに展開するときの規約(`.harness/` 等)は #322。
- **Codex の `project_doc_max_bytes`**: 既定 32 KiB を上げるには `~/.codex/config.toml` が要る。Codex のグローバル設定を Source 化するのは #311。それまでは順序と警告文で凌ぎ、全文が必要なときは `codex -c project_doc_max_bytes=200000` を使う。指示本文を 32 KiB 未満へ分割する案(別ドキュメントへの参照化)も #311 で共有モジュールを global / project スコープに分けるときに再検討する。

## ADR

- `docs/adr/0004-cursor-project-instructions-via-agents-md.md`: Cursor の共有指示を `AGENTS.md` に相乗りさせ、`.cursor/rules/*.mdc` を Runtime Extension 専用にする決定。
