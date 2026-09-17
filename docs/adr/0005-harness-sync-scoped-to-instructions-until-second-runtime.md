---
status: accepted
date: 2026-09-16
---

# 第 2 のエージェント製品が日常利用されるまで、harness 同期の範囲は指示文(Content Module)に限定し、permissions / hooks は製品ネイティブのまま chezmoi が所有する

#308 は Claude Code / Codex / Cursor の permissions・hook・MCP・Skill まで含む 3 製品 Semantic Sync を掲げ、ADR 0001 でその骨格(semantic core + Runtime Adapter + Enforcement Grade)を決めた。しかし実態は Claude Code が主で Codex / Cursor はほとんど使われておらず、50 user story と未着手 13 チケットの重さは「翻訳器のない製品向けに翻訳規則を先回りで設計している」ことから来ていた。そこで範囲を **指示文の共有** に縮める: Codex / Cursor に保証するのは「Claude と同じ Content Module を読むこと」だけで、permissions / hooks / sandbox は各製品ネイティブの設定のまま、`~/.claude/settings.json` は従来どおり chezmoi の `settings.json.tmpl` が唯一の Target Owner として所有する。tighten-only・Enforcement Grade の同等以上写像・Portable Hook は要件から外し、単一 Target Owner だけを不変条件として残す。グローバル指示の合成は chezmoi テンプレート(`.chezmoitemplates/` + `{{ include }}`)で行い、`harness/` の compose adapter は Managed Project(リポジトリ内)専用に据え置く。APM は MCP のみの Dependency Plane を維持する(2026-08-10 の Skill 配布撤回を再開しない)。

## Considered Options

