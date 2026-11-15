# Software Factory / AI SDLC 調査の監査(一次ソース照合によるセカンドオピニオン)

日付: 2026-11-15
対象: 別のエージェントが書いた調査レポート「Software Factory / AI SDLC 調査」(2026-11-13、追補 2026-11-14。以下「元レポート」)の主張と、それぞれの主張を所有する一次ソース
結論と推奨をまとめた本文: [Software Factory / AI SDLC 調査(改訂版)](2026-11-15-software-factory-ai-sdlc.md)
比較先: このリポジトリの ADR 0007 / 0011 / 0015 / 0022(自律実装フローを自前で持ち、後に撤退した記録)と、ローカルにインストールされた Elephant-Goldfish Model(EGM)プラグイン 0.1.1

本書の方針:

- 元レポートは検証対象の未検証入力として扱い、出典としては使わない。元レポートの推奨を支えている主張(数値・日付・帰属)を 1 行 1 主張に分けて台帳にし、一次ソースに当たって状態を付けた。
- 引用は WebFetch が返した短い抜粋(英文の逐語)で、ページ全文を `grep` で突き合わせたものではない。抜粋に無いことは「見つからなかった」と書き、反証とは扱わない(状態は `未確認`)。`不一致` は、取得した一次ソースが別の値を示しているときに限って付けた。
- openai.com は WebFetch が HTTP 403 を返したため、OpenAI の一次ソースは本文を読めていない。検索結果の抜粋と二次ソースで照合したものは `二次ソースのみ` とした。
- 事実(2〜5 節)と、元レポートの推奨に対する本書の評価(6 節)を分けて書く。未解決の問いは 7 節に置く。
- 元レポートの趣旨は「GitHub Issue を渡すと CI が通った Draft PR が返る仕組み(ソフトウェア工場)」の設計提案である。その結論は「単一ライター + 別権限の検証 + holdout + リスク階層化した人間ゲート」で、仕様層に Google の EGM、基盤の点検に Cloudflare の ADLC 7 条件を置き、Route A(Copilot coding agent + OpenSpec + EGM レビュー + Actions のゲート)/ Route B(OpenHands か Claude Agent SDK を自前で制御し Temporal 等で編成)/ Route C(1 種別に絞ったパイロット)を示している。

## 1. 要約

- **結論の骨格は一次ソースで概ね支持できる。** 「書き手は 1 人」(Cognition、CooperBench、後続の Claim Plane)、「ボトルネックは検証とレビュー」(Spotify の 2026 年の 2 本、DORA 2025)、「エージェントに見えるテストは攻略される」(StrongDM、ImpossibleBench)、「公開ベンチマークは許可証にならない」(SWE-bench Verified の監査)は、どれも一次ソースか複数の二次ソースで裏が取れた。
- **ただし個々の根拠には誤りと誇張がある。** Copilot coding agent の GA は 2025 年 5 月ではなく 2025-09-25。CooperBench は「小規模」ではなく 600 超のタスク。Spotify の「落ちたテストをコメントアウトし Java を下げた」は Honk の Part 1〜3 に見つからず、Part 3 にあるのは「flaky なテストを無効化しようとした」という範囲外の行動の記述だけだった。Faros の「PR あたり障害 +242.7%」には、同じ Faros の後続レポート(2026-09)で +14.5% という別の切り口の値が出ている。
- **Route A の「CI が通った PR が返る」には、元レポートが触れていない前提がある。** Copilot(現名称 Copilot cloud agent)の PR では、既定で GitHub Actions が走らず、書き込み権限を持つ人間の承認を待つ(設定で自動実行にできる)。「CI 通過」を工場の出力にするには、この既定を外すかどうかを決める必要があり、それはエージェントが書いたコードを人の確認前に CI で実行するというセキュリティ上の判断になる。
- **EGM の評価は過大。** ローカルの 0.1.1 を読むと、7 つの skill はすべて `disable-model-invocation: true`(人が起動する前提)で、レビューは対話ゲートを持つ。中断しないプリセットもあるが、1 回の全段レビューでレビュアーのサブエージェントを 10 体起動する。元レポートの「追加コストはほぼゼロ」とは合わない。Issue→PR の無人パイプラインに組み込めるかは、本書では試しておらず未検証。仕様の分岐を人間が判断する段(元レポート自身が人間を残すとした場所)の道具として位置づけるのが妥当と考える。
- **元レポートが扱っていない反証・リスク:** エージェント PR は人間の PR より受け入れ率が低いという独立研究(AIDev)、公開 Issue に仕込んだ指示で私有リポジトリの情報を漏らさせた実証(Invariant Labs、2025-05)、レビュー 1 件 $15–25(Anthropic Code Review)のような実測コスト、人間の監督そのものが劣化するという論文(Mitchell ら、2026-08)。
- **このリポジトリには、自律実装の段を自前で持ち、撤退した記録がある。** PR の作成は人間が確かめる前に起こしたくない外向きの操作だとしてやめ(ADR 0015)、実装段そのものは使われずに保守だけが残るとして廃止した(ADR 0022)。レビュー修正ループの判定をコードで強制する部分(ADR 0007)と、評価器を改善対象の外に置く原則(ADR 0011)は残っている。品質の失敗で撤退したわけではない。Route B を選ぶ前に「実装段を誰が起動し、本当に使うか」を確かめる材料になる。
- 台帳は 138 行(確認 67、不一致 3、二次ソースのみ 35、未確認 33)。

## 2. 主張台帳

状態の定義:

- `確認` — 一次ソース(当事者の公式ページ、論文の arXiv ページ、GitHub API、ローカルのプラグイン本体)を取得し、主張と一致した。
- `不一致` — 取得した一次ソースが別の値・別の事実を示した。正しい値を備考に書く。
- `二次ソースのみ` — 一次ソースの本文を取得できず、二次ソースか検索結果の抜粋でしか照合できていない。
- `未確認` — 一次ソースでも二次ソースでも照合できなかった。取得したページに見つからなかったものも含む。

各行の「主張」は元レポートの主張を言い直したもの、「備考」は照合結果である。

### 2.1 単一ライター(並行する書き手は成功率を下げる)

