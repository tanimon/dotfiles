# Domain Docs

engineering 系 skill がコードベースを探索するとき、このリポジトリの domain ドキュメントをどう読み書きするか。

## Before exploring, read these

- **`CONTEXT.md`**（リポジトリルート）— glossary の正典。形式は `domain-modeling/CONTEXT-FORMAT.md` に準拠（`**Term**:` + 1〜2文 + `_Avoid_:`）。
- **`docs/adr/`** — Architecture Decision Record。これから触る領域に関わる ADR を読む。
- **`docs/solutions/`** — ADR **ではない**。過去に踏んだ問題とその解決の記録（学びのアーカイブ）で、「何を決めたか」ではなく「何が壊れてどう直したか」が書かれている。決定の根拠として引くのではなく、同じ罠を踏み直さないために読む。
- **`CLAUDE.md`** の "Known Pitfalls" — `docs/solutions/` の要約版。短時間で当たるならこちらが先。
- **`CONCEPTS.md`** — **deprecated**。`CONTEXT.md` の前身。用語の背景を深く追うときだけ読む（下記「`CONCEPTS.md` の扱い」）。

これらが存在しない場合は **黙って進める**。不在を指摘したり、先回りして作成を提案したりしない。`/domain-modeling`（`/grill-with-docs` と `/improve-codebase-architecture` から到達する）が、実際に用語や決定が確定した時点で遅延生成する。

## File structure

single-context リポジトリ（このリポジトリ）:

```
/
├── CONTEXT.md           ← glossary（正典）
├── CONCEPTS.md          ← 前身。deprecated、読み取り専用アーカイブ
├── docs/adr/            ← Architecture Decision Record
├── docs/solutions/      ← 過去の問題解決の記録（ADR ではない）
├── docs/agents/         ← このファイルを含む skill 設定
└── dot_*/ darwin/ ...   ← chezmoi source
```

`CONTEXT-MAP.md` は無く、multi-context 構成は取らない。

## `CONCEPTS.md` の扱い

glossary の書き手は歴史的に2系統あった: `ce-compound` / `ce-compound-refresh` が `CONCEPTS.md` に、mattpocock 系 skill（`/domain-modeling` 等）が `CONTEXT.md` に書く。**ce-* 系は retire 検討中で新規追記の想定がないため、一本化ではなく世代交代で解決している**（一時的に symlink による SSoT を試したが、mattpocock のデフォルト構成を素直に採る方針に切り替えた）。

- **書き込みは `CONTEXT.md` のみ。** 新しい用語・定義・`_Avoid_` を `CONCEPTS.md` に追加しない。
- **`CONCEPTS.md` は消さない。** `CONTEXT-FORMAT.md` の「定義は1〜2文」制約に収まらない詳細な段落（fail open の含意、prefix マッチの限界、Contrast Pair 自体の限界、部分所有の危険）がそこにしか無い形で残っている。
- 誤って `CONCEPTS.md` に追記された内容を見つけたら、`CONTEXT.md` へ 1〜2文に圧縮して移し、背景段落は `CONCEPTS.md` に残す。
- ce-* 系 skill を実際に retire した時点で、`CONCEPTS.md` の残存段落を `docs/adr/` と `docs/solutions/` へ振り分けてファイルを削除できる。それまでは deprecated のまま置く。

## 形式は `CONTEXT-FORMAT.md` に従う

```md
**Term**:
{1〜2文。それが何で**あるか**を書く。何をするかは書かない。}
_Avoid_: 避ける同義語, 別の避ける語
```

- **定義は1〜2文まで。** 深い含意・失敗モード・検証手順は glossary の仕事ではない。それらは `docs/adr/`（決定なら）か `docs/solutions/`（壊れた記録なら）に置く。
- **このプロジェクト固有の用語だけ入れる。** 一般的なプログラミング概念は、このリポジトリで頻出しても入れない。
- 自然なクラスタができたら `### 見出し` でグループ化してよい。
- 複数の語が同じ概念を指すなら**断定的に1つ選び**、残りを `_Avoid_` に列挙する。曖昧な語（例: `profile`）は限定付きの別用語2つに割るのが正しい解決で、「曖昧です」と注記して残すのは解決ではない。

## 新しくルート直下にファイルを作るとき

このリポジトリは chezmoi source なので、**ルートに置いたファイルは `.chezmoiignore` に登録しない限り `~/` へ deploy される**。`CONTEXT.md` / `CONCEPTS.md` / `docs/` は登録済みだが、新設ファイルは登録漏れがそのまま home ディレクトリ汚染になる。

新しい root-level ドキュメント（`CONTEXT-MAP.md` 等）を作る場合は、同じ変更で `.chezmoiignore` に追記し、`chezmoi managed --source "$(pwd)" | grep <name>` が空であることを確認する。

## Use the glossary's vocabulary

出力が domain concept に言及するとき（issue のタイトル、リファクタ提案、仮説、テスト名）は、`CONTEXT.md` で定義された用語をそのまま使う。`_Avoid_` に挙がっている同義語へ流れない。

必要な概念が glossary に無いなら、それはシグナル: プロジェクトが使っていない語彙を発明しているか（考え直す）、本当のギャップがあるか（`/domain-modeling` 用に記録する）。

## Flag ADR conflicts

出力が既存の ADR と矛盾する場合は、黙って上書きせず明示的に指摘する:

> _ADR-0001（…）と矛盾するが、再検討の価値があるのは…_

`docs/solutions/` の記録と矛盾する場合も同様に指摘する。ただしそれは決定の反転ではなく「以前この方法で壊れた」という観測なので、なぜ今回は壊れないのかを示す。