- **rulesync(dyoshikawa/rulesync)に置き換えて `harness/` を削除する** — 却下。一次ソース調査(`docs/research/2026-09-16-rulesync-vs-harness-308.md`)で、#308 の 15 チケットのうち 7 件(#312 #318 #319 #321 #323 #324、実質 #316)が rulesync では実現不能で、不能な理由が Atomic Sync や Enforcement Grade といった「harness/ を重くしている要件そのもの」だった。つまり rulesync は既に動いている 300 行(#309 / #310)の代替にはなるが、重さの正体である未着手チケットは 1 つも消さない。加えて `~/.claude/settings.json` に対しては (1) `statusLine` 等を書かない設計のため唯一の writer になれず、chezmoi との 2 writer(apply で消え generate で戻る drift ループ)になる、(2) permissions 内の `{{ .ghOrg }}` は public リポジトリの Identity leak guard 上 rulesync の静的 JSONC に置けない、(3) 翻訳先の Cursor は `ask` を捨て Codex は filesystem の `ask` を deny に潰すため、Risk Tier の `ask` 層は将来も写らない。なお「Source にコメントが残らない」は rulesync 除外の理由に **ならない**(Source は JSONC)。
- **#308 の全範囲を自前で続行する** — 却下。使っていない製品のために Enforcement Grade 比較・Contrast Pair・Atomic Sync の apply 統合を作るのは、検証相手が存在しない投資になる。
- **グローバル指示も `harness/manifest.json` の Target にして `run_onchange_` から `harness sync` を呼ぶ(#311 / #324 原案)** — 却下。`~/.claude/CLAUDE.md` の Target Owner を chezmoi から harness に移す必要があり、apply との統合という新しい可動部が増える。chezmoi は既に `~/` の Owner で、`{{ template }}` / `{{ include }}` による合成は `gitignore-common` で実績がある。

## Consequences

- `~/.codex/AGENTS.md` は chezmoi が `dot_codex/AGENTS.md.tmpl` から生成する: Codex 用前置き(Runtime Extension)→ 共有本文(`.chezmoitemplates/`)→ `dot_claude/rules/common/*.md` の連結(合計約 10 KB、Codex の 32 KiB 切り捨てに余裕あり)。`dot_claude/rules/common/` は名前に製品名を含むが Source として据え置き、Codex 側は `include` で直接読む。`~/.claude/rules/` 配下に symlink で差し込まれる仕事用ルール はマシン固有なので含めない。Cursor はグローバル rules を持たないため対象外(ADR 0004)。
- Claude 専用のツール名(`AskUserQuestion`)は Claude 側の Runtime Extension に移し、共有本文には「選択肢を求めるときは番号付きの選択肢で提示する」という製品非依存の意図だけを残す。Runtime Extension は「その製品にしかない機能」に限るという ADR 0004 の線引きを共有本文にも適用する。実装では Claude 側の Runtime Extension は**前置きではなく末尾セクション**になった(下の「実装時の補正」を参照)。
- 根拠を失った #313〜#321 / #323〜#325 は決定コメント付きで close する。再開条件は「その製品が日常利用されている事実」で、その時点で permissions の翻訳器(rulesync か自前か)を改めて判断する。#308 本体は縮小版に書き換えて番号を維持する。
- CONTEXT.md から Safety Invariant / Enforcement Grade / Portable Hook / Credential Reference を削除した。Capability Probe と Atomic Sync は `harness check` / `harness sync` に実装が現存するため残す。`harness/manifest.json` の runtime probe(claude / codex / cursor / apm)も据え置く。
- ADR 0001 のうち「Enforcement Grade の同等以上写像」「tighten-only」「Portable Hook」は本 ADR により保留になる。0001 の他の決定(一方向生成・単一 Target Owner・APM は Dependency Plane 限定・Cursor 非公開ストレージを書かない)は有効。

## 実装時の補正(2026-09-17, #311)

#311 の実装で、本 ADR と issue の受け入れ条件の文言どおりには作れない箇所が 2 つ見つかった。どちらも意図的な逸脱として承認済み。

**1. 共有本文が 1 箇所であることと「`~/.claude/CLAUDE.md` のレンダリング結果が言い換え以外変わらないこと」は両立しない。** 変更前の `~/.claude/CLAUDE.md` の並びは `複数視点での意思決定` → `ルール構成` → `ユーザーへの確認` で、真ん中の `ルール構成` は `~/.claude/rules/` とドメイン別ディレクトリを指すため **Claude 固有**(Codex では rules を本文に連結するので成り立たない)。共有本文は `{{ template }}` で取り込む 1 つの連続ブロックなので、その内側に Claude 固有の節を差し挟むことはできない。共有本文が 1 箇所であること(#311 の AC1、本 ADR の骨子)を優先し、並びは次のようになった:

```
# 複数視点での意思決定          ← 共有本文(変更なし)
# ユーザーへの確認              ← 共有本文(番号付き選択肢に言い換え。元は末尾にあった)
# ルール構成                    ← Claude 固有(バイト単位で変更なし)
# ユーザーへの確認に使うツール   ← Claude 固有(AskUserQuestion)
```

つまり実際の差分は「言い換え」に加えて **`ユーザーへの確認` の位置が上がったこと** を含む。文面は `複数視点での意思決定` と `ルール構成` の 2 節が 1 字も変わっていない。

**2. Claude 側の Runtime Extension は「前置き」ではなく末尾セクションに置いた。** 上の並びの帰結であり、生成される `CLAUDE.md` が `## Claude Code specifics` を末尾に置く既存の慣行(ADR 0004 / #310)とも揃う。Codex 側だけは前置き(ファイル冒頭)のままで、そちらは後続に rules 群が連結されるため先頭に置く必要がある。

この並びは `test/global-instructions.bats` が **レンダリング結果の全文** で固定している。当初は「変更前の各行が出力に含まれる」検査だったが、それは節の並べ替えにも節の追加にも反応せず、ここで実際に起きた逸脱をちょうど素通りするため(`docs/solutions/workflow-issues/verification-through-the-wrong-resolution-path.md` と同じ形)、全文一致に置き換えた。今後この並びを変えるときは、テストの期待値を変える = 意図的な変更であることが diff に残る。
