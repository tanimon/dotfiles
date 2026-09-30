---
status: accepted
date: 2026-09-30
---

# コマンドを判定するフックは ask ルールに頼らず、allow を使わずに deny / ask / 無出力で判定する

git push のフック(`executable_git-push-guard.sh`)と curl のフック(`executable_curl-localhost-guard.sh`)は、どちらも `permissions.ask` に対応するルールを置かない。フックは `deny` / `ask` / 無出力だけを返し、`allow` は返さない。無出力のコマンドは auto mode の classifier が判定する。curl は `Bash(curl:*)` を ask から外し、宛先がループバックだけだと示せない curl と読み切れない curl にフックが `ask` を返す。git push は 2026-09-16 からの形(ask を外し、破壊的な綴りに `deny`、読み切れない形に `ask`)のままにする。こうする理由は、Claude Code 2.1.285 では、ask のルールに一致する呼び出しに対してフックの `allow` が効かないためである(ADR 0008 の実測)。一方、フックの `deny` と `ask` は今も効く(2026-09-30 に `defaultMode: default` と `--permission-mode auto` の両方で実測)。2 つのフックの失敗の向きがそろうので、コマンド文字列を読む処理を 1 つの module(shell command reader)にまとめ、「読めなければ各 policy が `ask`」という同じ約束で使える。

## Considered Options

- **ask を土台に、フックが `allow` で緩める(ADR 0008)** — 却下。現行版では `allow` が ask に負ける。
- **向きはそのままで、git-push-guard だけを共有 reader に載せる** — 却下。curl のフックは今の向きでは何も緩められず(localhost への curl も毎回プロンプトになる)、2 つのフックが別々の失敗の向きを持ち続ける。
- **refactor を見送り、git-push-guard の誤 deny だけを直す** — 却下。2 つの tokenizer の重複と、git-push 側が引用符を読めない問題が残る。

## Consequences

- **フックが死ぬと curl も classifier だけになる。** 未配置・クラッシュ・jq の不在・reader の読み込み失敗のとき、curl は git push と同じく classifier の判定に落ちる。prefix で書ける deny では `| sh` のような形を表現できないので、curl には deny の床を置かない。git push の先頭フラグ形の deny 3 行は残す。
- **引用符の中の置換に埋まった危険な push は、字面で `ask` にする。** reader は `$(…)` の中を再帰的に読まない。`$` かバッククォートを含む token と、閉じていない引用符の token について、その中に `git`・`push`・危険な綴りがそろっていれば `ask` にする。PR 本文の heredoc に書いた `git push --force` が `ask` になる挙動は、今までと同じ。
- **8192 byte を超えるコマンドには何も返さない。** reader が token を返さないので、classifier に任せる。長いコマンドの途中に埋まった本物の force push を守るのは、先頭フラグ形の deny 3 行だけになる。これは残存リスクとして受け入れる。
- **`bash -c "curl …"` と `bash -c "git push …"` はフックから見えない。** 引用符の中は 1 つの token になるので、curl や git の token として数えない。どちらも classifier の判定だけになる。ask ルールも `bash -c` の中は捕まえない(ADR 0008 の実測)ので、ask を外したことで弱くなるわけではない。
- **ループバック宛の curl は、フックの `allow` ではなく classifier が通す。** フックは何も返さない。classifier がプロンプトを出す場合は、フックでは緩められない。
