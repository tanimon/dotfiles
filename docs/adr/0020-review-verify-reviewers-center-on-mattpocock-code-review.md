---
status: accepted
date: 2026-10-23
---

# Review-Verify のレビュアーを mattpocock の 2 軸と、正しさを見る 2 体にする

Review-Verify のレビュアーを、`mattpocock-skills:code-review` の Standards 軸と Spec 軸、`ecc-code-review`、`pr-review-toolkit:silent-failure-hunter` の 4 体にし、`superpowers:requesting-code-review` を外す。mattpocock の code-review は、規約(Standards)と要件文書(Spec)を別の軸で見て、互いに打ち消させない。ただしこの 2 軸はバグもセキュリティも探さないので、正しさを見るレビュアーを必須の枠として残す。ecc はその枠で正しさとセキュリティだけを見て、規約とコード品質は Standards 軸に任せる。silent-failure-hunter は、握りつぶされる失敗と根拠の無いフォールバックを探す。このリポジトリのフックやスクリプトで繰り返し問題になってきたフェイルオープンは、この種の欠陥だからである。requesting-code-review の「plan との整合」は Spec 軸と、「コード品質」は Standards 軸と重なるので外す。レビュアーを増やすと見つかる指摘は増えるが、誤検出・統合と見送り検証の呼び出し・トークンも増えるので、観点の重ならない 4 体に絞る。

[ADR 0007](0007-deliver-workflow-enforces-review-loop-in-code.md) の「2本構成」はこの ADR で置き換わる。判定をコードで行う方針はそのまま引き継ぐ。

## Considered Options

- **mattpocock の code-review を 1 体のエージェントに丸ごと実行させる** — 却下。この skill は手順の中で 2 体のサブエージェントを並列に起動する。Workflow の `agent()` で起動したエージェントがさらにサブエージェントを起動できるかは、Workflow の資料に書かれておらず、実測もしていない。動かなければ、fork 型の built-in `code-review` と同じく結果が親セッションに流れるか、黙って 1 軸だけになる。2 軸を別々のレビュアーとして並べれば、並列化と軸の分離を Workflow 側で保証できる。
- **使えるレビュー skill・エージェントをできるだけ足す** — 却下。理由は上に書いたとおり。
- **mattpocock の 2 軸だけにする** — 却下。正しさとセキュリティの観点が抜ける。

## Consequences

- mattpocock の code-review は重大度の尺度を持たず、hard violation と judgement call を区別するだけである。この 2 値(`hard` / `judgement`)を mattpocock 系 2 体の尺度にし、`hard` を修正必須にする。
- Standards 軸が Fowler の code smell を基準に挙げた指摘は、Smell Finding として最終報告に載せるだけにし、修正エージェントには渡さない。smell はすべて judgement call なので、Advisory Finding と同じに扱うと、修正エージェントが頼まれていないリファクタリングを始める。統合後の指摘の元の指摘が**すべて** smell のときだけ Smell Finding にする。別のレビュアーが同じ箇所を不具合として挙げていれば、その重大度で判定する。smell と申告された指摘は、申告された重大度にかかわらず修正必須にしない。
- Spec 軸の手順にある「要件文書に書かれていない振る舞い(scope creep)」は、作業を止めない Requirements Concern に回す。要件文書は plan であることも多く網羅的ではないので、修正エージェントに渡すと、人間が意図して書いた機能を消しうる。Spec 軸の「未実装・部分実装」は、ほかのエージェントと同じく、ブランチが着手した項目に限る。
- mattpocock の code-review の手順は対話と issue tracker を前提にしている(固定点を尋ねる、tracker から spec を探す、無ければ `/setup-matt-pocock-skills` を案内する、2 体を起動して集約する、400 語以内にまとめる)。Workflow のプロンプトでこれらを上書きする。上書きはプロンプトでの指示にとどまり、コードでは強制できない。
- silent-failure-hunter は skill ではなくエージェント種別なので、`agent()` の `agentType` で起動する。`agentType` と `schema` を組み合わせて結果を返せることは、Workflow の資料には書かれているが、まだ実測していない。
- 動作確認が落ちたときの修正エージェントには `mattpocock-skills:diagnosing-bugs` を使わせる。再現できる手順を作ってから直し、回帰テストを残す流れがこの段に合う。人間に相談する場面(再現手順が作れない、人間の操作が要る)は、直せなかったとして返させる。