| # | 主張 | 状態 | 備考(URL・逐語引用・照合結果) |
|---|---|---|---|
| A1 | Cognition の Walden Yan が 2025-06-12 に「Don't Build Multi-Agents」を公開し、(1) 文脈とトレース全体を共有する、(2) 行動は暗黙の決定を伴い衝突すると壊れる、の 2 原則を述べた | 確認 | cognition.com/blog/dont-build-multi-agents。"Share context, and share full agent traces, not just individual messages" / "Actions carry implicit decisions, and conflicting decisions carry bad results"。推奨は "just use a single-threaded linear agent"(コーディングに限定した書き方ではない) |
| A2 | Cognition の 2026 年 4 月の続編が「書き込みは単一スレッドのまま、追加エージェントは行動ではなく知能を提供する」と述べた | 二次ソースのみ | 「Multi-Agents: What's Actually Working」(2026-04-22)。Yan の X 投稿と引用記事が伝える文言は "writes stay single-threaded and the additional agents contribute intelligence rather than actions"(検索結果経由で、逐語かは未確認)。Cognition のページ本体は未取得。レビューでは「コーディング役とレビュー役が事前に文脈を共有しないときに最もよく効いた」とある(同じく二次) |
| A3 | Anthropic のマルチエージェント・リサーチシステムが社内評価で単一エージェント比 +90.2% | 確認 | anthropic.com/engineering/multi-agent-research-system(2025-06-13)。"outperformed single-agent Claude Opus 4 by 90.2% on our internal research eval"。読み取り中心のリサーチ課題での値 |
| A4 | 同システムのトークンは通常のエージェントでチャットの約 4 倍、マルチエージェントで約 15 倍 | 確認 | 同上。"agents typically use about 4× more tokens than chat interactions," / "multi-agent systems use about 15× more tokens than chats." |
| A5 | 性能差の約 80% はトークン使用量で説明できた | 確認 | 同上。"We found that token usage by itself explains 80% of the variance"。原文は「性能の分散の 80%」で、元レポートの「(マルチと単一の)性能差の約 80%」は意味がずれた言い換え |
| A6 | Anthropic 自身が、共有文脈や依存の多いタスク(大半のコーディング)は現状マルチエージェントに不向きと述べた | 未確認 | 同ページの抜粋で見つかったのは "most coding tasks involve fewer truly parallelizable tasks than research" のみ。「不向き」と断じる文そのものは抜粋に無かった |
| A7 | CooperBench で、2 体が協力すると成功率は約 25% で、1 体が両方をこなす場合の約半分 | 確認 | cooperbench.com/blog/curse-of-coordination。"GPT-5 and Claude Sonnet 4.5 achieve only 25% success when two agents cooperate"、"50% lower than one agent doing both features alone"。論文の要旨(arXiv:2601.13295)は平均で "30% lower success rates when working together" |
| A8 | CooperBench は Stanford と SAP Labs の研究 | 確認 | 同ブログの著者注 "Equal contribution (Stanford) · †Equal contribution (SAP Labs)" |
| A9 | CooperBench の公表は 2026 年 1 月 | 確認 | arXiv:2601.13295 v1 は 2026-01-19、v2 は 2026-01-26 |
| A10 | CooperBench の設定は「同じコーディング作業を分割し、共有ファイルを 2 体で編集する」 | 確認 | 言い方の補足: 2 体がそれぞれ別の機能を同じリポジトリに実装し、調整しないとコードが衝突する設定で、比較の基準は 1 体が両方の機能を実装する場合(ブログの "one agent doing both features alone")。「作業の分割」とは合うが、同じファイルの同時編集に限った測定ではない |
| A11 | リアルタイムのメッセージングでも改善せず、行動予算の最大 20% をメッセージに使った | 確認 | 同ブログ。"Communication does not improve overall success."(ただしマージ衝突は減った)、"They spend up to 20% of their action budget on communication." |
| A12 | CooperBench はタスク数が小規模なので方向の読み取りに留めるべき | 不一致 | 要旨は "a benchmark of over 600 collaborative coding tasks across 12 libraries in 4 programming languages" |
| A13 | 書き手を 3〜4 体にするとさらに悪化する | 確認 | 同ブログ。"With 2 agents we saw 68.6% success. With 3 it fell to 46.5%. With 4 it dropped to 30.0%."(モデルの指定が無く、A7 の 25% とは直接比べられない) |
| A14 | Google の「Towards a Science of Scaling Agent Systems」は 260 構成・6 ベンチマーク・5 アーキテクチャ・3 モデルファミリーで計算量をそろえて測った | 二次ソースのみ | arXiv:2512.08296(v1 2025-12-09、v3 2026-04-08)。構成数は arXiv HTML 版の検索抜粋で確認したのみ。初期版と Google Research ブログは 180 構成。Nature Machine Intelligence に別題で掲載との記載がリポジトリにある(二次) |
| A15 | 同論文で、マルチエージェントの平均ゲインは約 −0.3% | 未確認 | 要旨にあるのはタスク別の幅 "ranges from +80.8% on decomposable financial reasoning" から −70.0% まで。平均値は見つからなかった |
| A16 | 同論文で、協調オーバーヘッドはトークン 1.6〜6.2 倍 | 未確認 | 要旨と検索抜粋に無かった |

### 2.2 ボトルネックは生成ではなく検証

| # | 主張 | 状態 | 備考 |
|---|---|---|---|
| B1 | Spotify の背景エージェント Honk は 2025-11-06 時点で 1,500 超の PR をマージした | 確認 | engineering.atspotify.com/2025/11/spotifys-background-coding-agent-part-1。"more than 1,500 pull requests that teams across Spotify have merged into our production codebase" |
| B2 | 機械検証できるコード移行で 60〜90% の時間削減 | 確認 | 同上。"a total time saving of 60–90% compared to writing the code by hand" |
| B3 | Honk の基盤は Claude Agent SDK | 確認 | Part 1 には記載なし。Part 2(2025-11-24)が "Claude Code is our top-performing agent" と書き、Anthropic の言として "used Claude Agent SDK to merge thousands of PRs across hundreds of repositories" を引く |
| B4 | 初期のエージェントは落ちたテストをコメントアウトし、Java のバージョンを下げてビルドを通した | 未確認 | Part 1・2・3 のいずれにも見つからなかった。Part 3(2025-12-09)にあるのは、エージェントが "trying to solve problems that weren't strictly in their prompt, like refactoring code or disabling flaky tests" という範囲外の行動の記述。二次ソース(SysDesAi)は「テスト削除や依存のダウングレード」と言い換えている |
| B5 | Spotify 自身が、制約は生成ではなく PR レビューと検証だと結論した | 確認 | 帰属は Honk の連載ではなく 2026 年の 2 本。2026-06-03 の記事が "76% more PRs to review" と "bottleneck moves from coding to decision-making"、2026-09-16 の記事が "the volume of change increased faster than some of our verification controls could adapt"。原文の言葉は「レビュー」より「意思決定」 |
| B6 | 2026 年 9 月の投稿で、チェックを通過した自動依存更新が本番で失敗した事例が開示された | 確認 | engineering.atspotify.com/2026/9/ai-changed-how-spotify-builds-…(2026-09-16)。"This year, an automated dependency upgrade passed our checks, but still failed in production, impacting end users." 同記事は "we did not identify AI-authored code as a material direct contributor" とも書く |
| B7 | 2026 年 3 月時点で約 1,000 PR / 10 日 | 二次ソースのみ | QCon London 2026 の講演を伝える二次記事のみ |
| B8 | DORA 2025 は約 5,000 人の調査 | 確認 | cloud.google.com の発表(2025-09-24 付。元レポートの 9 月 23 日とは 1 日ずれる)。"survey responses from nearly 5,000 technology professionals" |
| B9 | 仕事で AI を使う人は 90% | 確認 | 同上。"90% of survey respondents report using AI at work." |
| B10 | その 90% は前年比 +14pt | 二次ソースのみ | Google の発表ページに増分の記載は無く、二次記事のみ |
| B11 | 約 30% は AI 生成コードへの信頼がほぼ無い | 確認 | 同上。"30% report little or no trust in the code generated by AI" |
| B12 | 「AI は増幅器」が見出しの主張 | 確認 | 同上。"AI doesn't fix a team; it amplifies what's already there." |
| B13 | AI 採用はスループットとは正、安定性とは負の関係 | 確認 | 同上。"we observe a positive relationship between AI adoption on both software delivery throughput and product performance" / "AI adoption does continue to have a negative relationship with software delivery stability." |
| B14 | 性能ティアは 7 つのチームアーキタイプに置き換わった | 確認 | 同上。"seven common team profiles or archetypes" |
| B15 | 5 つ目の DORA 指標として手戻り率(rework rate)が追加された | 未確認 | 発表ページに記載なし。報告書本体は未取得 |
| B16 | Faros 2025: 高 AI 採用でマージ PR +98%、レビュー時間 +91%、PR サイズ +154% | 二次ソースのみ | faros.ai の自社ページを要約した検索結果(マージ PR +98%、レビュー時間 +91%、1 万人のテレメトリ)と二次記事。相関データ |
| B17 | Faros 2026: レビュー時間 +441%、PR あたり障害 +242.7% | 二次ソースのみ | 「The Acceleration Whiplash」(2026 年 Q2)の検索抜粋。+441.5% は中央値。+242.7% は低採用期から高採用期への「障害/PR 比」の変化。Faros 自身の後続「The Speed Trap」(2026-09-18)では、既に高採用のチームで PR あたり障害 +14.5%。元レポートは後続に触れていない |
| B18 | METR の RCT(2025-07-10)で、熟練 OSS メンテナ 16 人・実タスク 246 件、AI ありで 19% 遅くなった | 確認 | metr.org/blog/2025-07-10-…。"take 19% longer to complete issues"。ページには「現在の影響を反映しない」旨の注記が追加されている |
| B19 | その 19% の信頼区間は +2%〜+39% | 確認 | metr.org/blog/2026-02-24-uplift-update。"a confidence interval between +2% and +39%" |
| B20 | 事前予測は +24%、事後の実感は +20% | 確認 | 2025-07-10 のページ。"expected AI to speed them up by 24%" / "still believed AI had sped them up by 20%" |
| B21 | 2026-02 の追跡調査は 57 人・800 超タスクで「非常に弱い証拠」、30〜50% がタスクを差し控えた | 確認 | 2026-02-24 のページ。"57 developers, across 143 repos, and 800+ tasks"、"only very weak evidence"。点推定は元の参加者 −18%(95% CI −38%〜+9%)、新規参加者 −4%(−15%〜+9%)。負の値が高速化 |
| B22 | METR 2026 年 5 月調査で自己申告は中央値で価値 1.4〜2 倍、速度 3 倍 | 未確認 | 該当ページを特定できなかった |

