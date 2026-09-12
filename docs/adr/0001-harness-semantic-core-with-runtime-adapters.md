---
status: accepted
date: 2026-09-11
---

# harness 設定は semantic core から Runtime Adapter で一方向に生成し、APM は選択的に採用し、Target ごとに Owner を 1 つに固定する

Claude Code / Codex / Cursor の設定(instructions・権限・hook・MCP・Skill)を手でコピーして揃えていた結果、`CLAUDE.md` と `AGENTS.md` が乖離し、Codex には削除済みスクリプトへの参照が残り、MCP は Claude だけに配布されていた(#308)。そこで dotfiles(chezmoi)が所有する製品非依存の **Harness Policy**(機械検証可能な Harness Manifest)と **Content Module**(自然言語の指示)を正本とし、製品ごとの Runtime Adapter が native な表現を **Source → Target の一方向**に生成する方式を採る。互換性の契約はバイト一致ではなく **Semantic Sync**(意図と Enforcement Grade が一致すること)で、Target は必ず **1 つの Target Owner** だけが書く。

APM(v0.30)の採用範囲は **Dependency Plane に限定**する: 外部依存の解決・MCP 配布・lock と provenance・audit、それに APM が対応できる instructions のコンパイルと、名前が衝突しない standalone Skill の配布まで。permissions・Approval Gate・Isolation Boundary・複雑な hook・namespaced な native plugin は APM に載せず、製品別の Runtime Adapter / Runtime Extension で管理する。

## Considered Options

- **文字列が同じファイルを製品間で共有する / native 設定ファイルの相互コピー / 双方向同期** — 却下。製品ごとにスキーマ・探索規則・イベントモデル・強制力(Enforcement Grade)が違うので同じ文字列でも意味が揃わず、複数の writer が同じファイルを書く事実を隠してしまう。双方向は Source を増やし、製品が持つ Runtime State(認証・キャッシュ・信頼記録)まで取り込んでしまう。
- **APM への全面移行(Skill・hook・実行ポリシーも APM で配る)** — 却下。APM は Skill を `~/.claude/skills/<name>/` にフラットに配置するため、Claude の `plugin:skill` 名前空間が消え、同名 Skill が黙って上書きされる。また APM は「何をインストールできるか」の権威にはなれるが、権限・Approval Gate・Isolation Boundary・namespaced plugin など「何を実行できるか」の権威にはならない。hook も製品ごとにイベント名・入出力・失敗時の意味が違うので、APM の hook 配布は「対応が実証済みで APM が唯一の Target Owner になる場合」だけに限る。
- **Cursor のグローバル User Rules を非公開ストレージ経由で書く** — 却下。Cursor は Managed Project 内の commit 済み project instructions でのみ Semantic Sync を保証する。

## Consequences

- Managed Project は明示登録のみ(未登録リポジトリを走査・変更しない)。生成 Target への直接編集は drift として `check` が Owner 名付きで報告し、修正は Source 側で行う。
- 「1 Target 1 Owner」を文字列一致で検査できるように、manifest の `path` は正規化せず、絶対パス・`.`/`..` セグメント・`//` を **拒否**する(`./AGENTS.md` と `AGENTS.md` の併存を許さない)。
- Project policy は global policy を足すか強めるだけで、緩める mapping は無効。Safety Invariant は同等以上の Enforcement Grade にしか写せない。
- 最初の end-to-end 経路(#309)の設計は `docs/superpowers/specs/2026-09-11-harness-sync-seam-design.md`。用語は `CONTEXT.md` の「Agent harness」節。
