# troubleshooting

## fail の切り分け(最重要)

fail は必ず次の 3 分類のどれかに切り分けてから報告する。**分類せずに
「fail しました」とだけ報告しない。勝手に実装コードを直さない。**

1. **実装バグ**: 期待結果(承認済み観点)は正しいのに画面の振る舞いが違う。
   → trace(`npx playwright show-trace test-results/<...>/trace.zip`)で操作時点の
   画面・ネットワークを確認し、再現手順と証跡(動画パス)を添えて報告する
2. **シナリオ側の誤り**: セレクタ外れ・待ち不足・期待値の解釈違い。
   → シナリオを直して再実行する(実装は触らない)
3. **環境問題**(呼び出し元に返す `blocked` の範囲の定義はここ): ブランチのコードの外に原因があるもの。アプリ未起動・DB 未準備・`.env` 不足・
   保存場所が未決定や書き込み拒否・ポートを別 worktree のアプリが握っている・質問できない状況で
   人間の回答が要る不明点が残った(profile 調査で起動方法やログイン方式を確定できない)など。
   → 環境を直して機能全体を再実行する。直すのに人間の操作(資格情報・サンドボックスの許可・
   保存場所の決定・不明点への回答)が要るなら止めて報告する。deliver などから呼ばれて結果に `blocked` を求められて
   いれば、この分類のときだけ `blocked=true` にする。ブランチのコードが原因でアプリが起動しない・
   500 を返すのは 1(実装バグ)であって環境問題ではない

見分けの起点: 同じ観点を trace で見て、(a) 操作自体が届いていない → 2、
(b) 操作は届いたが応答が 5xx / 想定外 → 1 か 3(アプリログを見る)、
(c) 全シナリオが同じ箇所で落ちる → 3 の可能性が高い。

## 症状別

- **`Error: VERIFY_BASE_URL を .env に設定するか、実行時に渡してください` /
  `Error: VERIFY_LOGIN_ID / VERIFY_LOGIN_PASSWORD を .env に設定してください`**
  → `.env.example` をコピーして `.env` を作り値を埋める(ユーザーに依頼する)。
  `.env` は `playwright.config.ts` と同じディレクトリのものが読まれる
- **`Error: VERIFY_REPO_DIR に検証対象の worktree のパスを渡してください`**
  → 保存場所が対象リポの外にある。`VERIFY_REPO_DIR="<worktree の絶対パス>"` を付けて実行する。
  リポの中にあるのに出る場合は `playwright.config.ts` の `REPO_DIR_FROM_SUITE` が `null` のまま
- **`Error: VERIFY_FEATURE=<feature> のシナリオ(scenarios/<feature>/ の *.spec.ts)がありません`**
  → `scenarios/<feature>/` が無いか spec が 1 件も無い、または slug がブランチ名から作ったもの
  (SKILL.md の「検証資産」)と違う。旧レイアウトの平置きシナリオは `VERIFY_FEATURE` 未設定の
  全体実行でだけ収集される
- **auth-setup は通るのに全シナリオが未ログイン画面に飛ばされる**
  → `.auth/<feature>/user.json` が古い(セッション失効)。`.auth/<feature>/` を削除して再実行
- **起動確認(readiness)が通らない**
  → profile.md の起動コマンド・readiness 条件を見直す。アプリのログを提示して
  中止する(起動しないままブラウザ操作に進まない)
- **pass / fail が実行のたびに変わる(flaky)**
  → 固定 sleep や一時表示への依存を疑う(scenario-authoring.md の規約違反)。
  それでも不安定なら対象を単体実行して trace を比較する
- **再実行のたびにデータが増殖する / 前提データが見つからない**
  → `seed/common.ts` / `seed/features/<feature>.ts` が冪等でない、またはシナリオ間の実行順依存がある。
  固定識別子での存在チェックを入れる(`<skill-dir>/assets/seed/module.template.ts` の規約コメント参照)
- **別の機能の seed が落ちる(まだ無いテーブル・カラムを参照している)**
  → `VERIFY_FEATURE` を付けずに全体実行している。未マージの機能の seed も流れるので、
  今回の機能だけを `VERIFY_FEATURE=<feature>` で実行する
- **保存場所への書き込みが `Operation not permitted` で失敗する**
  → リポの外の保存場所がサンドボックスの書き込み許可の外にある。迂回せず止めて報告し、
  許可を広げるか保存場所を変えるかをユーザーに決めてもらう
- **録画にログイン操作(パスワード入力)が映っている**
  → auth の分離が壊れている。ログインが auth.setup.ts の外(シナリオ内)で
  行われていないか、playwright.config.ts の auth-setup プロジェクトの
  `video: "off"` が消えていないかを確認する。**該当動画は共有前に削除する**
  なお scenarios の trace.zip にはセッション Cookie・ヘッダが含まれる(auth-setup は
  trace off のためパスワードは含まれない)。動画と同様、外部共有前に扱いに注意する
- **`npx playwright install chromium` が遅い / 失敗する**
  → 初回はブラウザバイナリのダウンロードに数分かかる。プロキシ環境では
  `HTTPS_PROXY` の設定を確認する
- **CI や別マシンで動かしたい**
  → 本 skill の scope 外だが、資産は標準形式なのでそのまま移植できる。
  `.env` 相当の環境変数と対象アプリの起動だけ用意すればよい
- **検証ディレクトリの外から `--config` 指定で実行したい**
  → `.env` と `.auth/` は `playwright.config.ts` の位置を基準に解決されるので動く。ただし
  旧レイアウト(`support/run.ts` が無い)のスイートは CWD 基準なので、検証ディレクトリで実行する