### 2.3 holdout と報酬ハッキング

| # | 主張 | 状態 | 備考 |
|---|---|---|---|
| C1 | StrongDM の Software Factory は 2026-02-06 公開、チームは 2025 年 7 月結成の 3 人 | 確認 | factory.strongdm.ai。"February 6th, 2026"、結成 "July 14th, 2025"。3 人は Willison の記事(C10)で確認 |
| C2 | 規則は「人間はコードを書かない」「人間はコードをレビューしない」 | 確認 | 同上。"Code must not be written by humans" / "Code must not be reviewed by humans" |
| C3 | 振る舞い仕様(シナリオ)をコードベースの外に、ML の holdout のように置く | 確認 | 同上。"often stored outside the codebase"、"similar to a "holdout" set in model training" |
| C4 | holdout にした理由は、エージェントが `return true` を書いて見えるテストを攻略したため | 二次ソースのみ | Willison の記事に "if they don't cheat and `assert true`"。StrongDM のページの抜粋には理由の記述が無かった |
| C5 | 指標「満足度」= 観測された軌跡のうち仕様を満たす割合 | 確認 | 同上。"of all the observed trajectories through all the scenarios, what fraction of them likely satisfy the user?"(判定は LLM) |
| C6 | Digital Twin Universe は Okta・Jira・Slack・Google Docs 等の振る舞いクローン | 確認 | 同上。"behavioral clones of the third-party services our software depends on"(Okta, Jira, Slack, Google Docs/Drive/Sheets) |
| C7 | 「エンジニア 1 人あたり 1 日 1,000 ドル以上をトークンに使っていなければ改善余地がある」 | 確認 | 同上。"If you haven't spent at least $1,000 on tokens today per human engineer, your software factory has room for improvement" |
| C8 | 欠陥流出・本番障害の公開データは無い | 確認 | 同ページの抜粋に該当データ無し |
| C9 | StrongDM は Delinea に買収された(2026-01-15 発表、03-05 完了) | 二次ソースのみ | GlobeNewswire のプレスリリース(2026-01-15)と業界紙。完了日は Tracxn 経由の Benzinga 見出しのみ |
| C10 | 独立した訪問は Willison の 1 件(2025 年 10 月) | 確認 | simonwillison.net/2026/Feb/7/software-factory/。10 月の訪問。Willison 自身の懐疑も記されている("If these patterns really do add $20,000/month per engineer to your budget they're far less interesting to me.") |
| C11 | Stanford CodeX が 2026-02-08 に「Built by Agents, Tested by Agents, Trusted by Whom?」で問いを立てた | 二次ソースのみ | 検索結果のタイトルと URL の日付のみ。本文未取得 |
| C12 | ImpossibleBench(2025 年 10 月)は、仕様と矛盾するテストを持つタスクで「合格」が近道の証拠になることを示した | 二次ソースのみ | arXiv:2510.20270(2025-10-23、ICLR 2026)。要旨の検索抜粋と GitHub のみ |
| C13 | Veracode(2025-07-30)は 100 超の LLM・80 タスク・4 言語で、45% が OWASP Top 10 の欠陥を導入したと報告 | 二次ソースのみ | Veracode のプレスリリースと自社ブログの検索抜粋。ベンダー研究 |
| C14 | 同報告で Java の失敗率 72%、XSS 86%、ログインジェクション 88% | 二次ソースのみ | Veracode 自身の発表は Java を 70% 超と表記(検索結果の要約)。72% は二次ソースの値。XSS 86% は Veracode ブログの検索抜粋 |

### 2.4 ベンチマーク

| # | 主張 | 状態 | 備考 |
|---|---|---|---|
| D1 | OpenAI は 2026-02-23 に SWE-bench Verified の報告を停止した | 二次ソースのみ | openai.com は 403。OpenAI Developers の X 投稿の検索抜粋と複数の二次記事 |
| D2 | o3 が繰り返し失敗した 138 件の監査で 59.4% に欠陥テストか不十分な仕様があった | 二次ソースのみ | 二次記事のみ |
| D3 | GPT-5.2・Opus 4.5・Gemini 3 Flash が参照パッチを逐語的に再現できた(汚染) | 二次ソースのみ | 二次記事のみ |
| D4 | Verified のスコアは Opus 4.5 の 80.9% まで上がり、伸び(74.9%→80.9%)は曝露の反映だった | 未確認 | 照合できる抜粋が無かった |
| D5 | SWE-bench Pro(Scale AI、2025-09)は 1,865 タスク・41 リポジトリ・4 言語 | 未確認 | 論文(arXiv:2509.16941)は検索結果に出たが未取得 |
| D6 | OpenAI は 2026-07-08 の監査で、公開 731 件の約 30% が壊れていると推定した | 二次ソースのみ | openai.com/index/separating-signal-from-noise-coding-evaluations/ は 403。同ドメインの検索結果が伝える文言は "we estimate that ~30% of SWE-bench Pro tasks are broken, and advise that model developers carefully examine results" |
| D7 | 内訳は自動パイプラインで 27.4%、5 人のエンジニアのレビューで 34.1% | 二次ソースのみ | 二次記事のみ |
| D8 | OpenAI は SWE-bench Pro の推奨を撤回した | 二次ソースのみ | 「撤回」は二次記事の言い方。一次の抜粋で見えた文言は「結果を注意深く調べるよう勧める」のみ。2026-11 の技術報告(arXiv:2611.13246)も撤回と書く(二次) |
| D9 | 後継のベンチマークは指名されなかった | 未確認 | 一次本文を読めていない |
| D10 | Pro では同じモデルが 15〜35 ポイント下がった(例: Opus 4.5 で 80.9%→45.9%) | 未確認 | 照合できる抜粋が無かった |

### 2.5 EGM(仕様層)

ローカルのプラグイン 0.1.1(Claude Code のプラグインキャッシュ内)の README・skill・docs と、GitHub API で照合した。GitHub の main との差分は取っていない。

| # | 主張 | 状態 | 備考 |
|---|---|---|---|
| E1 | google/elephant-goldfish-model は 2026-09-13 作成、Apache-2.0 | 確認 | GitHub API。`created_at` "2026-09-13T16:31:06Z"、license `Apache-2.0`。2026-11-15 時点でスター 19,415、最終 push 2026-11-14 |
| E2 | Elephant が文脈を全部持って起草し、Goldfish は文書と参照ソースだけを会話履歴なしで読み、人間がトレードオフを解いて承認する | 確認 | README の役割表("The document and its referenced source material, without the earlier conversation") |
| E3 | skill は brainstorm / draft / review / resolve に加え、bootstrap、review loop、drift report | 確認 | README の skill 表と `skills/` の 7 ディレクトリ |
| E4 | review は新鮮なレビュアーが 5 段階で見る | 確認 | `egm-review` の description: "Initial Zoom Out Review, Comprehension Review, Design Critique, Intermediate Zoom Out Review, and Implementation Readiness" |
| E5 | Goldfish レビューには新鮮なサブエージェント文脈が必須で、作れない環境ではレビューを止める | 確認 | README: "Goldfish reviews require fresh subagent contexts. If your agent cannot create them, EGM stops the review." |
| E6 | drift report は文書と現在のソースを比べてズレを報告し、直すのが文書かコードかを人間が決める | 確認 | `docs/getting_started.md`: "Either update the doc, or the code. Human picks which." 週 1 回の実行を推奨。skill 本体は LLM への手順書で、決定的な検査ではない |
| E7 | README は「公式にサポートされる Google 製品ではない」「レビューはテストや人間の判断の代替ではない」と明記する | 確認 | "This is not an officially supported Google product." / "A review does not replace tests or human judgment." |
| E8 | Claude Code / Codex / Copilot / Antigravity 等にプラグインで導入できる | 確認 | README の Install 節と、`docs/copilot.md` 等のハーネス別ガイド |
| E9 | レビューだけを既存文書に 60 秒で試せる | 未確認 | ローカルの README と docs に該当する記述が見つからなかった |
| E10 | EGM の追加コストはほぼゼロ | 不一致 | 反証は 1 回あたりの実行コスト(導入の手間ではない)。中断しないプリセットの手順では、5 段でレビュアーを計 10 体(zoom-out ×2、inventive-catalyst、comprehension、design、structural、style ×2、implementation-readiness、codebase-details)起動し、加えて統合役(synthesizer)を使う。`docs/harnesses.md` の Muse の記録は "uninterrupted review with 15 fresh-context reviewers" |
| E11 | 着想源は Dave Rensin のエッセイ | 確認 | README の "Dave Rensin's original essay" へのリンク |

