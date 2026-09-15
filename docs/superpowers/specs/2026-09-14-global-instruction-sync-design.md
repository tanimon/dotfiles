# グローバル instructions を Claude Code / Codex へ同期する設計(#311)

日付: 2026-09-14
ステータス: 承認済み(#308 / #311 の Acceptance criteria と、Codex のスコープ別バイト上限の実測から蒸留)
親: [#308 feat: unify Claude Code, Codex, and Cursor harness configuration](https://github.com/tanimon/dotfiles/issues/308)
対象: [#311 feat(harness): synchronize global instructions for Claude Code and Codex](https://github.com/tanimon/dotfiles/issues/311)
前提: [#309 harness 同期・検証 seam](2026-09-11-harness-sync-seam-design.md) / [#310 このリポジトリを最初の Managed Project にする](2026-09-12-project-instruction-sync-design.md)(いずれも実装済み)

## 背景・目的

プロジェクトスコープ(#310)と違い、**グローバルスコープはまだ 1 つも Source を持っていない**。

- `~/.claude/CLAUDE.md` は chezmoi が `dot_claude/CLAUDE.md` から配置している。3 節(複数視点での意思決定 / ルール構成 / ユーザーへの確認)の日本語。
- `~/.codex/AGENTS.md` は**どこからも管理されていない**手書きファイル。同じ意図を英語で書いた 2 節に加えて、次の 2 つの誤りを含む。
  - `~/.Codex/rules/` — **存在しないディレクトリ**(実体は `~/.claude/rules/`。大文字小文字も違う)。#311 AC「Codex no longer references a nonexistent global rules location」が名指ししている当の記述。
  - `` The `ralph-wiggum` skill may appear as `ralph-loop` `` — `codex debug prompt-input` の skill 一覧に `ralph-wiggum` も `ralph-loop` も存在しない(2026-09-14 実測。`ralph` を含むのは無関係な `ecc:ralphinho-rfc-pipeline` のみ)。陳腐化した記述。
  - 「ユーザーへの確認」節が**まるごと欠落**している。
- Cursor にはグローバルな指示が無い。User Rules は非公開ストレージにしか無く、#308 が対象外と決めている。

つまり 3 製品が別々のグローバル指示で動いており、うち 1 つは存在しない場所を参照している。#311 はこれを 1 つの Source に寄せる。

## 決定事項サマリ

| 論点 | 決定 | 理由 |
|---|---|---|
| Target の書き先 | `harness sync` が `$HOME` 配下を直接書く(`--root` 既定値) | #310 設計の明示的な取り決め(「`manifest.json` の `targets[].path` は `--root`(= `$HOME`)からの相対で、#311 がグローバル Target を足す」)。#324「integrate atomic global synchronization with chezmoi apply」もこの形を前提にしている |
| `~/.claude/CLAUDE.md` の Target Owner | chezmoi(`dot_claude/CLAUDE.md`)から harness(`compose`)へ移す | #308「Every Target has exactly one Target Owner」。2 つの owner が同じファイルを書く状態は作らない |
| Cursor へのグローバルポリシー配送 | **プロジェクトの `.cursor/rules/dotfiles.mdc`** に共有 global モジュールを載せる | Cursor には書いてよいグローバル面が無い(AC「Cursor global User Rules storage is neither read nor modified」)。`.mdc` は **他のどの runtime も読まない**唯一の Target なので、ここに載せても二重ロードにならない。ADR 0005 |
| 重複回避(AC6)の形 | global モジュールは manifest.json の 2 Target と project.json の **cursor Target だけ**に入れる。project.json の `CLAUDE.md` / `AGENTS.md` には入れない | Claude はグローバル `~/.claude/CLAUDE.md` から、Codex はグローバル `~/.codex/AGENTS.md` から受け取る。プロジェクト側にも入れるとその 2 製品が同じ文を 2 回読む |
| Claude 側の文面 | 旧 `dot_claude/CLAUDE.md` の 3 節を**逐語で**共有モジュールにする | AC「Existing global Claude behavior is preserved as the regression baseline」を機械検査可能にする(下記テスト)。文面を「製品中立」に書き直すと baseline との一致が主張できなくなる |
| Claude 固有の記述の扱い | 共有モジュールに残したまま、**非 Claude 向けの訂正**を Runtime Extension で先頭に置く | `AskUserQuestion` は Claude Code のツール名、`~/.claude/rules/` は Claude Code だけが自動ロードする。#310 の `AGENTS.md`(「Notes for non-Claude agents」を先頭に置く)と同じ形にそろえる |
| Runtime Extension の共有 | `runtime/non-claude-global-extension.md` 1 つを Codex と Cursor で共有する | 訂正の内容(Claude 専用ツールが無い・rules は自動ロードされない)は両者に等しく当てはまる。ADR 0004 が `AGENTS.md` の拡張について決めたのと同じ粒度 |
| `AGENTS.md` のモジュール順 | グローバル側も Runtime Extension を**先頭**に置く | 切り捨ては起きない(下記実測)が、プロジェクト `AGENTS.md` と同じ形にそろえる。2 つの `AGENTS.md` で並びが違うと、どちらの規則だったかを毎回思い出す必要が出る |
| `~/.codex/config.toml` | **#311 では触らない** | #311 の AC はいずれも instructions の話。8.9 KB の runtime-mixed ファイルの部分所有は #312(MCP)/#315(Codex の Risk Tier)の形。`project_doc_max_bytes` の引き上げもそちらへ引き継ぐ |
| `~/.claude/rules/**` | chezmoi 所有のまま(`dot_claude/rules/common/*.md`) | AC が要求しているのは「グローバルな振る舞い」の Source 一元化であって rules ファイル群の移管ではない。参照する側(CLAUDE.md / AGENTS.md)が正しい場所を指すことが AC3 の要件 |
| グローバル drift 検査の位置づけ | `just check-global-instructions` はローカル専用(`lint` に入れない) | グローバル Target は `$HOME` にあり commit されない。CI にはそのファイルが無いので、`lint` に入れれば CI で必ず落ちる。`test-nono-profile` と同じ扱い |
| CI での検証 | fixture の `$HOME` に対して**本物の `manifest.json`** を sync/check する bats | Source が壊れていないこと・AC の不変条件は CI で検査できる。live の `$HOME` を検査しないことと、Source を検査しないことは別 |

## Codex のバイト上限はスコープごとに違う(実測)

#310 は `project_doc_max_bytes`(既定 32 KiB)でプロジェクト `AGENTS.md` が黙って切られることを発見し、グローバル側も同じかは未確認のまま #311 へ引き継いだ。**同じではない。**

codex-cli 0.147.0 / 2026-09-14、同一の 53,144 バイトのファイルを、スコープだけ変えて `codex debug prompt-input` に通した Contrast Pair:

| スコープ | 置いた場所 | 末尾マーカー(`GLOBAL_MARKER_END`) | 最後に届いた行 |
|---|---|---|---|
| グローバル | `$CODEX_HOME/AGENTS.md` | **あり** | `filler line 0899`(= 最終行) |
| プロジェクト | `<cwd>/AGENTS.md` | **なし** | `filler line 0554`(≈ 32 KiB) |

同じバイト列・同じバイナリで結果が反転するので、差の原因がスコープであることが言える。よって **`project_doc_max_bytes` はプロジェクトの `AGENTS.md` にしか効かず、`$CODEX_HOME/AGENTS.md` は上限なしで全文が渡る。**

帰結:

- グローバル `AGENTS.md` に切り捨て対策は要らない。サイズガードのテストも置かない(現時点で上限が無いことを実測しているのに、無い上限を守るテストを書くのは YAGNI)。
- 実験は `CODEX_HOME` を一時ディレクトリに向けて行い、live の `~/.codex/` は一切変更していない。
- #310 の「グローバル設定を Source 化すれば `project_doc_max_bytes` を上げられる」という引き継ぎは、**プロジェクト側の切り捨てを直すため**のものとして依然有効。ただし `config.toml` の所有は上表のとおり #311 の外。

## Target 構成

`harness/manifest.json`(`--root` = `$HOME`、`--source-dir` = リポジトリルート):

| Target | runtime | modules |
|---|---|---|
| `.claude/CLAUDE.md` | claude | `global/00` → `global/10` → `global/20` |
| `.codex/AGENTS.md` | codex | **`runtime/non-claude-global-extension`** → `global/00` → `global/10` → `global/20` |

`harness/project.json`(既存。cursor Target だけを変更):

| Target | runtime | modules |
|---|---|---|
| `.cursor/rules/dotfiles.mdc` | cursor | `runtime/cursor-extension` → **`runtime/non-claude-global-extension`** → `global/00` → `global/10` → `global/20` |

`CLAUDE.md` / `AGENTS.md`(プロジェクト)の modules は**変更しない** — グローバルモジュールを入れると Claude と Codex が同じ文を 2 回読む。

### 各 runtime が受け取る経路(重複が無いことの確認)

| runtime | グローバルポリシーの入手経路 | 重複 |
|---|---|---|
| Claude Code | `~/.claude/CLAUDE.md`(ネイティブにグローバル指示として読む) | 無し(`AGENTS.md` を読まないことは #310 で実測済み) |
| Codex | `~/.codex/AGENTS.md`(`# AGENTS.md instructions` として prompt に入ることを実測) | 無し(プロジェクト `AGENTS.md` にグローバルモジュールを入れない) |
| Cursor | プロジェクトの `.cursor/rules/dotfiles.mdc` | 無し(`.mdc` を読むのは Cursor だけ。プロジェクト `AGENTS.md` にも入れない) |

## Content Module の分割

```
harness/modules/
  global/                            # グローバル(プロジェクト横断)の共有
    00-decision-making.md            # 複数視点での意思決定(旧 dot_claude/CLAUDE.md 逐語)
    10-rule-structure.md             # ルール構成(旧 dot_claude/CLAUDE.md 逐語)
    20-user-confirmation.md          # ユーザーへの確認(旧 dot_claude/CLAUDE.md 逐語)
  runtime/
    non-claude-global-extension.md   # 新規。Codex と Cursor が共有する訂正
  project/ …                         # #310 のまま(変更なし)
```

`runtime/non-claude-global-extension.md` が担うのは次の 3 つだけ:

1. `~/.claude/rules/**` は**このディレクトリに実在する**が、自動で読み込むのは Claude Code だけであること(旧 `~/.Codex/rules/` を置き換える正しい記述 — AC3)。
2. `AskUserQuestion` は Claude Code のツールで、あなたには無いこと。代わりに選択肢を明示して尋ねること。
3. 元の `~/.codex/AGENTS.md` にあった `ralph-wiggum` / `ralph-loop` の注記は**持ち込まない**(実測で存在しない skill。#308「obsolete mechanisms and broken references are excluded」)。

## Target Owner の移管(chezmoi → harness)

1. `dot_claude/CLAUDE.md` を削除する。
2. `.chezmoiignore` に `.claude/CLAUDE.md` を追加し、harness が owner であることをコメントで書く(将来の `chezmoi add ~/.claude/CLAUDE.md` で 2 つ目の owner が生えるのを防ぐ)。同ファイル内の「`dot_claude/CLAUDE.md` … must stay deployed」というコメントも更新する。
3. `.chezmoiremove` には `.claude/CLAUDE.md` が無いことを確認済み。chezmoi は source から消えた target を既定で削除しないので、`chezmoi apply` が live のファイルを消すことはない。

`~/.codex/AGENTS.md` は元々 chezmoi の管理外なので、`.chezmoiignore` の変更は不要(chezmoi が配置しようとする source が無い)。

移管が実際に効いていることは推論ではなく実測で確かめた(`chezmoi-patterns.md`「Always verify with `chezmoi managed | grep <pattern>`」。この worktree からは `--source "$(pwd)"` が必須):

| 確認 | コマンド | 結果 |
|---|---|---|
| chezmoi が管理していない | `chezmoi managed --source "$(pwd)" \| grep -x '\.claude/CLAUDE\.md'` | 出力なし |
| `apply` が live を消さない | `chezmoi diff --source "$(pwd)" \| grep 'claude/CLAUDE.md'` | 該当 hunk なし |
| 将来の `chezmoi add` を弾く | `chezmoi add --dry-run --source "$(pwd)" ~/.claude/CLAUDE.md` | `chezmoi: warning: ignoring .claude/CLAUDE.md` |

なお `chezmoi ignored` にはこのパスが**現れない** — source が存在しないエントリは列挙されないため。`.chezmoiignore` の行が効いていることは上の `add --dry-run` でしか見えないので、`ignored` の出力を根拠にしないこと。

### #324 までの空白(既知・意図的)

`chezmoi apply` はもう `~/.claude/CLAUDE.md` を作らない。**新しいマシンでは `just harness-sync-global` を 1 度実行するまでグローバル指示が存在しない。** これを `chezmoi apply` に統合して fatal にするのが #324 の担当であり、#311 では埋めない(tracer-bullet の分割どおり)。

ただし**空白の解消を #324 へ送ることと、空白の検出まで送ることは別**である。当初は `50-pitfalls.md`(= 生成される `CLAUDE.md` / `AGENTS.md`)に書けば「エージェント自身が気づける場所」だとしていたが、この根拠は成立していない — そのテキストが届くのは**このリポジトリで作業しているとき**だけで、グローバル指示を欠いたエージェントは定義上どこか別のリポジトリにいる。「silence itself signals a dead hook」というこのリポジトリ自身のルールに照らすと、静かに欠けたままになる。

そこで**検出だけは #311 に入れる**: `dot_claude/scripts/executable_harness-briefing.sh`(`SessionStart` のグローバルフック)が 2 つの Target の実在を確認し、欠けているものを名指しして `just harness-sync-global` を促す。これはリポジトリに依らず毎セッション動く唯一の経路である。回帰テストは `test/harness-briefing.bats` の 3 件(各 Target の不在 + 両方在るときに警告しない Contrast Pair)。`50-pitfalls.md` の記述もこの経路に触れるよう更新した。

### worktree からグローバル sync を実行するときの注意

`just harness-sync-global` は **cwd の worktree の `harness/modules/`** を Source にして live の `$HOME` を書き換える。「`chezmoi apply` は main から配置される」という既存の落とし穴の裏返しで、こちらは**未マージのブランチの内容が即座に live に入る**。手元で検証するときは 1 回だけ実行し、baseline スナップショットと diff を取り、確認後は main の内容へ戻せるようにしておく。

## テスト

`test/harness-global-instructions.bats`(新規)。`HOME` と `--root` は `$BATS_TEST_TMPDIR` 配下に向け、**live の `$HOME` には一切触らない**。manifest は本物の `harness/manifest.json` を使う(Source の検査であって live の検査ではない)。

**レンダリングと冪等性**

- 本物の `manifest.json` を fixture root に sync → `2 updated`、2 回目は `0 updated`。
- sync 後の `check --no-probe` が 0 failures。

**AC2(Claude のグローバル挙動の保全)**

- `test/fixtures/global-claude-baseline.md` に旧 `dot_claude/CLAUDE.md` を凍結して置く。
- レンダリングされた `.claude/CLAUDE.md` に、baseline の**全非空行が逐語で**含まれることを 1 行ずつ検査する。文面を書き換えれば必ず落ちる。

**AC3(Codex の陳腐化した参照の排除)**

- `.codex/AGENTS.md` に `.Codex/rules` が**無い**。
- `ralph-wiggum` / `ralph-loop` が**無い**。
- `~/.claude/rules/` への参照が**ある**(消えただけで置き換えられていない状態を捕まえる)。

**AC6(スコープ間の重複回避)** — 両方向を見る

- `manifest.json` のどの Target にも `harness/modules/project/` のモジュールが入っていない。
- `project.json` の `CLAUDE.md` / `AGENTS.md` Target に `harness/modules/global/` のモジュールが入っていない。
- `project.json` の `.cursor/rules/dotfiles.mdc` には入っている(**Contrast Pair**: 上の 2 つは「global モジュールがどこにも無い」でも成立してしまうので、実際に配送されている経路が 1 つあることを対で示す)。
- 生成済みのプロジェクト `CLAUDE.md` / `AGENTS.md` に global モジュールの目印が**無い**(宣言だけでなく成果物でも確認する)。

**モジュール網羅(#310 のテストの拡張)**

- `harness/modules/` の全 `*.md` が `manifest.json` ∪ `project.json` のどれかの Target から参照されている。#310 の同名テストは `project.json` しか見ていないので、そのまま `harness/modules/global/` を足すと落ちる。**両 manifest の和**に広げる。

**Cursor の構造(#310 のテストの更新)**

- `.cursor/rules/dotfiles.mdc` は引き続き `---` 始まり・`alwaysApply: true`。
- #310 の「Cursor の rule は共有モジュールを重複して持たない」は *project* 共有モジュール(`chezmoi Naming Conventions`)についての検査であり、そのまま有効。global モジュールを載せることとは矛盾しない — 二重ロードの判定基準は「同じ内容が同じ runtime に 2 経路で届くか」であって「`.mdc` が薄いか」ではない。テストのコメントにこの区別を書く。

## 検証(ネイティブな発見挙動)

| 製品 | 検証手段 | 実行時期 | 結果 |
|---|---|---|---|
| Codex(グローバル) | `codex debug prompt-input` の出力に `# AGENTS.md instructions` と `~/.codex/AGENTS.md` の内容が現れる。プロジェクト外の空ディレクトリで実行して、プロジェクト doc と混ざらないことを保証する | 手動(macOS conformance) | 2026-09-14 確認。空の一時ディレクトリでもグローバル AGENTS.md が `<INSTRUCTIONS>` として prompt に入る |
| Codex(バイト上限) | 同一ファイルをグローバル / プロジェクトに置き分けて末尾マーカーの有無を見る Contrast Pair | 手動(macOS conformance) | 2026-09-14 確認。上表のとおりグローバルは無制限 |
| Claude Code | このリポジトリ外で起動したセッションのシステムプロンプトに `~/.claude/CLAUDE.md` の 3 節が現れる | 手動(macOS conformance) | sync 実行後に確認する |
| Cursor | GUI のみで自動検査できない。`.mdc` の構造(`alwaysApply: true`)と global モジュールの同梱を bats で構造検査する | 構造検査は CI、ロードの確認は手動 | #310 と同じ線引き |

Cursor が実際にグローバルポリシーをロードしたことは自動化できない。CI の緑でそれを主張しないのが [verification through the wrong resolution path](../../solutions/workflow-issues/verification-through-the-wrong-resolution-path.md) の予防線である。

## 後続チケットへの引き継ぎ

- **`chezmoi apply` からのグローバル sync**: #324。`~/.claude/CLAUDE.md` が新マシンで作られない空白は、それまで `just harness-sync-global` の手実行で埋める。
- **`~/.codex/config.toml` の所有**: #312(MCP の 3 target 配布)/ #315(Codex の Risk Tier)。#310 はこれを「#311 の担当」として引き継いだが、**#311 の 6 つの AC はいずれも instructions の話で config.toml を要求していない**ため、意図的にここでは扱わない。`project_doc_max_bytes` の引き上げ(= #310 のプロジェクト `AGENTS.md` 切り捨ての恒久対応)はそちらに乗る。**グローバル側には上限が無いことが実測で分かったので、急ぐ理由は #310 のプロジェクト Target だけ**である。
- **プロジェクト `AGENTS.md` の 32 KiB ヘッドルーム**: #311 のリップル編集で `### Key Patterns` の位置が 30,011 → 30,472 バイトへ動き、**残り 2,296 バイト**になった。#310 が「並べ替えの余地は使い切っている」と記録したとおり、次に共有モジュールが太ると `test/harness-instructions.bats` が落ちる。#310 が #311 へ引き継いだ「指示本文を 32 KiB 未満へ分割する案」は、global / project のスコープ分割では解消しない(グローバルモジュールはプロジェクト `AGENTS.md` に入らないので、そもそもヘッドルームを使っていない)。残る手は #310 の記述どおりモジュールの分割・散文の圧縮・`docs/` への外出しで、`config.toml` を所有するチケットが `project_doc_max_bytes` を上げればまとめて解決する。
- **他の Managed Project への Cursor グローバル配送**: `lib/path.bash` は絶対パスと `../` を拒否するので、別リポジトリの `project.json` からこのリポジトリの `harness/modules/global/` は参照できない。第 2 の source root を許すか、モジュールを vendoring するかは #322(enroll)で決める。**#311 が保証しているのはこのリポジトリの Cursor だけ**。
- **`~/.claude/rules/**` の Source 化**: 未着手。`~/.claude/rules/` には chezmoi 管理外のドメイン別ディレクトリ(`golang/` `typescript/` `web/`)と、仕事リポジトリへの symlink がある。グローバル rules 群をどこまで Source 化するかは #321(self-improvement lifecycle)で改めて扱う。

## ADR

- `docs/adr/0005-global-policy-reaches-cursor-via-project-rules.md`: Cursor にはグローバル面が無いため、グローバルポリシーを Managed Project の `.cursor/rules/*.mdc` から配送する決定(ADR 0004 の「`.mdc` は Cursor 固有の Runtime Extension 専用」を、スコープを限って改める)。

## 付録: 移管前の `~/.codex/AGENTS.md`(全文・570 バイト)

Claude 側の旧 `dot_claude/CLAUDE.md` は `test/fixtures/global-claude-baseline.md` に凍結され、AC2 の逐語テストが守っている。Codex 側の旧ファイルは**どのリポジトリにも存在しない手書きファイル**で、初回の `just harness-sync-global` が上書きすると唯一のコピーが消える。内容を捨てる判断は上記「Content Module の分割」のとおりだが、**捨てたものに価値が無かったことを後から検証できる状態**にしておくためここに全文を残す。

fixture にはしない — これは baseline ではなく破棄記録であり、テストがこの文面に依存すると「捨てた記述」を将来の Target が満たすべき契約に格上げしてしまう(現に `~/.Codex/rules/` と `ralph-wiggum` は AC3 が**不在**を要求している文字列である)。

```markdown
# Multi-Perspective Decision Making

- Treat user opinions as one perspective among many — consider other viewpoints and sources
- Push back and suggest alternatives when warranted, rather than defaulting to agreement

# Rule Structure

Detailed coding rules, test policies, and security guidelines live in `~/.Codex/rules/`, organized by domain (`web/`) and shared (`common/`). This file contains only cross-project behavioral guidelines.

# Compound Engineering Plugin Notes

The `ralph-wiggum` skill may appear as `ralph-loop`. Launch via `/ralph-loop:ralph-loop`.
```

移管後の Target との対応:

| 旧の節 | 移管後 |
|---|---|
| Multi-Perspective Decision Making | `global/00-decision-making.md`(日本語の原文へ回帰) |
| Rule Structure | `global/10-rule-structure.md` + `runtime/non-claude-global-extension.md` の訂正(`~/.Codex/rules/` → `~/.claude/rules/`、自動ロードは Claude Code だけ) |
| Compound Engineering Plugin Notes | **持ち込まない**(実測で不在の skill。#308「obsolete mechanisms and broken references are excluded」) |
| (欠落していた「ユーザーへの確認」) | `global/20-user-confirmation.md` + Runtime Extension の `AskUserQuestion` 訂正 |
