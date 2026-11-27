# ルールと強制の対応表

繰り返された誤りのうち、仕組みが止めるもの。ここに載るルールは文書で守らせない — 違反すれば右列が落とす
(または、誤りそのものが起こらなくなる)。

訂正を受けたら、次の順で直す: 誤りが起こらない構造にする → lint / テストで落とす → それも無理な判断だけを
`CLAUDE.md` の Known Pitfalls や `.claude/rules/` に書く。仕組みを作ったらこの表に 1 行足す。表に載ったルールを
守らせるための注意書き(Known Pitfalls の項目など)が指示ファイルに残っていたら消す(強制されているものを文書で
二重に持たない)。仕組みそのものの説明や、症状が出たときの確かめ方として触れる記述は残してよい。ルールの文章が既にあるのに
同じ誤りが繰り返されたら、それは文書では止まらないという証拠なので、同じ変更で仕組みに上げる。

| ルール | 強制する仕組み |
|---|---|
| Markdown の相対リンクは git 管理下のパスを指す(`harness/modules/` の下と `/` 始まりはルートから、他はファイルから解決する。ルート合成のモジュールから nested `CLAUDE.md` へ段落を移すとリンクの解決元が変わる) | `just check-md-links` |
| 生成物の `CLAUDE.md` / `AGENTS.md` / `.cursor/rules/*.mdc` を手で直さない(`harness/modules/` を直して `just harness-sync`) | `just check-instructions` |
| 指示ファイルとルールはサイズの上限を超えない | `just check-instruction-size`(上限は `scripts/instruction-size-limits.txt`) |
| ADR の番号を重複させない | `just check-adr-numbers` |
| ループの PR は Guarded Path を変えない | `just check-guarded-paths` |
| 新しい suite は `lint:` と `.github/workflows/lint.yml` の両方に足す | `just test-ci-parity` |
| work 用 org 名とローカルアカウント名を書かない | `just scan-sensitive` |
| Claude Code の Bash ツールで、bash の書き方(`G="git -c x"; $G add`・クォートしない glob や `?` を含む URL・`=` で始まる語・`$VAR:h`)が zsh に化けない | `dot_config/zsh/claude-code.zsh` の option(`test/claude-code-zsh.bats`) |
| `git push` の破壊的な綴り(force / delete / `+refspec` など)を通さない | `PreToolUse` の `executable_git-push-guard.sh`(`test/git-push-guard.bats`) |
| orca や `/config` が live の `~/.claude/settings.json` に書いた変更は、`chezmoi apply` で消える前に `dot_claude/settings.json.tmpl` に取り込む | SessionStart の briefing(`executable_harness-briefing.sh`)が、描画した source と live の食い違いを ATTENTION で出し続ける(`test/harness-briefing.bats`) |
| 指示ファイル(CLAUDE.md・ルール・SKILL.md・Content Module)に経緯(「初版は」「以前は」、出来事の日付、「#N で実装」)を書かない。コードコメント(`#` と `//` の行。`{{/* */}}` は対象外)にも、日付を除く同じ経緯を書かない | `just check-comment-noise`(範囲は `scripts/instruction-pathspecs.bash`) |