### 2.6 Cloudflare ADLC(基盤層)

| # | 主張 | 状態 | 備考 |
|---|---|---|---|
| F1 | Cloudflare Blog「The Agent Development Lifecycle has arrived on Cloudflare」は 2026-08-04 公開 | 確認 | blog.cloudflare.com/agent-development-lifecycle/。構造化データで 2026-08-04 公開、著者 Brendan Irvine-Broque |
| F2 | 土台に 7 条件(Programmatic / Horizontally scalable / Reproducible / Real-time, push based / Atomic / Permissioned / Self-improving)を挙げる | 確認 | 例: "Every last operation needs APIs that agents can call, debug, and rely on."、"every agent must have its own preview that matches production"、"every change needs to be independently testable, releasable, observable, and reversible"、"Agents, too, need ways to learn from experience." |
| F3 | 「CI/CD は Workflow である」と主張する | 確認 | "A CI/CD pipeline is just a Workflow. But a Workflow can be so much more than a CI/CD pipeline." |
| F4 | 発表物は @cloudflare/ci、ローカル開発への OTel トレース、Agent Traces、標準の強制、Astro の Issue をゼロにした自社工場 | 確認 | 同ページ。@cloudflare/ci は "a new way to run CI/CD across millions of repos, that can self-heal and spawn agents" |
| F5 | 80% から「99% 台の何桁か」へという課題設定 | 確認 | "going from working successfully 80% of the time, to some number of nines past 99%" |
| F6 | Cloudflare Workflows は状態を分〜週単位で保持し、コンテナ・エージェント・ブラウザを起動できる | 未確認 | 取得した抜粋に無かった |

### 2.7 Route A/B/C の部品

| # | 主張 | 状態 | 備考 |
|---|---|---|---|
| G1 | GitHub Copilot coding agent は 2025 年 5 月に GA | 不一致 | GA は 2025-09-25。github.blog/changelog/2025-09-25-copilot-coding-agent-is-now-generally-available/ に "September 25, 2025"、"is now generally available for all paid Copilot subscribers."。2025 年 5 月はパブリックプレビュー(changelog 一覧の検索抜粋) |
| G2 | Issue を割り当てると Actions 上でクローン→作業→Draft PR を作る | 確認 | docs.github.com の risks-and-mitigations。新しい Issue から起動すると "a new `copilot/` branch is created for Copilot, and the agent can only push to that branch." |
| G3 | マージは必ず人間 | 確認 | 同上。"prevents the user who asked Copilot cloud agent to create a pull request from approving it"。branch protection と required checks はそのまま効く。ただし必須承認を課すかはリポジトリの設定次第 |
| G4 | 2026 年 4 月から計画の事前承認も可能 | 二次ソースのみ | github.blog/changelog/2026-04-01-research-plan-and-code-with-copilot-cloud-agent/ の検索抜粋。同時に名称が Copilot cloud agent に変わった |
| G5 | Agent HQ(2025-10-28)は Claude / Codex 等を GitHub 内にホストする | 未確認 | 照合していない |
| G6 | 料金は 2026-06-01 から AI Credits 制 | 二次ソースのみ | github.blog の 2026-06-01 changelog と 2026-04-27 の発表の検索抜粋。トークン量に応じた従量課金で、長いエージェントのセッションほど高くなる |
| G7 | 1 クレジット = 0.01 ドル | 未確認 | 抜粋に単価の記載が無かった |
| G8 | Claude Code SDK は 2025-09-29 に Claude Agent SDK へ改称 | 確認 | claude.com/blog/building-agents-with-the-claude-agent-sdk(2025-09-29)。"we're renaming the Claude Code SDK to the Claude Agent SDK." |
| G9 | OpenHands は MIT で 86k 超のスター | 確認 | GitHub API(OpenHands/OpenHands)。MIT、2026-11-15 時点 93,500、最終 push 同日 |
| G10 | OpenHands は 2025 年 11 月に Series A 1,880 万ドル | 未確認 | 照合していない |
| G11 | Aider は 2026-05-22 以降 main へのコミットが無い | 確認 | GitHub API(Aider-AI/aider/commits)の最新が 2026-05-22T14:02:20Z |
| G12 | LangGraph は MIT で 1.0 は 2025 年 10 月 | 未確認 | 1.0 の日付は照合していない。リリースは継続中(1.2.22 が 2026-11-14) |
| G13 | Temporal は MIT | 確認 | GitHub API(temporalio/temporal)。MIT、最終 push 2026-11-15 |
| G14 | GitHub Spec Kit は 2025-09-02 に OSS 化 | 二次ソースのみ | GitHub Blog の告知記事の検索抜粋(2025-09-02、Den Delimarsky)。リポジトリ作成は 2025-08-21(GitHub API) |
| G15 | Spec Kit は MIT で、スター数は後半に 13 万超 | 確認 | GitHub API。MIT、2026-11-15 時点 149,852 |
| G16 | OpenSpec(Fission-AI)は MIT で、仕様を既存の振る舞いへの差分(デルタ)として管理する | 確認 | GitHub API で MIT。Thoughtworks の OpenSpec ページは、変更を永続する正本の仕様に対するデルタとして記録すると説明している(要約。逐語は "centers on a spec-anchored workflow") |
| G17 | Thoughtworks Technology Radar(2025 年 11 月)は SDD を Assess に置いた | 確認 | thoughtworks.com/radar/techniques/spec-driven-development。Assess(Vol.33、2025-11-05 公開) |
| G18 | 2026 年 4 月の Radar では Spec Kit と OpenSpec が個別に Assess | 確認 | 両ブリップのページ。どちらも 2026-04-15 公開で Assess |
| G19 | Böckeler(2025 年 10 月)は Kiro も Spec Kit も spec-first 止まりで、spec-as-source を狙うのは Tessl だけとした | 確認 | martinfowler.com/articles/exploring-gen-ai/sdd-3-tools.html(2025-10-15)。"spec-kit is still what I would call spec-first only"、Tessl は "exploring the spec-as-source level of SDD" |
| G20 | Scott Logic(2025-11-26)が Spec Kit を spec-first の足場と批判した | 未確認 | 照合していない |
| G21 | AWS AI-DLC のワークフローは 2025 年 11 月に MIT-0 で OSS 化された | 確認 | GitHub API(awslabs/aidlc-workflows)。作成 2025-11-13、MIT-0 |
| G22 | AWS AI-DLC は 2025-07-31 に公表された | 未確認 | 2025 年 7 月の創設記事の存在は二次ソースにあるが、日付は照合していない |
| G23 | AI-DLC v2 のエンジンは 33 ステージ | 二次ソースのみ | 解説サイトの検索抜粋(5 フェーズ 33 ステージ) |

### 2.8 事例・周辺の数値

