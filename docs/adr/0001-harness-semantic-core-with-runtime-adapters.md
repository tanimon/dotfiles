---
status: accepted
date: 2026-09-11
---

# harness 設定は semantic core から Runtime Adapter で一方向に生成し、Target ごとに Owner を 1 つに固定する

Claude Code / Codex / Cursor の設定(instructions・権限・hook・MCP・Skill)を手でコピーして揃えていた結果、`CLAUDE.md` と `AGENTS.md` が乖離し、Codex には削除済みスクリプトへの参照が残り、MCP は Claude だけに配布されていた(#308)。そこで dotfiles を唯一の Source とし、機械検証可能な Harness Manifest と自然言語の Content Module から、製品ごとの Runtime Adapter が native な表現を **Source → Target の一方向**に生成する方式を採る。互換性の契約はバイト一致ではなく **Semantic Sync**(意図と Enforcement Grade が一致すること)で、Target は必ず **1 つの Target Owner** だけが書く。

## Considered Options

- **native 設定ファイルの相互コピー / 双方向同期** — 却下。製品ごとにスキーマ・探索規則・イベントモデル・強制力が違うのでコピーでは意味が揃わず、双方向は Source を増やして製品が持つ Runtime State(認証・キャッシュ・信頼記録)まで取り込んでしまう。
- **APM(Dependency Plane)に実行ポリシーも任せる** — 却下。APM v0.30 は依存解決・MCP 配布・lock・audit には向くが、権限・Approval Gate・Isolation Boundary・namespaced plugin の権威にはならない。APM は「何をインストールできるか」だけを持ち、「何を実行できるか」は Runtime Adapter / Runtime Extension に残す。
- **Cursor のグローバル User Rules を非公開ストレージ経由で書く** — 却下。Cursor は Managed Project 内の commit 済み project instructions でのみ Semantic Sync を保証する。

## Consequences

- Managed Project は明示登録のみ(未登録リポジトリを走査・変更しない)。生成 Target への直接編集は drift として `check` が Owner 名付きで報告し、修正は Source 側で行う。
- 「1 Target 1 Owner」を文字列一致で検査できるように、manifest の `path` は正規化せず、絶対パス・`.`/`..` セグメント・`//` を **拒否**する(`./AGENTS.md` と `AGENTS.md` の併存を許さない)。
- Project policy は global policy を足すか強めるだけで、緩める mapping は無効。Safety Invariant は同等以上の Enforcement Grade にしか写せない。
- 最初の end-to-end 経路(#309)の設計は `docs/superpowers/specs/2026-09-11-harness-sync-seam-design.md`。用語は `CONTEXT.md` の「Harness sync」節。
