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
- Claude 専用のツール名(`AskUserQuestion`)は Claude 用前置きに移し、共有本文には「選択肢を求めるときは番号付きの選択肢で提示する」という製品非依存の意図だけを残す。Runtime Extension は「その製品にしかない機能」に限るという ADR 0004 の線引きを共有本文にも適用する。
- 根拠を失った #313〜#321 / #323〜#325 は決定コメント付きで close する。再開条件は「その製品が日常利用されている事実」で、その時点で permissions の翻訳器(rulesync か自前か)を改めて判断する。#308 本体は縮小版に書き換えて番号を維持する。
- CONTEXT.md から Safety Invariant / Enforcement Grade / Portable Hook / Credential Reference を削除した。Capability Probe と Atomic Sync は `harness check` / `harness sync` に実装が現存するため残す。`harness/manifest.json` の runtime probe(claude / codex / cursor / apm)も据え置く。
- ADR 0001 のうち「Enforcement Grade の同等以上写像」「tighten-only」「Portable Hook」は本 ADR により保留になる。0001 の他の決定(一方向生成・単一 Target Owner・APM は Dependency Plane 限定・Cursor 非公開ストレージを書かない)は有効。