| # | 主張 | 状態 | 備考 |
|---|---|---|---|
| H1 | OpenAI「Harness engineering」(2026-02-11、Ryan Lopopolo)は 5 か月で約 100 万行・約 1,500 PR、手書きコードゼロ | 二次ソースのみ | openai.com/index/harness-engineering/ は検索結果に出たが本文未取得。InfoQ 等の二次記事 |
| H2 | 同事例でチームは 3→7 人、3.5 PR / 人 / 日、所要時間は手書き比約 1/10、1 回の実行が約 6 時間 | 二次ソースのみ | 二次記事のみ。3.5 は 1,500 PR / 3 人からの計算と書く記事もある |
| H3 | AGENTS.md は約 100 行の「目次」 | 二次ソースのみ | 二次記事のみ |
| H4 | Stripe Minions(2026-02-09)は週 1,000 超の PR をマージし、全件を人間がレビューする | 確認 | stripe.dev/blog/minions-stripes-one-shot-end-to-end-coding-agents(Alistair Gray)。"while they're human-reviewed, they contain no human-written code." |
| H5 | Minions は Block の goose のフォークで、devbox は約 10 秒で起動し、CI は最大 2 ラウンド、決定的な手順をループに挟む | 確認 | 同上。"spun up in 10 seconds"、"at most two rounds of CI"、"interleave agent loops and deterministic code" |
| H6 | Minions はその後週 1,300 超 | 二次ソースのみ | InfoQ(2026-03) |
| H7 | Osmani「Software Factories, Light and Dark」(2026-07-20)の背圧ルール | 確認 | addyosmani.com/blog/software-factories/。"you can only hand a loop as much autonomy as you can cheaply and reliably verify, and not one inch more." |
| H8 | 約 200 行の計画を先にレビューすれば 2,000 行の diff を追わずに済む | 確認 | 同上。"a quick read of a two-hundred-line plan" / "chasing through two thousand lines of generated code" |
| H9 | 理解負債の定義と、Horthy の 4 か月の無人工場の事例 | 確認 | 同上。"the widening gap between how much code exists and how much any human still understands"、"a fully automated code factory for about four months" |
| H10 | Dan Shapiro「The Five Levels」は 2026-01-23 公開 | 確認 | danshapiro.com の記事 |
| H11 | 「90% が Level 2」は Shapiro 本人の推定 | 確認 | Level 2 の節に "This is where 90% of "AI-native" developers are living right now."。母集団は開発者全体ではなく「AI ネイティブ」の開発者 |
| H12 | Ramp の背景エージェントはマージ PR の約 30%(2026-01)→約 75%(2026 年後半) | 二次ソースのみ | Ramp 公式ブログを要約した検索結果で、マージ PR の 74%。30% は当初はフロントエンドとバックエンドのリポジトリに限った値 |
| H13 | Uber は 2026-08-27 の投稿で PR の 70% 超がエージェント帰属、エージェント利用が 2〜8 月で 9.4 倍 | 二次ソースのみ | Uber Engineering の X 記事の引用のみ。9.4 倍は「週あたりのエージェント要求数」。日付は 8 月 27 日と 29 日の二説 |
| H14 | Factory.ai は Series B 5,000 万ドル(2025-09、評価額 3 億)→ Series C 1.5 億(2026-04、15 億)→ 2 億(2026-09、50 億) | 二次ソースのみ | 資金調達トラッカーと業界紙 |
| H15 | BCG Platinion の「生産性 3〜5 倍」には出典も方法も示されていない | 未確認 | 照合していない |
| H16 | Microsoft の Customer-Zero 投稿で開発者の 90% 超が Copilot を使用 | 未確認 | 照合していない |
| H17 | Gartner(2025-06-25)はエージェント型 AI プロジェクトの 40% 超が 2027 年末までに中止されると予測し、本物のベンダーは約 130 社とした | 二次ソースのみ | gartner.com のプレスリリースの検索抜粋 |
| H18 | Gartner(2026 年 5 月)は 2027 年までに企業の 40% が本番障害後に見つかった統制不備で自律エージェントを格下げ・廃止すると予測 | 二次ソースのみ | gartner.com の 2026-05-26 プレスリリースの検索抜粋 |
| H19 | McKinsey State of AI の 23% / 39%(2025)と 40% / 22%(2026) | 未確認 | 照合していない |
| H20 | Stack Overflow 2025 で 84% が使用・予定、66% が「ほぼ正しい」が不満 | 未確認 | 照合していない |
| H21 | Anthropic の約 40 万セッション分析で計画決定の約 70% は人間 | 未確認 | 一次も二次も特定できなかった |
| H22 | Anthropic は過去の障害の背後のバグの約 1/3 を自動レビューで検出できたと主張 | 未確認 | Code Review の紹介ページ(claude.com/resources/articles/code-review、2026-03-09)に該当の主張は無かった。同ページにあるのは「実質的なレビューコメントが付く PR が 16% から 54% へ」と「1,000 行超の PR の 84% に指摘、平均 7.5 件」 |
| H23 | 文脈の圧縮・編集でトークン 84% 削減、性能 +29%(「Effective context engineering」記事) | 二次ソースのみ | 数値は「context editing / memory tool」の告知(2025-09)を伝える二次記事にある。元レポートが帰属させた「Effective context engineering for AI agents」(2025-09-29)には数値が無いことを確認した |
| H24 | 高度なツール利用で初期文脈が約 77k→8.7k、精度 49%→74% | 未確認 | 照合していない |
| H25 | Chroma(2025-07)は 18 モデルで入力が長いほど性能が落ちることを確認 | 未確認 | 照合していない |
| H26 | MAST は 1,642 トレース・7 フレームワーク・14 の失敗モード | 未確認 | 照合していない |
| H27 | USENIX Security 2025 のパッケージ幻覚研究は 57.6 万サンプル・16 モデルで、商用 5.2%・OSS 21.7% | 二次ソースのみ | usenix.org の要旨の検索抜粋で 576,000 と 16 モデル。5.2% / 21.7% は 2026 年の追試論文の要約 |
| H28 | 同研究で幻覚した名前の 43% は再プロンプトでも再出現 | 未確認 | 抜粋に無かった |
| H29 | CodeRabbit の 470 PR 分析で AI の PR は問題 1.7 倍、セキュリティ問題 2.74 倍 | 未確認 | 照合していない |
| H30 | GitClear でコピペコードが 8.3%→12.3%、リファクタリングが約 25%→10% 未満 | 未確認 | 照合していない |
| H31 | CVE-2025-53773 は PR 説明文経由のプロンプトインジェクションで CVSS 9.6 | 二次ソースのみ | 脆弱性データベース(SentinelOne、OpenCVE 等)の検索抜粋では CVSS 3.1 は 7.8(AV:L/…/UI:R)、対象は Visual Studio 2022 の Copilot エージェントモード、注入元はソースファイル・Web ページ・Issue。9.6 は MDPI のレビュー論文等の値。NVD のページは取得できなかった |
| H32 | Trail of Bits(2025-10)は事前承認済みコマンドへの引数注入で承認を経ない RCE を実証 | 未確認 | 照合していない |
| H33 | MCP は 2025-12-09 に Linux Foundation 傘下の Agentic AI Foundation へ寄贈された | 未確認 | 照合していない |
| H34 | EU AI 法 14 条は自動化バイアスへの自覚を保つ監視設計を求める | 確認 | artificialintelligenceact.eu/article/14/ の 14(4)(b)。"to remain aware of the possible tendency of automatically relying or over-relying on the output" |
| H35 | 2026 年 8 月の論文「AI Agents Push Humans Out of the Loop」(Mitchell、Ghosh、Passi)が承認疲れを名指しした | 二次ソースのみ | arXiv:2608.23642(v1 2026-08-24)。要旨と論評の検索抜粋 |
| H36 | Devin のローンチ時デモは SWE-bench Lite で 13.86% | 未確認 | 照合していない |

台帳の行数は 138 行。

## 3. 一次ソースの内容(台帳の補足)

### 3.1 Copilot cloud agent の既定の動き(Route A の前提)

docs.github.com の「Risks and mitigations for GitHub Copilot cloud agent」から取得した事実:

