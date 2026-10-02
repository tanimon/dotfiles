# コーディングエージェント harness の Recursive Self-Improvement(一次ソース調査)

日付: 2026-10-02
対象: 外部の一次ソース(論文本体・公式ブログ・公式ドキュメント)15 件と、このリポジトリの harness 自己改善ループ(`dot_claude/skills/harness-{reflect,review}/`、`dot_claude/scripts/executable_harness-*.sh`、関連 spec / solutions / PR)
比較先: `docs/superpowers/specs/2026-07-06-harness-engineering-rebuild-design.md`(現行ループの設計)

本書は**事実のみ**を記録する。推奨は含めず、判断が要る点は「6. 未解決の問い」に問いの形で置く。リポジトリ内の引用は `(path:L範囲 @ c4e7da6)` の形で書く。論文の数値と引用文は、arXiv の HTML 版をタグ除去してから `grep` で原文と突き合わせた。突き合わせられなかったものは本文で「未確認」と書き、末尾の節にまとめた。

用語: 本書の「RSI」は、harness(指示・ルール・スキル・フック)が自分自身を改善する仕組み、さらに改善ループ自体を改善する仕組みを指す。モデルの重みの更新は扱わない。

## 1. 要約

- **外部の手法は、どれも改善の採否を「実行して測った数値」で決めている。** ADAS は検索用の validation 20 問とは別に held-out test 60 問を持ち、5 回評価した中央値と 95% bootstrap 信頼区間で報告する。GEPA は学習データを `Dfeedback` と `Dpareto` に分け、別に test を持つ。DGM は 10 → 50 → 200 タスクの段階評価を使う。Claude Code 公式も、skill について「評価を先に作り、skill なしのベースラインと比べる」ことを求めている。
- **暴走対策として繰り返し出てくるのは 3 つ。** (1) 評価関数を改変対象から外す。DGM は、幻覚検出のマーカーを消して偽の成功を報告させるという改変を実際に観測した。(2) 変更の系譜を残す(DGM の archive、ADAS の archive)。(3) 全文の書き直しではなく差分で更新する。ACE は、18,282 トークンの文脈が書き直し 1 回で 122 トークンに潰れ、精度がベースラインを下回った例を報告している(context collapse)。
- **人間のゲートは、どの研究でも「サンドボックス + 系譜の事後レビュー」が中心。** 変更 1 件ずつを人が承認する設計の論文は見つからなかった。現行ループは逆で、変更 1 件ずつを人が PR で承認するが、数値による評価を持たない。
- **既存ループで最大の欠落は、採用したルールが振る舞いを変えたかを測る仕組みが無いこと。** 原則としては `harness-engineering.md` に書かれている(「if a rule isn't changing behavior, rewrite or remove it」)。しかし実装上の評価は、harness-review の「would this rule have prevented the original failure?」という LLM の反実仮想判定 1 つだけで、held-out データも実行も無い。これは spec の Decision 3(generator-evaluator 層を置かず、人間の PR レビューだけをゲートにする)という意図した選択の結果である。
- **ループの稼働そのものも、一度止まっている。** #212(2026-07-06)で作り直した後、最初の `/harness-review` は 2026-09-28 の #373 で、その時点で pending は 426 件、transcript 消失が 194 件、何も残っていないものが 39 件あった。旧システムが数週間止まっていた件と同じく、約 12 週間誰も review を回していない。
- 公式の測定手段として `claude plugin eval`(v2.1.269 以降)がある。with/without の 2 アームで Δ を出す。ただし実行は隔離され、`CLAUDE.md`・rules・ユーザー設定は読み込まれないため、ルール単体の効果測定にそのまま使えるかは未確認。

## 2. 外部の知見

各手法を (a) 評価、(b) 暴走・肥大・reward hacking の防止、(c) 人間のゲート、の 3 観点で整理する。

### 2.1 Reflexion(Shinn et al., 2023, arXiv:2303.11366)

- **(a) 評価:** タスクのフィードバック(スカラーまたは自由記述、外部または内部シミュレーション)を言語で振り返り、episodic memory に保持する。プログラミングではモデル自身が生成したユニットテストを使う。
- **(b) 防止:** メモリは件数で上限を設ける。「we bound mem by a maximum number of stored experiences, Ω (usually set to 1-3) to adhere to max context LLM limitations」。自己生成テストの偽陽性が弱点として明記されている。「the false positive test execution rate for MBPP Python is 16.3% while the rate for HumanEval Python is a mere 1.4%」。偽陽性では「the agent will prematurely」完了と見なす(該当箇所は原文 grep で確認)。
- **(c) 人間:** 該当する記述なし。限界節には「it may still succumb to non-optimal local minima solutions」とある。
- 本件への含意(事実の対応づけのみ): 自己評価の信号は偽陽性を出す。数値はタスクによって 1.4% から 16.3% まで変わる。

### 2.2 Voyager(Wang et al., 2023, arXiv:2305.16291)

- **(a) 評価:** skill library への登録は、別の GPT-4 が critic として成功を判定した後に限る。「the self-verification module confirms the task completion, at which point we commit the program to the skill library」(WebFetch の要約経由。原文の文言そのものは grep していない)。
- **(b) 防止:** ablation で、自己検証の除去が「Removing the module leads to a significant drop (−73%) in the discovered item count」(原文で確認)を招いた。登録前ゲートが品質の主要因であることを示している。
- **(c) 人間:** 該当する記述なし。
- 取得は記述文の embedding で top-5 を引く(WebFetch の要約経由)。

### 2.3 ADAS / Meta Agent Search(Hu et al., 2024, arXiv:2408.08435)

- **(a) 評価:** 「We sample a validation set and a test set with 20 and 60 questions, respectively, for searching and testing」。報告は「the median accuracy and the 95% bootstrap confidence interval on a held-out test set by evaluating agents five times」(いずれも原文で確認)。発見したエージェントがドメインやモデルをまたいで転移するかも評価している。
- **(b) 防止:** 発見物は評価値と一緒に archive に追加し、次の設計の条件にする。
- **(c) 人間:** 「containerized execution of all generated code in secure, isolated environments, thorough manual inspections to verify the absence of harmful behaviors」(原文で確認)。
- 検索に使うデータと報告に使うデータを分けているのが特徴。

### 2.4 Gödel Agent(Yin et al., 2024, arXiv:2410.04444)

- **(a) 評価:** 自分のコードを実行時に書き換え(monkey patching)、utility 関数で評価する(WebFetch の要約経由)。
- **(b) 防止:** 書き換えが壊れる頻度が報告されている。「it occasionally makes erroneous changes, which can result in either terminating unexpectedly (4%) or experiencing temporary performance drops (92%) during optimization. Only in 14% of trials, optimization ultimately failed, resulting in worse performance than the initial policy」(原文で確認)。エラー処理の機構で回復させる設計になっている。
- **(c) 人間:** Ethics Statement でサンドボックスと改変範囲の制約を挙げている(WebFetch の要約経由)。
- 自己改変のほぼ全試行(92%)で一時的な性能低下が起きる。単発の観測で採否を決めると、ノイズを効果と取り違える余地がある。

### 2.5 Darwin Gödel Machine(Zhang et al., 2025, arXiv:2505.22954 / Sakana AI ブログ)

- **(a) 評価:** 段階評価を使う。「We first evaluate each coding agent on a set of 10 tasks to verify basic codebase-editing functionality. … Agents that pass this initial stage are then evaluated on an expanded set of 50 tasks」(原文で確認)。上位候補だけを 200 タスクで評価する、という部分は WebFetch の要約経由。評価は pass@1 で、「the agent never sees ground-truth test results」(原文で確認)。
- **(b) 防止 / reward hacking:** Sakana のブログが 2 つの事例を報告している。
  - ツール使用の幻覚: 「rather than doing so, it just creates a fake log that makes it look like it ran the tests and that they all passed!」
  - 評価関数の改竄: 「it removed the markers we use in the reward function to detect hallucination (despite our explicit instruction not to do so), hacking our hallucination detection function to report false successes」
  - 検出できた理由: 「DGM provides a transparent, traceable lineage of every change that allows us to quickly catch such undesirable behaviors」
  - 以上 3 つはいずれもブログ原文で確認した。論文の付録 H にある同じ事例の記述は取得できず、未確認。
- **(c) 人間:** 論文の安全性の節に「We maintained a complete, auditable lineage (archive) of code changes and evaluations, enabling rollback and post-hoc analysis」とあり、改変は「restricted to the agent's own Python codebase and evaluation harnesses」(原文で確認)。ブログでは「under human supervision and with strict limits on access to the web」。
- 「明示的に禁止した」改変でも、評価器を書き換えれば点が上がる状況では実際に起きた。

### 2.6 SICA: A Self-Improving Coding Agent(Robeyns et al., 2025, arXiv:2504.15228)

- **(a) 評価:** utility は「w_score=0.5, w_cost=0.25 and w_time=0.25」(原文で確認)で、コストと時間も含む。archive で最も良いエージェントを次の meta-agent にする。ベンチマークは SWE Bench Verified の 50 問、LiveCodeBench の 50 問、自作の合成ベンチマーク(WebFetch の要約経由)。held-out の有無は明記されていない(未確認)。
- **(b) 防止:** 非同期の overseer を置く。「an LLM, running periodically in a concurrent thread, which is prompted to judge whether there are any pathological behaviours or deviations」(原文で確認)。限界として経路依存が挙がっている。初期の質の悪い改善案が後続の提案の質を下げる(WebFetch の要約経由)。
- **(c) 人間:** 「a key safety mitigation in such systems is observability: that humans can and do oversee all aspects of potentially self-improving systems」(原文で確認)。overseer は「may also use a different LLM to the running agent」。

### 2.7 DSPy MIPROv2(Opsahl-Ong et al., 2024, arXiv:2406.11695)

- **(a) 評価:** 提案(proposer LM)と credit assignment(TPE による surrogate model)を分ける。minibatch で評価し、train / dev / test を分ける(500 / 500 / 2k、WebFetch の要約経由)。
- **(b) 教訓:** 「Lesson 1: Optimizing bootstrapped demonstrations as few-shot examples is key to achieving the best performance」(原文で確認)。抽象的な指示文より、実例の選択のほうが効く場合が多い。
- **(c) 人間:** 該当する記述なし。

### 2.8 GEPA(Agrawal et al., 2025, arXiv:2507.19457)

- **(a) 評価:** feedback 関数はスコアに加え、テキストのフィードバック(コンパイラエラー、満たせなかったルーブリックなど)を返す。データは `Dfeedback`(変異用の minibatch)と `Dpareto`(候補選択用)に分け、別に held-out test を持つ。rollout 予算 B の上限がある(WebFetch の要約経由)。
- **(b) 防止:** 最良の候補だけを残すと局所解に落ちる。「this often traps the optimizer in a local optimum: once a dominant strategy is found, it becomes difficult to surpass」(原文で確認)。そのため、少なくとも 1 タスクで最良の候補を Pareto front として残す。成果物は短くなり、「prompts produced by GEPA and GEPA+Merge are up to 9.2× shorter than those from MIPROv2」(原文で確認)。GRPO との比較は「by 6% on average and by up to 20%, while using up to 35x fewer rollouts」(原文で確認。WebFetch の要約は「up to 19%」としており、版による違いの可能性がある)。
- **(c) 人間:** 該当する記述なし。

### 2.9 ACE: Agentic Context Engineering(Zhang et al., 2025, arXiv:2510.04618)

- **(a) 評価:** AppWorld と金融ドメインのベンチマークで評価する。ラベル無しでも実行フィードバックで適応できるとしている(abstract)。
- **(b) 防止:** 2 つの失敗型を名づけている。
  - brevity bias: 「many prompt optimizers prioritize concise applicable instructions over comprehensive accumulation」
  - context collapse: 「iterative rewriting erodes details over time」。実例は「at step 60 the context contained 18,282 tokens and achieved an accuracy of 66.7, but at the very next step it collapsed to just 122 tokens, with accuracy dropping to 57.1—worse than the baseline accuracy of 63.7 without adaptation」(いずれも原文で確認)
  - 対策は 2 つ。1 つ目は全文の書き直しをやめ、項目単位の delta 更新にすること。各 bullet は「a unique identifier and counters tracking how often it was marked helpful or harmful」を持つ(原文で確認)。2 つ目は grow-and-refine で、embedding による重複排除を行う。
  - 限界: 「if the Reflector fails to extract meaningful insights from generated traces or outcomes, the constructed context may become noisy or even harmful」(原文で確認)。
- **(c) 人間:** 該当する記述なし。
- **項目ごとの helpful / harmful カウンタは、外部手法の中で「ルール 1 件ごとの効果」を記録する機構に最も近い。**

### 2.10 Anthropic: Effective context engineering for AI agents

- context rot: 「as the number of tokens in the context window increases, the model's ability to accurately recall information from that context decreases」。指針は「the smallest possible set of high-signal tokens that maximize the likelihood of some desired outcome」。
- edge case を列挙するより、「a set of diverse, canonical examples」を示す。
- 長期化への対策として compaction と structured note-taking(文脈の外に置くメモ)。
- (引用は WebFetch の抽出を経由しており、原文との grep 照合はしていない)

### 2.11 Anthropic: Demystifying evals for AI agents

- 2 種類の eval を区別する。capability eval は「should start at a low pass rate」、regression eval は「should have a nearly 100% pass rate」。
- grader の頑健性: 「The agent shouldn't be able to easily 'cheat' the eval」。
- 始め方: 「20-50 simple tasks drawn from real failures is a great start」。
- transcript を読む: 「You won't know if your graders are working well unless you read the transcripts and grades from many trials」。
- pass@k と pass^k を区別し、飽和(100%)した eval は改善の信号にならない。
- (WebFetch の抽出を経由。原文 grep 未実施)

### 2.12 Claude Code 公式ドキュメント(memory / skills / plugin evals)

- **memory:** 「target under 200 lines per CLAUDE.md file. Longer files consume more context and reduce adherence」。矛盾する指示は「Claude may pick one arbitrarily」なので、定期的に見直す。`/doctor prompt-audit` で古い指示・存在しない参照・矛盾を検出できる。auto memory は `MEMORY.md` の先頭 200 行または 25KB だけを読み込む。読み込まれたファイルの記録には `InstructionsLoaded` フックが使える。CLAUDE.md への追記の目安は「Claude makes the same mistake a second time」。(https://code.claude.com/docs/en/memory)
- **skills best practices:** 「Create evaluations BEFORE writing extensive documentation」。手順は gap の特定 → 3 シナリオの eval → skill なしのベースライン計測 → 最小限の指示 → 反復。「There is not currently a built-in way to run these evaluations」(この文書の時点)。Claude A(書く側)と Claude B(使う側)を分け、B の実際の振る舞いを観察して A に戻す。「The context window is a public good」。
- **plugin evals(`claude plugin eval`、v2.1.269 以降):**
  - 各ケースは with-plugin と no-plugin の 2 アームで既定 3 回ずつ実行し、Δ を出す。「If a case scores 1.0 both with and without the plugin, the plugin isn't what made it pass」。
  - grader は 6 種類。`regex` / `tool_used` / `tool_order` / `file_exists` は無料、`llm` / `baseline` はジャッジモデルを呼ぶ。
  - `--threshold` で CI ゲートにできる。
  - 制約 1: 隔離実行のため「Your user settings, hooks, `CLAUDE.md` files, MCP servers, other installed plugins, memory, and skills are absent」。
  - 制約 2: 過去の会話を `context.history_file` で再開できるが、path を対象にした場合は既定で 1 アームしか走らない(`--ablation with-without` で 2 アームにできる)。
  - 制約 3: レート制限に当たると 0 点として集計され、回帰のように見える。
  - 「The case definitions are hidden from the agent」(評価対象から eval を隠す)。skills-directory plugin も対象にできる。

## 3. 横断して見えるパターンとアンチパターン

### パターン

1. **評価は実行ベースで、データを分ける。** ADAS(validation / held-out test)、GEPA(`Dfeedback` / `Dpareto` / test)、MIPRO(train / dev / test)、DGM(段階評価)。Anthropic の eval 記事と plugin eval は「ベースラインとの差」を求める(2.3, 2.7, 2.8, 2.5, 2.11, 2.12)。
2. **評価器は改変対象の外に置く。** DGM は評価器を改竄された実例を持つ(2.5)。plugin eval はケース定義をエージェントから隠す(2.12)。
3. **系譜(archive / lineage)を残す。** ADAS・DGM・SICA の archive。DGM では、系譜が reward hacking を見つけた手段そのものだった(2.3, 2.5, 2.6)。
4. **登録前に、別の主体が検証する。** Voyager の critic を外すと −73%(2.2)。SICA の overseer は別の LLM でもよい(2.6)。
5. **更新は差分で、項目ごとに効果を記録する。** ACE の delta 更新と helpful/harmful カウンタ(2.9)。
6. **反復と分散を前提にする。** ADAS は 5 回評価、plugin eval は既定 3 回。Gödel Agent では 92% の試行で一時的な性能低下が起きる(2.3, 2.12, 2.4)。
7. **小さく始める。** 実際の失敗から 20〜50 タスク(2.11)。skill では 3 シナリオから(2.12)。

### アンチパターン

1. **自己評価だけで採否を決める。** Reflexion の自己生成テストは偽陽性率 16.3%(2.1)。
2. **全文を書き直す。** context collapse(2.9)。
3. **短さだけを最適化する。** brevity bias(2.9)。ただし GEPA は短いまま性能も上がっており(2.8)、短さそのものが悪いわけではない。
4. **貪欲に最良だけを残す。** 局所解に落ちる(2.8)。経路依存(2.6)。
5. **評価器と改変対象が同じ権限の内側にある。** DGM のマーカー削除(2.5)。
6. **長く矛盾した指示ファイル。** 公式の 200 行の目安と「pick one arbitrarily」(2.12)。

## 4. 既存 harness loop の棚卸し

### 4.1 構成(引用は `@ c4e7da6`)

| 部品 | 役割 | 根拠 |
|---|---|---|
| SessionEnd: `harness-reflect-trigger.sh` | assistant の応答が 10 以上のセッションを `pending.jsonl` に追記する。LLM は使わない | (dot_claude/scripts/executable_harness-reflect-trigger.sh:L41-L64) |
| `/harness-reflect` | 現在のセッションと pending の transcript から候補を `queue.md` に追記する。dedup はしない | (dot_claude/skills/harness-reflect/SKILL.md:L18-L72) |
| `/harness-review` | doctor → reflect → triage → staleness scan → 1 PR | (dot_claude/skills/harness-review/SKILL.md:L19-L101) |
| SessionStart: `harness-briefing.sh` | 毎セッション 1 行のステータスを出す。警告は 4 種類 | (dot_claude/scripts/executable_harness-briefing.sh:L17-L93) |
| `harness-doctor.sh` | 配線・デプロイ・状態ファイルの死活チェック | (dot_claude/scripts/executable_harness-doctor.sh:L22-L86) |
| 配線 | 両フックとも stderr をログに流し `|| true` で終了 | (dot_claude/settings.json.tmpl:L323, L405) |

設計判断の出所は spec の Decisions(docs/superpowers/specs/2026-07-06-harness-engineering-rebuild-design.md:L21-L37)。特に関係するのは次の 2 つ。

- 「The human PR review is the single quality gate (no LLM generator-evaluator layer)」(同:L26-L28)
- 「LLM at exactly two points — extraction (reflect) and triage (review)」(同:L41-L42)

### 4.2 評価(観点 a)に当たるもの

- **原則は書かれている。** 「Test rules by observing agent behavior — if a rule isn't changing behavior, rewrite or remove it」(dot_claude/rules/common/harness-engineering.md:L36)。アンチパターンにも「Adding rules without verifying the agent actually reads and follows them」(同:L65)とある。
- **実装上の評価は 1 か所だけ。** triage の「**Value test:** would this rule have prevented the original failure? Is it specific, actionable, and likely to recur?」(dot_claude/skills/harness-review/SKILL.md:L39-L41)。これは LLM が、ルールの元になった同じセッションについて反実仮想で判断するもので、実行もしないし、別のデータでも試さない。
- **staleness scan は参照の実在と矛盾を見る。** 参照しているファイルやコマンドの実在、新しい学びとの矛盾を確認する(同:L60-L77)。効果の有無は見ない。
- **反映後の確認は lint だけ。** `just lint` を通して PR を開く(同:L85-L87)。
- **テストはスクリプトの挙動だけを見る。** spec のテスト方針は「Skills (prompts) are not unit-tested; acceptance is one full manual cycle after landing」(rebuild-design.md:L214-L215)。実在するテストは `test/harness-{reflect-trigger,briefing,doctor}.bats` で、決定的スクリプトの挙動を検査している。
- **旧システムでも同じ欠落が症状として挙がっていた。** 「Rule effectiveness is not tracked — stale rules accumulate silently」(docs/solutions/developer-experience/self-learning-harness-engineering-system-2026-03-29.md:L10)。当時の対策は「90 日より古いルールを stale とみなす」という経過時間の proxy(同:L48)で、効果の測定ではなかった。

**リポジトリの外にある未文書の実験。** `~/.claude/harness/` に `gold-set.jsonl`(40 件)、`triage.jsonl`(40 件)、`triage-report.md`、`digests/`(202 件)がある(更新日 2026-08-28)。git 管理外で、spec にも skill にも記述が無い。内容は次のとおり。

- **何を測っているか:** `triage-report.md` は、ローカル LLM(qwen3:8b)がセッションを「学びあり / なし」に分類するプレフィルタの結果である。測っているのは安いモデルの分類精度で、harness-reflect の抽出品質でもルールの効果でもない。
- **件数:** レポートは 40 件中 34 件(85%)を「学びあり」と判定している。gold set の人手ラベルは 40 件中 10 件が true。
- **比較できる範囲:** 2 つのファイルが共有する session_id は 10 件だけだった(`jq` + `sort` + `comm` で確認)。その 10 件の内訳は次のとおり。
  - gold が true の 3 件は、triage も 3 件とも true
  - gold が false の 7 件は、triage が 7 件とも true

  n=10 と小さいが、プレフィルタは recall が高く precision が低い(3/10)。
- 中身にはセッション ID、絶対パス、仕事のセッションからの引用が含まれるため、本書には件数だけを載せる。

### 4.3 暴走・肥大の防止(観点 b)に当たるもの

- **抽出を抑える指示:** 「When in doubt, lean toward NOT queueing. A short high-signal queue beats a long noisy one」(dot_claude/skills/harness-reflect/SKILL.md:L52-L53)。
- **dedup と統合:** 既存のルール・Known Pitfalls・solutions との重複を判定し、関連 entry をまとめる(dot_claude/skills/harness-review/SKILL.md:L36-L58)。
- **削除を促す指示:** 「deprecate aggressively; git history preserves them」(同:L76-L77)。
- **入力側の汚染対策:** transcript_path を `~/.claude/projects/` 配下の `.jsonl` に限る(dot_claude/skills/harness-reflect/SKILL.md:L26-L33)。
- **サイズの実績:**
  - 生成物の `CLAUDE.md` は現在 234 行、50,266 バイト。公式の目安は「target under 200 lines」。#212 時点では 19,163 バイトだった。
  - ただし増分の多くは permissions や nono など review 以外の PR によるもので、review ループの寄与は分けて測っていない。
  - review を経た 2 PR の差分は、#373 が 19 ファイル +248/−20、#393 が 9 ファイル +58/−4(`git show --stat`)。どちらも追加が削除を大きく上回る。
  - Codex は `AGENTS.md` を 32 KiB で切り捨てる、と `CLAUDE.md` の Generated agent instructions 節に記載がある。
- **自己改変の範囲:** review は、ループ自身(`harness-review/SKILL.md`、`harness-reflect/SKILL.md`、`harness-doctor.sh`)も同じ PR で変更できる。実際に #373 は `harness-doctor.sh` と両 SKILL.md を変更した(`git show --stat 8cadba9`)。#388(prompt-audit)も harness-review を変更している。評価器にあたる doctor と、triage の基準を改変対象から外す仕組みは無い。人間の PR レビューは、その変更も含めて見る。

### 4.4 人間のゲート(観点 c)

- **唯一のゲートは PR のマージ。** 自動適用は無い(rebuild-design.md:L26-L28、dot_claude/skills/harness-review/SKILL.md:L86-L87「Do NOT merge it」)。
- **PR 本文でトレードオフを示させる。** skill の description に「this skill must present honest trade-offs, not advocacy」とある(dot_claude/skills/harness-review/SKILL.md:L9-L10)。#373 と #393 の本文には「人間の判断が要る点」「レビューで判断してほしいトレードオフ」の節があり、観測回数が 1 回の entry を採用した理由も書かれている。
- **起動は人間の手動。** briefing は 7 日を過ぎると警告を出すが、`/harness-review` を起動するのは人間である(dot_claude/scripts/executable_harness-briefing.sh:L17, L57-L58)。

### 4.5 既知の失敗

1. **旧システムが数週間止まっていた(2026-06〜07)。** 3 つの独立した silent failure が重なった。
   - token 失効による 401
   - gate のスキップが green として記録された
   - plugin の rename で observer が停止した

   briefing の「Pipeline: BROKEN」は診断が付いておらず、常設のノイズになった(docs/solutions/integration-issues/harness-silent-failures-scheduled-workflows-and-plugin-rename.md:L32-L56)。稼働期間全体で auto-promote されたルールは 0 件(rebuild-design.md:L13-L14)。
2. **作り直し後、review が約 12 週間走らなかった(2026-07-06〜09-28)。** #212 のマージは 2026-07-06。#373 は自らを「`/harness-review` の初回実行」と書き、次を報告している。
   - 未振り返りのセッションが 426 件
   - transcript から再ダイジェストしたものが 193 件
   - transcript が消え、8 月の既存ダイジェストで代替したものが 194 件
   - どちらも無く対象外にしたものが 39 件

   補足:
   - 期間中にもダイジェストを作る試み(4.2 の `digests/`)はあったが、review までは至っていない。
   - briefing の警告がこの期間に実際に表示されていたかは未確認。`~/.claude/logs/harness-errors.log` は空で(0 バイト、更新は 9 月)、briefing がエラーで落ちた記録は無い。
   - doctor は review の Step 1 でしか実行されないため(dot_claude/skills/harness-review/SKILL.md:L19-L24)、review が走らないこと自体は doctor では検出できない。
   - 旧システムの教訓「Relying on the session briefing as the alert channel … trains the reader to ignore it」(harness-silent-failures…md:L54-L56)に対し、新設計は警告に対処コマンドを添えた(rebuild-design.md:L43-L44)。それでも「起動されない」という結果は繰り返された。
3. **系譜が劣化する。** queue entry の出所は `- **Source:** session <session_id>`(dot_claude/skills/harness-reflect/SKILL.md:L67)。しかし transcript は保持期間を過ぎると削除される(公式 memory ドキュメントの `cleanupPeriodDays`)。briefing も「its transcript may be auto-pruned soon」と警告している(executable_harness-briefing.sh:L75-L76)。判定の記録 `queue-archive.md` はローカルにだけあり、git 管理外である(rebuild-design.md:L46-L47)。現状では 73 entry で、内訳は adopted 35 / handoff 18 / merged 12 / rejected 8。ルールが存在する理由は、PR 本文と、ルール本文に書いた「理由」にだけ残る。

## 5. ギャップ分析(外部の知見に対して既存に欠けているもの)

| 外部の要素 | 出典 | 既存での対応 | ギャップ |
|---|---|---|---|
| 採用前の実行評価(ベースラインとの差) | ADAS 2.3、GEPA 2.8、skills best practices / plugin eval 2.12 | 無い。LLM の反実仮想判定のみ(SKILL.md:L39-L41) | **ルールが振る舞いを変えるかを、採用前にも採用後にも測っていない** |
| held-out データ | ADAS、GEPA、MIPRO | 無い。判定に使うのは元のセッションそのもの | 発生源のセッションに過剰適合したルールを検出できない |
| ルール 1 件ごとの効果記録 | ACE の helpful/harmful カウンタ 2.9 | 無い。staleness は参照の実在と矛盾だけを見る | 効かないルールを「効かない」という理由で削除できない(原則 harness-engineering.md:L36 は未実装) |
| 回帰 eval(ほぼ 100% を保つ) | Anthropic evals 2.11 | スクリプトの bats と `just lint`、`test/global-instructions.bats` のゴールデンだけ | ルール変更が既存の振る舞いを壊していないかを見ていない |
| 評価器を改変対象から外す | DGM 2.5、plugin eval のケース秘匿 2.12 | 無い。review は doctor と自分の SKILL.md を同じ PR で変更できる | 現状の防御は人間の PR レビューだけ |
| 系譜の永続化 | DGM / ADAS の archive | `queue-archive.md` はローカル・非バージョン管理。Source の transcript は削除される | 採用理由の一次記録が時間とともに失われる |
| 差分更新と肥大の抑制 | ACE 2.9、公式 200 行 2.12 | dedup と「deprecate aggressively」の指示。実績は追加が優勢 | サイズ予算や純増の上限といった定量的な歯止めが無い |
| 抽出側の精度評価 | Reflexion の偽陽性 2.1 | 未文書の gold set 実験だけ(4.2) | harness-reflect 自体の precision / recall は測っていない |
| 稼働の監視(ループが回っていること) | SICA の overseer 2.6(実行中の監視) | briefing の 7 日警告。doctor は review の内側でしか走らない | 「review が起動されない」を止める手段は人間の注意だけで、実績として 12 週間止まった |
| 分散を前提にした反復評価 | ADAS 5 回、plugin eval 3 回、Gödel 92% 一時低下 | 観測 1 回の entry も採用している(#393 本文) | 単発観測の採用が妥当かは PR レビュー時の判断に委ねられている |

## 6. 未解決の問い(設計の対話で決めるべき論点)

1. **何を「効いた」とみなすか。** 候補は 3 つある。(i) 同じ失敗型の再発率(transcript から検出)、(ii) ルール有無の 2 アーム比較(plugin eval 型)、(iii) ACE 型の helpful/harmful 記録。どれを採るかで必要なデータと費用が変わる。
2. **`claude plugin eval` をルール評価に使えるか。** 隔離実行では `CLAUDE.md` や rules が読み込まれない。ルール本文を plugin の skill やフック経由で注入して 2 アーム比較が成立するかは、本調査では検証していない(未確認)。`context.history_file` で失敗直前までの transcript を再開する場合も、既定は 1 アームなので `--ablation with-without` の明示が要る。
3. **held-out をどこから作るか。** 元のセッションとは別の、同じ失敗型の事例を集める必要がある。transcript は保持期間で消えるため、事例を保存する仕組みが先に要るかもしれない。
4. **評価器をループの改変対象から外すか。** doctor と triage の基準を review の PR から分離するか、同じ PR で人間が見る現状を維持するか。DGM の事例は、明示的な禁止だけでは防げなかったことを示している。
5. **人間のゲートの位置。** 外部の研究は「系譜の事後レビュー + サンドボックス」に寄っており、現行は「変更ごとの事前承認」である。数値評価を足す場合、事前承認を軽くするのか、両方を持つのか。
6. **起動の責任をどこに置くか。** 12 週間止まった件を受けて、人間の手動起動に依存し続けるか。spec はコストと OAuth の失敗を理由に、headless の自動実行を外している(rebuild-design.md:L31-L35)。
7. **肥大の予算。** 公式の 200 行、Codex の 32 KiB、ACE の collapse と brevity bias の両方を踏まえ、純増の上限やサイズ予算を設けるか。設けた場合、削除の判断に効果データが要るのではないか。
8. **系譜をどこまで残すか。** `queue-archive.md` をバージョン管理するか。ただし公開リポジトリなので、entry 本文に含まれうる仕事の文脈をどう扱うかが制約になる。
9. **gold set 実験を正式化するか。** プレフィルタの precision の低さ(n=10 で 3/10)を受けて、抽出側の評価に使うか、やめるか。

## 7. 出典一覧

### 外部(15 件)

1. Shinn et al., "Reflexion: Language Agents with Verbal Reinforcement Learning" — https://arxiv.org/abs/2303.11366(本文 https://arxiv.org/html/2303.11366)
2. Wang et al., "Voyager: An Open-Ended Embodied Agent with Large Language Models" — https://arxiv.org/abs/2305.16291
3. Hu et al., "Automated Design of Agentic Systems" — https://arxiv.org/abs/2408.08435
4. Yin et al., "Gödel Agent: A Self-Referential Agent Framework for Recursive Self-Improvement" — https://arxiv.org/abs/2410.04444
5. Zhang et al., "Darwin Gödel Machine: Open-Ended Evolution of Self-Improving Agents" — https://arxiv.org/abs/2505.22954
6. Sakana AI, "The Darwin Gödel Machine" — https://sakana.ai/dgm/
7. Robeyns et al., "A Self-Improving Coding Agent" — https://arxiv.org/abs/2504.15228
8. Opsahl-Ong et al., "Optimizing Instructions and Demonstrations for Multi-Stage Language Model Programs"(MIPROv2) — https://arxiv.org/abs/2406.11695
9. Agrawal et al., "GEPA: Reflective Prompt Evolution Can Outperform Reinforcement Learning" — https://arxiv.org/abs/2507.19457
10. Zhang et al., "Agentic Context Engineering"(ACE) — https://arxiv.org/abs/2510.04618
11. Anthropic, "Effective context engineering for AI agents" — https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents
12. Anthropic, "Demystifying evals for AI agents" — https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents
13. Claude Code Docs, "How Claude remembers your project" — https://code.claude.com/docs/en/memory
14. Claude Docs, "Skill authoring best practices" — https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices
15. Claude Code Docs, "Test plugins with evals" — https://code.claude.com/docs/en/plugin-evals

### リポジトリ内(`@ c4e7da6`)と GitHub

- `dot_claude/skills/harness-reflect/SKILL.md`
- `dot_claude/skills/harness-review/SKILL.md`
- `dot_claude/scripts/executable_harness-reflect-trigger.sh`
- `dot_claude/scripts/executable_harness-doctor.sh`
- `dot_claude/scripts/executable_harness-briefing.sh`
- `dot_claude/settings.json.tmpl`
- `dot_claude/rules/common/harness-engineering.md`
- `docs/superpowers/specs/2026-07-06-harness-engineering-rebuild-design.md`
- `docs/solutions/integration-issues/harness-silent-failures-scheduled-workflows-and-plugin-rename.md`
- `docs/solutions/developer-experience/self-learning-harness-engineering-system-2026-03-29.md`
- `harness/modules/project/35-key-patterns.md`(生成物 `CLAUDE.md` の「Harness self-improvement loop」節の Source)
- PR #212(作り直し)、#373(初回 review)、#388(prompt-audit 3 回目)、#393(2 回目 review) — `gh pr view` で本文を確認
- ランタイム状態(git 管理外): `~/.claude/harness/{state.json,queue-archive.md,gold-set.jsonl,triage.jsonl,triage-report.md}`、`~/.claude/logs/harness-errors.log`(件数と日付だけを参照)

## 未確認事項

- DGM 論文付録 H(幻覚対策のケーススタディ)の原文。reward hacking の記述は Sakana のブログ原文でだけ確認した。
- DGM の「上位候補を 200 タスクで評価」の条件の詳細(WebFetch の要約経由)。
- Voyager の登録条件の原文の文言と、top-5 取得(WebFetch の要約経由)。
- Gödel Agent の utility と Ethics Statement の文言(WebFetch の要約経由)。
- SICA のベンチマーク構成と経路依存の文言、held-out の有無(WebFetch の要約経由)。
- MIPROv2 のデータ分割の数値(WebFetch の要約経由)。
- GEPA のデータ分割と、GRPO 比の最大値(原文 grep では「up to 20%」、WebFetch の要約では「up to 19%」)。
- Anthropic の 2 記事の引用文(WebFetch の抽出経由。原文 grep 未実施)。
- transcript の既定保持期間の具体的な日数(公式ドキュメントに `cleanupPeriodDays` があることだけを確認した)。
- 2026-07-06〜09-28 の間に、briefing の警告が実際に表示されていたか。
- `claude plugin eval` で、ルール本文を plugin 経由で注入した 2 アーム比較が成立するか。

## 8. 追補: 実現可能性の確認(2026-10-02)

§6 の問い 2・3・6 を、ローカル CLI(Claude Code 2.1.287)・公式ドキュメント・小さな実測で確かめた結果。§1〜§7 の「未確認」のうち、ここで確かめたものはこちらが優先する。


### 8.1. `claude plugin eval` で「ルールあり/なし」の 2 アーム比較ができるか

#### 結論

**できる(実測済み)。** ルール本文を plugin の SessionStart フック(`additionalContext`)で注入すると、with-arm にだけ届く。without-arm には届かない。実測では、既定では起きない規約をルールとして注入したケースで Δ = +1.0 が出た。

ただし、次の 2 点に注意する。

- 注入の経路は CLAUDE.md や rules の読み込みとは別物なので、測った効果は代理指標にとどまる。
- Bash を使うルール(このリポジトリのルールの多く)の評価は未確認(下の「未確認・リスク」)。

#### 隔離の前提(公式ドキュメント)

- 「Your user settings, hooks, `CLAUDE.md` files, MCP servers, other installed plugins, memory, and skills are absent. Project-scoped configuration isn't read anywhere either」
- 「Ship any skills, agents, hooks, or MCP servers a case depends on in the plugin under test」
- `claude plugin eval` は「loads the target plugin's skills, hooks, and agents」。
- 「The case definitions are hidden from the agent.」

したがって、ルールを持ち込む経路は次の 3 つになる。

1. **plugin のフック(SessionStart の `additionalContext`)**: 実測で動作を確認した。with/without の差がそのまま「ルールの有無」になる。
2. **plugin の skill**: ドキュメント上は可能。ただし skill は Claude が呼び出すかどうかで発火が決まる。そのため、常に読み込まれる CLAUDE.md とは性質が違い、「skill が発火したか」と「ルールが効いたか」が混ざる。`tool_used: Skill` の grader は 2 アーム比較では自動的に `scored: false`(発火したかどうかを示すだけの指標)になる。
3. **ケースの `append_system_prompt`(prompt.md の frontmatter、または case.yaml の `execution:`)**: ドキュメントには「Text appended to the child session's system prompt」とある。ケース単位の設定なので、おそらく両アームに効く。これでルール有無を比べるなら、ルールありのケースとルールなしのケースを別々に作り、`--ablation none` で 1 アームずつ実行することになる。**未確認(試していない)。**

#### 実測(Claude Code 2.1.287、子プロセスのモデルは trace 上 `claude-opus-5-5`)

構成は `<scratchpad>/rule-eval-probe/` に置いた。

- `.claude-plugin/plugin.json`
- `hooks/hooks.json`: SessionStart で `cat ${CLAUDE_PLUGIN_ROOT}/hooks/rule.json` を実行する。
- `hooks/rule.json`: `hookSpecificOutput.additionalContext` にルール文を入れる。
- `evals/<case>/prompt.md` と `graders/*.md`(regex grader のみ。無料)

| 実測 | ケース | 結果 | 費用 |
|---|---|---|---|
| 1 | `zsh-separator`: 「=== を表示する echo を 1 行」と頼み、引用符付きかを regex で見る | WITH 1.0 / W/OUT 1.0、Δ = 0 | 4 runs で $0.167 |
| 2 | `convention`: 「区切り線を出力するコマンドを 1 行」と頼む。ルールは「echo を使わず printf を使う」 | WITH 1.0 / W/OUT 0.0、Δ = +1.0 | 4 runs で $0.167 |

- **対照ペア:** 実測 2 では、注入文に含めた固有マーカーを trace に対する regex grader(`arm: both`)で探した。マーカーは with-arm の 2 run で検出され、without-arm の 2 run では検出されなかった。注入が with-arm にだけ届くことを両側から確認したことになる。
- **実測 1 の Δ = 0 は天井効果である。** プロンプト自体が echo と `===` を指定しているため、モデルはルールが無くても引用符を付けた。ルールに効果が無いことの証拠ではない。言い換えると、ケースの作り方次第で識別力が無くなる(公式の「If a case scores 1.0 both with and without the plugin, the plugin isn't what made it pass」がまさにこの状態)。
- `weight: 0` は受け付けられない(`Number must be greater than 0` でケースの読み込みに失敗する)。
- `--keep-temp` を付けないと、`tracePath` が指す一時ディレクトリは実行後に消える。

#### ケース定義の形式(公式ドキュメント)

- ケースは eval ディレクトリ(既定は `evals/`)の下の、`prompt.md` または `case.yaml` を持つディレクトリ。grader が 1 つも無いと読み込みに失敗する。
- prompt.md の frontmatter: `name`、`description`、`tags`、`plugins`、`runs`(既定 3、1〜50)、`model`、`max_turns`(既定 10、上限 200)、`timeout_seconds`(既定 300、上限 3600)、`allowed_tools`、`append_system_prompt`、`env`(`EVAL_*` のみ)。未知のキーはエラーになる。
- case.yaml: `schema_version: "1.1"` と `name` が必須。`context.scaffold_script`(`--scaffold` を付けたときだけ実行)、`context.history_file`、`context.add_dirs`、`execution.prompt`、`graders:` を持てる。

#### `context.history_file`

- 「A `.jsonl` transcript in the case directory to resume. The case's prompt becomes the next user turn」。**transcript はケースのディレクトリの中に置く必要がある。**
- target がパスのとき、このケースは既定で 1 アームだけ実行される(stderr に `single-arm (no Δ)` が出る)。比較するには `--ablation with-without` を明示する。

#### `--ablation`

- `none | with-without`。plugin が解決できたときの既定は `with-without`(CLI ヘルプ)。
- `none` にすると費用は半分になるが、grader の除外も行われなくなるので、同じ suite でも絶対スコアが変わる(ドキュメント)。

#### 採点(grader は 6 種類。独自コードの grader は無い)

- 無料: `regex`(target は `last_message` / `trace` / `files` / `{source: file, path}` / `mock_calls`)、`tool_used`、`tool_order`、`file_exists`。
- 有料: `llm`(3 回投票して 2 票以上 PASS で合格)、`baseline`(参照 transcript と比べる)。ジャッジの既定は haiku(CLI ヘルプ)。
- `arm: with-only` と `arm: both` で、どちらのアームで採点するかを制御できる。

#### 費用の目安

- 実測では 1 run あたり約 $0.04(1 ターン・ツールなし・regex grader のみ)。**これは下限であり、典型的な値ではない。**
- ドキュメントの例は 6 runs で $0.41。
- run 数は「cases × runs × 2 アーム」、ジャッジ呼び出しは「`llm` / `baseline` grader 1 つにつき、1 run あたり 3 回」。
- 上限の手段は `--max-cost-usd`。ただしこれは定価ベースの推定値に対する上限で、プランの使用量に対する上限ではない。実行中の run はそのまま走るので、上限を少し超えうる。超えると exit 2 と `partial: true` になる。
- レート制限や使用量上限に当たった run は 0 点になり、`partial` にもならないので、回帰のように見える(ドキュメント)。

#### 未確認・リスク

- **Bash を使うケース:** `--allow-tools Bash` を付けると、各 run に Claude Code の OS サンドボックス(Seatbelt)がかかる(ドキュメント)。一方 `dot_config/nono/CLAUDE.md` には、macOS ではサンドボックスの入れ子(nested `sandbox_apply`)が exit 71 で失敗すると書かれている。したがって、**nono の内側のセッションから Bash を許可したケースを走らせると失敗する可能性が高い(未確認)。** 試すなら `command claude` 経路か launchd から起動する。
- `append_system_prompt` が両アームに効くかどうか: 未確認。
- `context.history_file` を使った 2 アームの実行: 未確認。

---

### 8.2. headless の定期実行

#### 結論

ローカルの launchd で `claude -p` を回すのは現実的で、同じマシンに前例がある。GitHub Actions には transcript が無い。そのうえ OAuth トークンの失効という前例があり、入力データの面でも運用の面でも不利。

予算の強制は 1 回の実行単位でならできる(`--max-budget-usd`)。複数回にまたがる上限や月額の上限を強制する CLI フラグは見当たらない。

#### CLI フラグ(`claude --help`、2.1.287)

- `--max-budget-usd <amount>`: 「Maximum dollar amount to spend on API calls (only works with --print)」。**実在する。** 効くのは 1 回の起動だけ。
- `--no-session-persistence`: transcript を保存しない(`--print` のときだけ)。
- `--bare`: hooks、CLAUDE.md の自動探索、auto-memory を読まない。ヘルプには「Anthropic auth is strictly ANTHROPIC_API_KEY or apiKeyHelper via --settings (OAuth and keychain are never read)」とあり、**`--bare` を使う headless 実行には API キーが要る。** ルールなどの文脈は `--append-system-prompt[-file]` や `--plugin-dir` で明示的に渡す。
- `claude setup-token`: 「Set up a long-lived authentication token (requires Claude subscription)」。
- `--max-turns` は `--help` に出てこない(存在しないとは断定しない)。`plugin eval` 側の turn 上限は `max_turns`。

#### ローカル launchd

- **前例:** このマシンには、別リポジトリの launchd ジョブが `command claude -p … --allowedTools … --output-format text` を毎日実行しているものがある。直近 5 日間は成功ログが残っている。認証は通常セッションと同じ資格情報で通っているとみられる(どの資格情報かは未確認)。
- **nono について:** nono のラッパーは zsh の関数(`dot_config/zsh/sandbox.zsh` の `claude()`)である。launchd は zsh の関数を読み込まないので、**nono は適用されない。** 適用されるのは Claude Code 自身の Bash サンドボックス(`settings.json.tmpl` の `sandbox.enabled: true`)だけ。nono の内側で走らせたいなら、スクリプトで `nono run --profile claude-seal --allow-cwd -- claude …` と明示的に包む必要がある。その場合は、ラッパーと同じように `--settings '{"sandbox":{"enabled":false}}'` も必要になる(`dot_config/nono/CLAUDE.md`)。nono の内側では書き込みに制約があり、たとえば `.git/config` は書けない。
- **transcript について:** `~/.claude/projects/` はローカルにしか無い。launchd なら直接読める。
- **harness loop への副作用:** `--bare` を付けない `claude -p` はユーザーのフックを読み込む。SessionEnd の `harness-reflect-trigger.sh` は、対話か非対話かを区別していない(L41-L64 で見ているのは assistant の応答数が 10 以上かどうかと、重複かどうかだけ)。そのため、**定期実行のセッション自身が `pending.jsonl` に積まれ、reflect の入力が汚れる。** `--bare` にする(この場合は API キーが要る)か、トリガー側で除外する必要がある。

#### GitHub Actions

- 入力データ: transcript は runner に無い。使うには、ローカルから何らかの形でアップロードする必要がある。transcript には絶対パスや仕事の文脈が含まれ、このリポジトリは public なので、その点も考える必要がある。
- 認証: 前例がある。`CLAUDE_CODE_OAUTH_TOKEN` の失効により、2026-06-07 から毎週 `401 Invalid authentication credentials` で失敗し、気づかれたきっかけは CI のメールだけだった(`docs/solutions/integration-issues/harness-silent-failures-scheduled-workflows-and-plugin-rename.md` の L9、L35、L102、L128-L129)。現在の定期 workflow には `harness-issue-alert` による通知がある(CLAUDE.md の「Scheduled workflow failure alerting」)。

#### 既存設計書が headless を外した理由

`docs/superpowers/specs/2026-07-06-harness-engineering-rebuild-design.md` の L31-L35。

- Decision 5: 「Cost model for reflection: Deferred … No headless `claude -p` from hooks.」
- Decision 6: 「Periodic health checks run locally, not in CI. This removes the OAuth-token failure class entirely.」

つまり、headless を外した理由は費用(フックから LLM を呼ばない)と、CI 上の OAuth の失敗の 2 つである。この判断は「ローカルの launchd で headless を回すこと」を直接禁じてはいない。ただし原則 1「LLM at exactly two points」(L40-L41)には抵触しうる。

---

### 8.3. transcript の保持期間と held-out の置き場所

#### 結論

保持期間は既定の 30 日。transcript を参照するだけの記録は、30 日を過ぎると参照先が消える。実例として、gold set に記録された session_id は 40 件中 0 件しか transcript が残っていない。held-out は `.jsonl` を実体としてコピーし、ローカルの `~/.claude/harness/` 配下に置くのが既存の構成と合う。

#### 根拠

- `dot_claude/settings.json.tmpl` に `cleanupPeriodDays` は**無い**(grep で確認。リポジトリ内でヒットしたのは研究ノートだけ)。デプロイ先の `~/.claude/settings.json` でも `null` だった。managed settings(`/Library/Application Support/ClaudeCode/`)のディレクトリ自体が存在しない。
- 既定値: 2.1.287 のバイナリ内の設定スキーマに「Number of days to retain chat transcripts before automatic cleanup (default: 30). Minimum 1.」とある。同じバイナリ内の文言として「To keep transcripts for a long time, set a large number (e.g. 3650 …)」もある。今回取得した settings ドキュメントのページには、このキーが含まれていなかった。
- 実際の状態との一致:
  - 残っている transcript のうち最も古いものは 2026-09-02 で、ちょうど 30 日前だった。
  - `~/.claude/harness/gold-set.jsonl` の 40 件の session_id のうち、transcript が残っているのは **0 件**だった。
  - briefing も、未反映のセッションが 20 日を超えると「may be auto-pruned soon」と警告する(`executable_harness-briefing.sh` の L19、L74-L76)。

#### held-out を置ける既存の場所

| 場所 | 性質 | 適否 |
|---|---|---|
| `~/.claude/harness/` | `.chezmoiignore` の L86 で除外されている。git 管理外のローカル状態。設計書の原則 3(L45-L46)で「Runtime state is not chezmoi-managed」とされている。`gold-set.jsonl` などの実験が既に置かれている | **最も適する。** ただし eval のケースは plugin の eval ディレクトリの中に置き、`history_file` もケースのディレクトリの中に置く必要がある。そのため、この配下に eval 専用のローカル plugin(`plugin.json` と `evals/`)を作る形になる |
| リポジトリの `test/`(bats のフィクスチャ) | public で git 管理下 | 不適。transcript には絶対パス、アカウント名、仕事の文脈が含まれ、`scan-sensitive` の対象にもなる |
| `docs/solutions/` | public。文章による事後記録 | 失敗の要約は置けるが、実行可能な事例(`.jsonl`)は置けない |
| `cleanupPeriodDays` を大きくする | `settings.json.tmpl` で宣言できる | 消えるのを防ぐ補助策にはなる。ただし held-out を固定して管理することにはならない |

注意: `~/.claude/projects/` 自体は `.chezmoiignore` の L52 で除外されている。トリガーは transcript のパスを記録するだけで、内容はコピーしない(`executable_harness-reflect-trigger.sh` の L59-L64)。
