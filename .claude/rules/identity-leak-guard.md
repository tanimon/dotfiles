---
date: 2026-10-23
trigger: "ルートの CLAUDE.md / AGENTS.md のサイズ上限に余白が無く(#544)、ガードを触るときにしか要らない機構の詳細が全セッションに載っていた"
paths:
  - "scripts/scan-sensitive-info.sh"
  - "scripts/sensitive-patterns.txt"
  - "scripts/sensitive-allowlist.txt"
  - "test/scan-sensitive-info.bats"
---

**Identity leak guard(`scripts/scan-sensitive-info.sh`)** — このリポジトリは public なので、work 用 GitHub org 名とローカルアカウント名は git 管理下に置かない。ガードは 2 層で、1 層では両方の形を覆えない。

**(1) 形(shape)のパターン** — `sensitive-patterns.txt` に commit され、CI でも動く。識別子そのものを含まないので commit できる。
- `ghq/github\.com/[A-Za-z0-9._-]+` — `~/ghq/github.com/<literal>` のハードコードを検出し、`~/ghq/github.com/{{ .ghOrg }}/**`(正例は `dot_claude/settings.json.tmpl`)を強制する。
- `-Users-[A-Za-z][A-Za-z0-9.-]*--` — Claude Code のプロジェクトスラグ(`/Users/<user>/.local/share/chezmoi` → `-Users-<user>--local-share-chezmoi`。実際には `<user>` の位置に実アカウント名が入る)。`/` が消えるため既存の `/Users/...` パターンでは**構造的に捕まらない**。実際にこの形で実アカウント名が docs/ に残っていた。
- プレースホルダ(`{{ .ghOrg }}`、`<work-org>`、`-Users-<user>--`)はいずれも文字クラス外なので誤検知しない。

**(2) 識別子そのもの** — 散文中の言及(「<org> の worktree では…」)は形が無いので (1) では捕まらない。**リポジトリには書かず**、スキャン時にマシンから解決する: work org は `chezmoi data` の `.ghOrg`、アカウント名は `id -un`。それぞれ `SENSITIVE_WORK_ORG` / `SENSITIVE_LOCAL_USER` で上書き可(set-but-empty で無効化)。`id -un` が CI runner やコンテナの汎用アカウント名(`runner`/`node`/`root` 等)を返した場合は**識別子として扱わない** — これらは repo 内に普通の単語として頻出し、狩ると CI が無意味に赤くなる(実測で 14 行以上)。明示的な上書きは常に優先されるので、この除外が本当に守りたい名前を隠すことはない。マシンから引けない文字列(改名前のアカウント名や、システムが保持していない実名など)は gitignore 済みの `scripts/sensitive-patterns.local.txt` に書く — **その文字列はここに書けない**(書けば漏洩そのもの)ので、このファイルも含め commit されるファイルには具体例を残さない。**このファイルは自己ブートストラップできない**(seed のために commit したら、それがまさに防ぎたい漏洩)ので、新しいマシンでは手で作り直す。

**出力の作法。** パターンは行頭 `@redact ` で出力モードを切り替える。redact は `file:line` だけを出力する — public リポの Actions ログにマッチ行を出すと、ガードが守っている文字列をガード自身が公開してしまうため。redaction は*マッチ内容*に対するもので、commit 済みパターン自体は既に公開なので**パターン名は出す** — これが「1行に2ガードが当たった」のか「別々の2件」なのかの区別になる。形を表すパターンでも、マッチ行に識別子そのものが出るもの((1) の 2 つ)は redact にする。それ以外の形のパターンは既定の show のまま(マッチ行が見えないと修正できない)。識別子が解決できないときは黙って exit 0 せず、**どの resolver がなぜ skip されたかを名前で**出す — 静かな pass は「clean」に見えるうえ、resolver が複数ある状態で「何かが skip された」だけでは片方だけ解決した実行を誤って説明してしまう。

**強制点。** CI は (1) だけを強制する(chezmoi 設定も実ユーザー名も無い)。(2) の強制点はローカルの pre-commit フックと `just lint`。意図的に公開している情報(公開済みの commit identity・SSH 公開鍵・このリポの公開アカウント名)は `scripts/sensitive-allowlist.txt` に `<path-suffix or *>:<regex>` 形式で例外登録する。識別子そのものはこのファイルに書けない(書けば漏洩そのもの)ことが設計上の制約。