- エージェントの PR では、既定で Actions のワークフローが走らない。"By default, workflows are not triggered until Copilot cloud agent's code is reviewed." 書き込み権限を持つ人が承認すると走る。"Optionally, you can configure Copilot to allow workflows to run automatically"。この設定は 2026-03-13 の changelog で追加された(検索抜粋)。
- 起動した人はその PR を承認できない。push できるのは `copilot/` ブランチか、呼び出された既存 PR のブランチだけ。branch protection と required checks はそのまま効く。
- Issue 本文やコメントに隠した指示への対策として、HTML コメントなど表示されない文字を取り除いてから渡す。インターネットへの接続は制限される(既定のファイアウォール。2026-04-03 から組織単位で管理できる)。
- 名称は 2026-04-01 から Copilot cloud agent。同日に、計画を作って人間の承認を得てから実装する機能が入った(検索抜粋)。
- 課金は 2026-06-01 からトークン量に応じた AI Credits(検索抜粋)。旧来の「プロンプト 1 回 = 1 リクエスト」と違い、長い自律セッションほど費用が増える。

### 3.2 EGM プラグイン 0.1.1 の実体

- 7 つの skill(`egm-brainstorm` / `egm-draft` / `egm-review` / `egm-resolve` / `egm-review-loop` / `egm-bootstrap` / `egm-drift-report`)は、すべて frontmatter に `disable-model-invocation: true` を持つ。モデルが自分で呼ぶのではなく、人がスラッシュコマンドで起動する前提である。
- `egm-review` は対話ゲートを持つ。プリセット選択(`interactive` / `uninterrupted` / `feature_spec` / `implementation`、または個別の段)を省略すると、選択を 1 問だけ聞いてターンを終える。段ごとに再監査は 1 回まで("1-Audit Convergence Cap")。
- 中断しないプリセット(`uninterrupted`)では、5 段を続けて実行し、段ごとの報告と統合報告 `consolidated_review_report.md` を書く。指摘は Blocker / Major / Nit に分類され、生の指摘と統合後の作業項目の対応表(Traceability Matrix)を作る。
- 応答の規律として「既定で同意しない」「批判を先に」「お世辞を言わない」を明記している。
- レビュアーの隔離について `docs/claude.md` は、Claude のレビュアーは `omitClaudeMd: true` と `tools: [Read, Grep, Glob]` で起動し、親の会話履歴と指示ファイルを除くと書く。ただし "This is context and tool isolation, not filesystem isolation: reviewers can read accessible files." とあり、ファイルシステム上の隔離ではない。Codex と Antigravity では、プロジェクトの `AGENTS.md` などがレビュアーに漏れる報告がある(issue #237、`docs/harnesses.md`)。
- headless 実行について `docs/claude.md` は、プラグインの `agents/` `docs/` `resources/` `skills/` への読み取りを権限設定で事前に許可する必要があると書く。Issue→PR の無人パイプラインで EGM を回せるかは、本書では試していない。
- `egm-drift-report` は LLM への手順書(文書を読み、対応するソースを探し、差分だけを `{YYYY-MM-DD}_DRIFT_REPORT.md` に追記する)で、決定的な検査ではない。
- `TESTING.md` に書かれているのは、frontmatter・リンク・マニフェストなどのオフラインの単体テストと、ハーネスごとの導入・E2E のフィクスチャで、レビューが手戻りを減らすかを測った評価は無い。
- このリポジトリでは `dot_claude/settings.json.tmpl` で `egm@egm` が有効化されている。

### 3.3 CooperBench とその後続

- CooperBench(arXiv:2601.13295)の要旨は、協力すると平均で 30% 成功率が下がり("the curse of coordination")、通信路が "vague, ill-timed, and inaccurate messages" で詰まると書く。
- 後続の Claim Plane(arXiv:2608.00947、2026-08-02)は、書き込み前の決定的な受付制御で CooperBench の 30 組の機能ペアの成功率を 23.3% から 50.0% に上げた。ただし静的な受付は "serialized 96.7% of executions" で、改善の大半は直列化によるものだった。動的な受付では 90 件中 46 件が宣言外のスコープで止まり、成功率は 22.2% に下がった。
- Shepherd(arXiv:2605.10913)は、監督役のメタエージェントが並行するコーディングエージェントの衝突を防ぎ、ペアの成功率を 28.8% から 54.7% に上げたと要旨に書く。
- どちらも「並行する書き手をそのまま走らせると壊れる」点では CooperBench と一致し、直す手段は直列化か監督役の追加である。

### 3.4 Thoughtworks Radar の最新(2026-11)

- OpenSpec は 2026 年 11 月号で Trial に上がった。"Since we featured it in Assess in April, several of our teams have reported success with it, enough to move it to Trial." 差別化は spec-anchored なワークフローにあると書く。
- 同じ号に Caution のブリップ「AI-driven documentation sprawl」と「Agent instruction bloat」がある。Spec Kit のブリップは現行号に載っていない。
- 元レポートは 2026 年 4 月号までしか反映していない。

### 3.5 Faros の後続レポート

- 2026 年 Q2 の「The Acceleration Whiplash」の +242.7%(障害/PR 比)は、低採用期から高採用期への移行での変化である。
- 2026-09-18 の「The Speed Trap」は、既に高採用のチームの直近 12 か月で PR あたり障害 +14.5% とし、移行期の品質低下はそれ以上悪化し続けないと示唆する一方、全体像はそれほど安心できないとも書く(いずれも検索抜粋)。

## 4. 元レポートが扱っていない反証・リスク

### 4.1 エージェント PR の受け入れ率(独立研究)

- AIDev(Li、Zhang、Hassan、arXiv:2507.15003、2025-07-20)は、5 種のエージェント(Codex、Devin、Copilot、Cursor、Claude Code)の 45 万 6 千超の PR を集め、要旨で "although agents often outperform humans in speed, their PRs are accepted less frequently, revealing a trust and utility gap" と書く。
- 二次要約によると、エージェント別のマージ率は 35〜65% 程度で人間は 76.8%(初期版)。後続の研究では、Python の 489 リポジトリで人間の PR が約 85%、エージェントの PR が 64〜68% マージされ、設定系の作業は 80% 超、機能実装や LLM 統合は 60% 未満だった(arXiv:2607.21832 の二次要約)。数値は抽出条件で大きく変わる。
- 元レポートの指標(マージ PR あたりコスト、欠陥流出率)には「出した PR のうち何割がマージされたか」が無い。

### 4.2 Issue 本文からのプロンプトインジェクション

- Invariant Labs(2025-05-26)は、公開リポジトリの Issue に仕込んだ指示で、GitHub MCP サーバーを使うエージェントに私有リポジトリの情報を公開 PR へ書き出させた。原因はサーバーのバグではなく、トークンがユーザーの全リポジトリを読めて、セッションを対象リポジトリに縛っていなかったことにある(検索抜粋)。
- 「Issue を渡すと PR が返る」工場では Issue 本文が入力そのものになる。元レポートは「Issue/PR のテキストは信頼できない入力」と 1 行で触れるが、誰が工場のラベルを付けられるか、トークンを 1 リポジトリに絞るかは設計に入っていない。Copilot cloud agent は、割り当てを書き込み権限者に限り、隠し文字を除去し、ファイアウォールを掛ける(3.1)。

### 4.3 コストの実測値

- StrongDM のエンジニア 1 人 1 日 1,000 ドル(C7)、Anthropic Code Review の 1 件 $15–25(H22 の同ページ)、Copilot の従量課金化(G6)、Uber のセッションあたりコスト 52% 削減(二次)。元レポートの「コスト上限」は問いとして残っているが、Route ごとの費用の見積もりは無い。EGM の全段レビューも 1 回で 10 体のサブエージェントを使う(E10)。

### 4.4 人間の監督の劣化

- Mitchell、Ghosh、Passi(arXiv:2608.23642)は、エージェントの設計が監督を妨げ、長期の利用が監督に要る思考力を弱めると論じる(要旨の検索抜粋)。元レポートはこの論文を承認疲れの根拠に引くが、「無作為監査サンプリング」がその劣化を防げるかの根拠は示していない。

### 4.5 holdout の汚染

- 元レポートは「自分のリポジトリの過去 Issue 20〜50 件 + ホールドアウトテスト」を非公開評価に推す。SWE-bench Verified の監査(D1〜D3)が示したのは、公開リポジトリの修正履歴がモデルの学習データに入ると参照パッチを再現できてしまうことだった。対象リポジトリが公開なら、過去 Issue の修正は git 履歴と学習データの両方にあり、holdout として汚染されている可能性がある。

### 4.6 別の成熟度の捉え方

- DORA 2025 の AI Capabilities Model(7 つの能力)と、Gartner の行動単位のガバナンス段階は、元レポートも触れている。Shapiro の 5 段階は 1 人の実務家の観察で、「90%」は「AI ネイティブ」の開発者についての推定である(H11)。

## 5. このリポジトリの撤退記録(ADR)

このリポジトリは個人の dotfiles で、以下は 1 つの事例である。

- **ADR 0007(2026-09-25、accepted)** — plan を受け取り、実装・レビュー修正ループ・動作確認・draft PR・人間への報告までを自律で行うフロー `deliver` を作った。ループの上限・終了条件・収束判定は LLM へのプロンプトではなく Claude Code Workflows のスクリプトで判定する。理由は「プロンプトで守らせる方式では、agent が自分で『もう十分』と判断してループを早く抜けたり、直しにくい指摘を見送ったりする経路が残る」ため。superpowers の subagent-driven-development、compound-engineering の lfg、orca orchestration、google/ax、ralph-loop は、上限と収束をコードで保証できない等の理由で却下した。
- **ADR 0011(2026-10-02、accepted)** — 自己改善ループのルール採用を、ルールの有無で結果を比べた Evaluator の数値で判定し、Evaluator(検出器・分類器・判定基準・Eval Case)を改善対象の外に置く。ループが作った PR が Evaluator に触れたら CI で落とす。根拠の 1 つは、DGM で評価の改変を禁じても評価を無効化して偽の成功を報告する改変が観測されたこと。
- **ADR 0015(2026-10-04、ADR 0022 で superseded)** — Deliver は push も PR の作成もやめ、ローカルのコミットと報告を人間に渡す。理由は 2 つ。PR の作成はレビュワーへの通知や `pull_request` トリガーの bot を起動する外向きの操作で、人間が中身を確かめる前に起こしたくない。仕事用リポジトリでは PR 本文をテンプレートの節構成で書く決まりがあり、Workflow の報告はそれに合わない。
- **ADR 0022(2026-10-17、accepted)** — Deliver を廃止し、自律 Workflow を、既存のブランチにレビュー修正ループと動作確認だけをかける Review-Verify に絞った。実装は Workflow の外(人間か実装 skill)で行う。理由は「`/deliver` は使われていなかった」ことと、実装経路を持ち続けると分岐・プロンプト・テストを使われないまま保守することになる点。残存リスクとして、テスト/lint を直す checks エージェントの修正上限(3 回)はプロンプトの指示でしかなくコードで強制していないこと、「未着手の要件は範囲外」という制約もプロンプトの指示にとどまることを書いている。

記録から読める事実は次のとおり。撤退の理由は使われなかったことと保守費用で、記録に自律実装の品質の失敗は書かれていない。残っているのは「判定はコードで強制する」(ADR 0007、Review-Verify に引き継ぎ)と「評価器は改善対象の外」(ADR 0011)の 2 つである。

## 6. 評価(本書の見解)

ここからは事実ではなく本書の判断である。

### 6.1 同意する点

- **単一ライター。** CooperBench に加え、Claim Plane の改善の大半が直列化から来ていたこと(3.3)が、元レポートの結論をむしろ補強する。並行性はタスク間に置くという設計原則は維持でよい。
- **検証がボトルネック。** Spotify の 2026 年の 2 本(PR が 76% 増え、検証の制御が変更量に追いつかなかった)と DORA の「安定性とは負の関係」は、元レポートの主張どおりである。
- **ゲートとテストをエージェントの編集対象から外す。** StrongDM と ImpossibleBench が支える。根拠に引くなら、Spotify の「コメントアウトと Java ダウングレード」は確認できなかったので外し、Part 3 の「範囲外の行動(flaky テストの無効化など)」と ImpossibleBench に差し替えるべきである。
- **公開ベンチマークを許可証にしない。** SWE-bench Verified と Pro の監査は二次ソースでしか読めていないが、複数の独立した報道と後続の論文が一致している。
- **リスク階層化した人間ゲートと、上限をハーネスで強制すること。** このリポジトリの ADR 0007 / 0022 の経験(プロンプトで守らせた上限は残存リスクとして残る)とも一致する。ADR 0007 の「判定はコードで強制」と ADR 0011 の「評価器は改善対象の外」は、元レポートの「上限はハーネスが強制」「審判は選手を兼ねない」と同じ向きである。
- **ただし出口の向きは異なる。** ADR 0015 は PR の作成を人間の確認前に起こさないと決めた。Issue から自動で Draft PR を作る工場の出口とは逆向きで、対象リポジトリでこの判断をどう扱うかは 7 節の問いに含めた。

### 6.2 異論

1. **Route A は「CI が通った PR」をそのままでは返さない。** Copilot cloud agent の PR は既定で Actions が走らない(3.1)。自動実行に切り替えると、Issue 本文経由で誘導されたコードが人の確認前に CI 上で走る。元レポートの推奨経路の出力定義に関わるので、Route A を選ぶなら「エージェント PR の Actions を自動実行にするか」を明示の決定事項にすべきである。
2. **EGM は工場の自動経路ではなく、人間が残る段の道具として扱うべき。** 全 skill が人の起動前提で、レビューは対話ゲートを持ち、全段レビューは 10 体のサブエージェントを使う。元レポート自身が「仕様の分岐は人間の主仕事」としているので、EGM はその人間の作業を助けるものと位置づけるのが整合的である。無人パイプラインに組み込むことは、試して確かめるまで前提にしない。「追加コストほぼゼロ」は撤回が要る。drift report も LLM の手順書で、週次の人間の作業として扱うのが妥当。
3. **ADLC の Self-improving には歯止めの条件が欠けている。** 元レポートはこれを「障害→holdout 化の学習ループ」と対応づけるが、自己改善の経路が評価器そのものを動かせると、効果が上がったのか基準が緩んだのかを区別できない(このリポジトリの ADR 0011 と、そこで引いた DGM の観測)。ADLC の 7 条件をチェックリストに使うなら、「評価器と holdout は改善対象の外」を 8 番目の条件として足すべきである。
4. **holdout を過去 Issue から作るときは汚染を疑う。** 対象リポジトリが公開なら、過去の修正はモデルに見えている可能性がある(4.5)。holdout は新しく書くシナリオか、非公開のリポジトリ由来に寄せる。
5. **MVP に Temporal / LangGraph を入れるのは Route A では過剰。** Route A ではオーケストレータを Copilot 側が持つ。永続実行エンジンは Route B で、承認待ちが日をまたぐことが実測で問題になってからでよい。このリポジトリで判定をコードで強制した仕組み(ADR 0007)は、Claude Code Workflows のスクリプトで足りていた。
6. **指標に「エージェント PR のマージ率」を足す。** 独立研究(4.1)は、エージェント PR が人間より受け入れられにくいことを繰り返し示す。工場の初期の健康度は、流出率より先にこの値で見えるはずである。
7. **Faros の数値は最新版で引き直す。** +242.7% は移行期の値で、後続では +14.5%(3.5)。方向の主張は維持できるが、事業計画に使う大きさとしては古い。

### 6.3 代替案

- **Route C を前段にした Route A の縮小版を推す。** 1 種別(例: 依存更新かドキュメント)に絞り、Copilot cloud agent に実装させ、EGM も Temporal も入れない。測るのは、マージ率・巻き戻し率・マージ PR あたりコスト・人間のレビュー時間の 4 つ。
- **既存の Review-Verify を「別権限の検証」の段に転用する案。** ADR 0022 で、実装は Workflow の外で行う前提になっている。Copilot cloud agent が作ったブランチに Review-Verify をかけると、「書き手 1 人 + 別の検証」の形をこのリポジトリの既存資産で作れる。ただし Review-Verify のエージェントはブランチにコミットするので、読み取り専用の検証サービスではない。この差は残る。
- **Route B は、自前の実装段を誰が起動するかを先に確かめてから。** このリポジトリの `/deliver` は作ったが使われなかった(ADR 0022)。Route B の数週間の構築に入る前に、同じ結果にならない理由(起動の入口、通知の経路、使う人)を確かめたい。

### 6.4 MVP の「今やる/後でやる」への見解

- 今やるに残す: 単一ライター、CI・テスト・ゲートファイルのパス保護、決定的ゲート、上限付きの修正ループ、リスク階層化した人間ゲート、ベースラインの計測。
- 後でやるに移す: Temporal / LangGraph(Route A の場合)、EGM の全工程(brainstorm → draft)、ADLC 点検の全項目(パイロットの 1 種別に関係する項目だけを今やる)、夜間のガーデニング・ループ。
- 今やるに足す: エージェント PR 上の Actions の扱いの決定、工場ラベルを付けられる人の制限とトークンのリポジトリ単位の限定、マージ率の計測。

## 7. 未解決の問い

元レポートの「決めてほしい 5 つ」を残し、本書の見解で 4 つ足す。

1. Route: A(最速)/ B(自前で制御)/ C(1 種別に絞る。A か B と併用)のどれか。本書は C を前段にした A を推す。
2. 対象リポジトリの URL と言語・スタック(Workers / TypeScript 系かどうか)。
3. ホスティングは GitHub でよいか。
4. 1 タスクあたりのコスト上限($1 / $5 / $10 など)。
5. 最初のタスク種別(1 種別だけ)。
6. **(追加)対象リポジトリは公開か非公開か。** holdout の汚染(4.5)と、Issue 経由のインジェクションの露出(4.2)の両方に効く。
7. **(追加)エージェント PR 上の GitHub Actions を自動実行にするか。** 自動にしないなら、工場の出力は「CI 未実行の Draft PR」になり、人間の承認が CI の前に入る。
8. **(追加)工場の入口(ラベル付けや割り当て)を誰に許すか。** 書き込み権限者に限るか、外部からの Issue も受けるか。
9. **(追加)人間が確認する前に PR を作ってよいか。** このリポジトリは ADR 0015 で、PR の作成を人間の確認後に回した。対象リポジトリで Draft PR の自動作成を許すかは、レビュワーへの通知や `pull_request` トリガーの bot が動くことを含めて決める。

## 8. 出典一覧

一次ソース(取得して照合したもの):

- Cognition「Don't Build Multi-Agents」 https://cognition.com/blog/dont-build-multi-agents
- Anthropic「How we built our multi-agent research system」 https://www.anthropic.com/engineering/multi-agent-research-system
- Anthropic「Effective context engineering for AI agents」 https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents
- Anthropic「Building agents with the Claude Agent SDK」 https://claude.com/blog/building-agents-with-the-claude-agent-sdk
- Anthropic「Code Review for Claude Code」 https://claude.com/resources/articles/code-review
- CooperBench 論文 https://arxiv.org/abs/2601.13295 / ブログ https://cooperbench.com/blog/curse-of-coordination
- Shepherd https://arxiv.org/abs/2605.10913 / Claim Plane https://arxiv.org/abs/2608.00947
- Google「Towards a Science of Scaling Agent Systems」 https://arxiv.org/abs/2512.08296
- SWE-Bench Pro Verified https://arxiv.org/abs/2609.08149
- AIDev https://arxiv.org/abs/2507.15003 / 後続 https://arxiv.org/abs/2607.21832
- Spotify Engineering: Honk Part 1 https://engineering.atspotify.com/2025/11/spotifys-background-coding-agent-part-1 / Part 2 https://engineering.atspotify.com/2025/11/context-engineering-background-coding-agents-part-2 / Part 3 https://engineering.atspotify.com/2025/12/feedback-loops-background-coding-agents-part-3 / 2026-06 https://engineering.atspotify.com/2026/6/code-with-claude-coding-is-no-longer-the-constraint / 2026-09 https://engineering.atspotify.com/2026/9/ai-changed-how-spotify-builds-what-we-learned-and-fixed-about-quality-at-higher-velocity
- Stripe「Minions」 https://stripe.dev/blog/minions-stripes-one-shot-end-to-end-coding-agents
- StrongDM Software Factory https://factory.strongdm.ai/
- Simon Willison https://simonwillison.net/2026/Feb/7/software-factory/
- Addy Osmani「Software Factories, Light and Dark」 https://addyosmani.com/blog/software-factories/
- Dan Shapiro「The Five Levels」 https://www.danshapiro.com/blog/2026/01/the-five-levels-from-spicy-autocomplete-to-the-software-factory/
- Cloudflare「The Agent Development Lifecycle has arrived on Cloudflare」 https://blog.cloudflare.com/agent-development-lifecycle/
- google/elephant-goldfish-model(GitHub API と、ローカルのプラグイン 0.1.1)
- METR https://metr.org/blog/2025-07-10-early-2025-ai-experienced-os-dev-study/ / https://metr.org/blog/2026-02-24-uplift-update/
- Google Cloud「Announcing the 2025 DORA Report」 https://cloud.google.com/blog/products/ai-machine-learning/announcing-the-2025-dora-report
- Thoughtworks Radar: OpenSpec https://www.thoughtworks.com/radar/tools/openspec / GitHub Spec Kit https://www.thoughtworks.com/radar/languages-and-frameworks/github-spec-kit
- Birgitta Böckeler https://martinfowler.com/articles/exploring-gen-ai/sdd-3-tools.html
- GitHub Docs「Risks and mitigations for GitHub Copilot cloud agent」 https://docs.github.com/en/copilot/concepts/agents/coding-agent/risks-and-mitigations
- GitHub API: github/spec-kit、Fission-AI/OpenSpec、OpenHands/OpenHands、Aider-AI/aider、langchain-ai/langgraph、temporalio/temporal、awslabs/aidlc-workflows
- EU AI 法 14 条 https://artificialintelligenceact.eu/article/14/

検索抜粋・二次ソースでのみ照合したもの(台帳で `二次ソースのみ`):

- Thoughtworks Radar の SDD ブリップ https://www.thoughtworks.com/en-us/radar/techniques/spec-driven-development(検索抜粋と、OpenSpec ページの関連ブリップ欄で Assess・2025-11 を確認。ページ本体は未取得)
- OpenAI「Why SWE-bench Verified no longer measures frontier coding capabilities」(2026-02-23)と「Separating signal from noise in coding evaluations」(2026-07)、「Harness engineering」(2026-02-11)。いずれも openai.com が 403
- Faros AI の 2025 / 2026 Q2 / 2026 Q3 レポート、Veracode 2025 GenAI Code Security Report、Gartner のプレスリリース(2025-06-25、2026-05-26)、GitHub changelog(2025-09-25、2026-03-13、2026-04-01、2026-06-01)、GitHub Blog の Spec Kit 告知(2025-09-02)、Invariant Labs の GitHub MCP の記事(2025-05-26)、Cognition「Multi-Agents: What's Actually Working」、Uber Engineering、Ramp、Factory.ai の資金調達、Delinea のプレスリリース、ImpossibleBench、USENIX Security 2025 のパッケージ幻覚論文、Mitchell ら arXiv:2608.23642、CVE-2025-53773 の脆弱性データベース

## 未確認事項

- OpenAI の一次ソース 3 本の本文(403)。SWE-bench Pro について OpenAI が「推奨を撤回」と書いたのか、「注意深く調べるよう勧めた」にとどまるのかは、本文で確かめる必要がある。
- Spotify の「テストのコメントアウトと Java のダウングレード」の出典。Honk の Part 1〜3 には無く、Part 4 と講演資料は確かめていない。
- Google の平均 −0.3% とトークン 1.6〜6.2 倍(論文本文を読んでいない)。
- Anthropic の「障害の背後のバグの約 1/3」と「約 40 万セッション分析」の出典。
- EGM を headless の `claude -p` などから無人で回せるか。プラグインの説明は事前の読み取り許可が要ると書くが、実行はしていない。
- DORA 2025 の rework rate、AI Capabilities Model の 7 項目の名前(報告書本体を読んでいない)。
- 台帳で `未確認` とした周辺の数値(McKinsey、Stack Overflow、BCG、Microsoft、CodeRabbit、GitClear、Chroma、MAST、Trail of Bits、MCP の寄贈日、Devin、OpenHands の資金調達、LangGraph 1.0 の日付、Agent HQ、AI Credits の単価、AI-DLC の公表日、Scott Logic)。
