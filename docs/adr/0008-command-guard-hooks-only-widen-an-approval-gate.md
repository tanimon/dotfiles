---
status: deprecated
date: 2026-09-30
---

# コマンドを判定するフックは Widening Hook に揃え、git push も Approval Gate を土台に戻す

> **却下(2026-09-30)。前提が現行版で成り立たない。** Claude Code 2.1.285 では、PreToolUse フックが `permissionDecision: "allow"` を返しても、同じ呼び出しに一致する `permissions.ask` ルールが勝つ。contrast pair で実測した(`claude -p --settings`、sandbox 無効、`< /dev/null`。フックは marker ファイルで呼ばれたことを記録): `ask: Bash(git push:*)` と `ask: Bash(curl:*)` のどちらでも、常に allow を返すフックが走ったうえでブロックされた。2026-09-17 と同じ組み方(ask のみ、`allow: Bash` なし)でもブロックされたので、原因は版の変化である。フックの `deny` と `ask` は今も効く(常に deny / ask を返すフックでブロックされた)。公式ドキュメントは今も「allow なら ask は評価されない」と書いているので、ドキュメントを根拠にしないこと。代わりの決定は ADR 0009。以下は却下された当時の本文。

git push の判定フック(`executable_git-push-guard.sh`)を、curl のフック(`executable_curl-localhost-guard.sh`)と同じ Widening Hook の向きに揃える。`Bash(git push:*)` を `permissions.ask` に戻し、フックは「remote 名と保護 branch 以外の送り先を明示した push」だけを `allow` にする。破壊的な綴りの `deny` は今までどおり独立に判定する。2026-09-16 の決定(`docs/superpowers/specs/2026-07-25-permission-tier-model-design.md` の addendum。ask を外し、素の push を auto mode の classifier に任せる)は、フックが不在・故障・判定不能のときに無出力になり、それが静かなフェイルオープンになる形だった。揃えるとこれがすべて承認プロンプトに倒れ、フックの死も毎回の push で目に見える。2 つのフックの失敗の向きが同じになるので、コマンド文字列を読む処理を 1 つの module にまとめられる(「読めなければ無出力」が両方で正しくなる)。

## Considered Options

- **現状維持(git push は ask を外し、フックが塞ぐ向き)** — 却下。フックの未配置・クラッシュ・jq の不在・共有ライブラリの読み込み失敗がどれもフェイルオープンになり、エラーログと backstop の `deny` 行で補うしかない。reader を共有しても、git push 側だけ fail-closed の分岐を手で書き続けることになる。
- **揃えたうえで、素の push を全部 `allow` にする** — 却下。フックの `allow` は classifier の判断(main への直接 push や想定外の remote への push を止めるなど)を経ずに通してしまう。送り先を字面から決められる形だけを `allow` にし、決められない形(`HEAD`、refspec の省略)はプロンプトに残す。判定を決定的な shell に置くのはこのリポジトリの方針とも合う。
- **curl のフックを git push の向きに揃える** — 却下。curl は ask を外すとダウンロードや `| sh` が classifier 任せになり、緩める側のフックの失敗がフェイルオープンになる。

## Consequences

- **素の `git push` と `git push -u origin HEAD` は毎回プロンプトになる。** 送り先の branch がコマンドの字面から分からないため。外部の plugin skill(commit-commands、compound-engineering)の手順は `git push -u origin HEAD` と書いているので、それに従った push もプロンプトになる。プロンプトに答えられない Workflow(`deliver` の publish)には、branch 名を明示した形で push させる(注記: Publish は [ADR 0015](0015-deliver-does-not-publish.md) で取り除かれ、`deliver` は push しなくなった)。摩擦が目立つようなら、hook 入力の `cwd` から現在の branch を引く案を別の変更で検討する。
- **保護 branch の一覧(`main` / `master` / `develop` / `development`)は固定で持つ。** このフックはグローバルに効き、仕事用リポジトリにも当たる。リポジトリごとの既定 branch は引かない(cwd のずれ、git の呼び出しによる遅延と失敗経路を避けるため)。
- **ask の土台は包まれた形も捕まえるとみられる**(2026-09-30、`claude -p --setting-sources project` で、ask なしの control と `Bash(git push:*)` を ask に置いた treatment を比較。push 先はローカルの bare repo)。`echo "$(git push …)"`・`` echo `git push …` ``・`for … do git push …; done`・`if …; then git push …; fi` の 4 形は、control では実行され、treatment ではブロックされた。捕まえないのは `bash -c "git push …"` だけで、これは現行のフックでも対応していない既知の残存リスク。ただしこの測定では、モデルが実際に打ったコマンドを記録していない。実装計画の Task 0 で、打ったコマンドが指示どおりであることを確かめてから「実測済み」とする。
- **素の `git push` をプロンプトにしても摩擦は小さい。** 過去のセッション記録にある `git push` 123 件のうち、素の push は 21 件(17%)、送り先が `HEAD` だけのものは 1 件だった。一方 115 件が `2>&1` 付き、107 件がパイプ付き(`tail` 101・`grep` 6・`head` 4)だったので、fd の複製と読み取り専用のパイプ先は `allow` の対象に含める。
- **そのため、コマンド文字列を読む共有の module は、置換・変数・展開を見つけても flag を立てるだけで、中身までは読まない。** 引用符の内側の置換(`echo "$(git push … --force)"`)や heredoc の本文にある `git push … --force` は、フックから見て無出力になる。これらの形が `deny` から ask のプロンプトに下がることは受け入れる。代わりに、PR 本文などの散文に書いた `git push --force` を誤検出しなくなる。
- **フックの `allow` が git push の ask に勝つこと**は、curl のフックでは実測済みである(2026-09-17)。git push でも同じ contrast pair で確かめてから `accepted` にする。
