---
status: accepted
date: 2026-10-31
---

# Risk Tier の届く範囲は作成先リポジトリの owner で評価し、作成先を自分で検査する create-issue.sh だけを確認なしにする

Risk Tier(`docs/superpowers/specs/2026-07-25-permission-tier-model-design.md`)は `gh issue create` を Tier 2 として ask に置いている。理由は、新しい作業項目を他人の視界に入れ、CI を起動するためである。しかし許可リストの個人 owner(`dot_claude/scripts/lib/issue-linkage-scope.bash`)のリポジトリでは、issue を受け取る「他人」がいない。issue-linkage スキルが issue を作るたびに出る確認は、守る相手のいない Approval Gate になっていた。そこで Tier の判定を次の 2 段に改める。

1. **原則**:届く範囲は、作成先リポジトリの owner を基準に評価する。許可リストの個人 owner のリポジトリでは他人がいないとみなし、そこで行う Tier 2 の非破壊的な操作(作成・close・reopen・edit)は Tier 1 扱いにできる。
2. **適用の条件**:Tier 1 の「規則の構文で強制できること」という要件は残す。前方一致の照合では作成先の owner を表せない(`-R` / `GH_REPO` / cwd の remote で作成先が変わる)ので、規則だけでは条件を満たせない。allow に置けるのは**作成先を自分で検査してから作る**スクリプト経由の操作だけで、これは rule-enforced ではなく、spec の hook-enforced と同じ「スクリプトが強制する」別枠である。今これを満たすのは issue-linkage スキルの `create-issue.sh` だけで、その `bash ~/…` の綴り(`~` 形と展開形)を ask から allow に移す。

`create-issue.sh` は作成の前に、gh と同じ優先順(`-R` / `--repo` → `GH_REPO` → cwd の remote)で作成先を決め、範囲外のときと判定できないときは何も作らずに終了コード 2 で止める。作成先の読み取りは issue-linkage-guard と同じ関数(`issue_linkage_scope_repo_flag`)を使う。値を取るオプションの値(`--label -Rx/y`)を作成先と誤読すると、cwd の仕事のリポジトリに確認なしで作ってしまうため、値は読み飛ばす。

## Considered Options

- **Tier モデルは変えず、create-issue.sh を例外として注記する** — 却下。基準のない個別判断に戻り、Tier モデルを入れた目的(足すたびに議論しないで済む基準)が崩れる。
- **ask から外すだけにして、auto mode の classifier に任せる** — 却下。判定が確率的で、毎回変わりうる。
- **スクリプトの検査なしで allow に置く** — 却下。残りの引数を `gh issue create` にそのまま渡すので、`--repo <任意の owner>/x` で仕事の org を含むどのリポジトリにも確認なしで作れてしまう。

## Consequences

- **gh pr の write 系とは別の基準で並ぶ。** `gh pr create` などは 2026-09-15 に「他のエンジニアと CI へ実際に作用があるか」を基準にして allow に移してあり(`dot_claude/settings.json.tmpl` の allow 側のコメント)、作成先の owner は検査していない。この ADR はその基準を置き換えない。
- **issue の edit / close / reopen は ask に残る。** 原則 1 では Tier 1 扱いにできるが、条件 2 を満たす経路が無い。扱いは #443 で決める。
- **公開リポジトリの watcher には通知が届く。** 「他人がいない」は近似で、個人 owner の公開リポジトリを watch している人には新しい issue の通知が行く。これは受け入れる。
- **`@claude` を含む issue は、有料の `claude.yml` ジョブを確認なしで起動する。** 同じ起動は allow 済みの `gh issue comment` からもできるので、作成時だけ塞いでも防げる経路は増えない。
- **範囲の強制はスクリプトとライブラリの中身に依存する。** `create-issue.sh` と `~/.claude/scripts/lib/issue-linkage-scope.bash` のどちらかの検査が壊れれば、allow は範囲外にも効く。検査は `test/issue-linkage-create-issue.bats` と `test/issue-linkage-scope.bats` が固定している。`bash` を付けない直接実行や別の綴りは allow に当たらず、classifier の判定に落ちる。
- **gh と作成先の決め方がずれる形は、判定不能に倒す。** github を含むのに読めない形の remote の URL(ユーザー名付き・ポート付き・`github-work` のような SSH のホスト別名)は、gh の remote の順位(upstream > github > origin > その他)でその remote が選ばれる(同順位を含む)なら作成しない。名前に github を含まない SSH のホスト別名だけは見分けられず、その remote を飛ばして判定する。これは残存として受け入れる。
- **ホストの無い `-R` / `GH_REPO` は `GH_HOST` のホストで解決される。** `GH_HOST` が github.com 以外なら、同じ owner 名でも別ホストのリポジトリなので範囲外にする。`GH_HOST` が無くても、gh の設定でログインしているのが github.com 以外の 1 ホストだけのときは gh がそのホストを既定にしうるが、ライブラリは gh の設定を読まないので見分けられない。これは残存として受け入れる。
- **許可リストは環境変数で広げられる。** `ISSUE_LINKAGE_GUARD_OWNERS` を設定したセッションでは、そこに書いた owner も範囲内になる。前置の `ISSUE_LINKAGE_GUARD_OWNERS=… bash …` は allow の綴りに当たらないので classifier の判定に落ちるが、セッションの環境に設定されていれば allow のまま効く。
