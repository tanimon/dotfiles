# software factory の実践例は Human Touchpoint をどう消しているか(一次ソース調査)

日付: 2026-11-11
問い: #648(親: #645)
入口: [tanimon/software-factory-engineering の日次ダイジェスト](https://github.com/tanimon/software-factory-engineering/tree/main/docs/digest)(2026-08-13〜2026-11-11 の 76 ファイル、377 項目の見出しを流し読みし、関係する約 70 項目を選んだ)
対象: ダイジェストからたどった実践例・公式ドキュメント・論文・事故報告の一次ソース約 50 件と、このリポジトリの nono・Command Guard・Review-Verify・Loop PR / 週次ジョブ

本書は事実を記録する。推奨はしない。#645 への含意は「7. 所見」に分け、#645 の Out of scope(条件付きの auto-merge、AI が自分で課題を見つけて着手すること)に当たる実践は、事実として載せたうえで「範囲外」と印を付ける。

## 0. 読み方

### 確認の度合い

ダイジェストは二次資料なので、引用はすべて元の文書までたどった。各主張の確認の度合いを次の 3 つで書き分ける。

- **原文**: 元の文書の本文を取得し(GitHub は `gh api .../contents`、Web は curl で取得してタグを除去)、引用文や数値を文字列で照合した。
- **要約経由**: WebFetch の要約モデルの出力だけで、本文の文字列とは照合していない。
- **ダイジェストのみ**: 元の文書を取得できなかった。

特に断らない引用は **原文** である。

### 6 つの Human Touchpoint

`GLOSSARY.md` には Human Touchpoint の項がまだ無い(この worktree と origin/main の両方で確認)。本書では #648 の本文に従い、次の 6 つを指す。

| Touchpoint | 本書での意味 |
|---|---|
| 着手 | 仕事をエージェントに渡し、実行を始めさせる |
| 権限 | 実行中のコマンドやツールの承認 |
| 途中の質問 | 実行中に要件や判断を人に聞く |
| 実装 | コードを書く |
| PR の作成 | push と PR を開くこと |
| 通知 | 完了・行き詰まり・失敗を人に戻す |

## 1. 要約

- **人に残る Touchpoint は、ほぼ全例で「着手(キューに入れる)」と「マージ」の 2 つに寄っている。** 個人の夜間ループ(nightly Ralph loop)、SIS、islo、Stripe Minions、GitHub Copilot cloud agent はいずれも、人がラベルなどでキューに入れ、人がマージする。これは #645 の Destination と同じ形である。人のマージを外した例(StrongDM、Pullboard、Kiro と Electric Twin の一部の自動マージ)もあるが、#645 の範囲外である。
- **あいまいさへの対処は、止まる位置で 3 つに分かれる。** (a) 着手の前にまとめて聞く(Fabrika、AI-DLC、HumanLayer の lights-on、Review-Verify)。(b) 実行中に聞くが、人ではなく上位のエージェントに先に聞く(Pullboard、Agent Scrum、Kiro、Oskar Groth)。(c) 人に聞くときは 1 件にまとめ、推奨の答えを付け、ラベルを付けて止まる(nightly Ralph loop、SIS)。「仮定を置いて進めて PR に書く」を既定にした例は見つからなかった。近いのは、決定を Linear に記録する Electric Twin と、spec に「誰も確かめていない仮定」の節を置く Fabrika である。
- **仮定で進めた失敗例はある。** OpenAI の社内エージェントは「メッセージを送るな」という指示を、監視アラートを止めてよいという意味に読んだ。islo では、合わない設計に固執したまま、テストは通るが筋の悪いコードが出てきた。HumanLayer は、人がコードを読まない運用を 2025 年 7 月から続けた末に、作り直しに追い込まれた。逆に、止まりすぎる側の失敗も記録がある。Groth が自分のメッセージ 488 件を調べると、本当の承認は約 8 件に 1 件しかなく、約 3 分の 2 は仕組みが処理すべきものだった。Kiro は、質問のたびに自動化が止まることを問題にした。
- **人間不在の承認は、4 つの層を重ねて置き換えている。** (1) 隔離の境界(Stripe は devbox の中で確認を全部省く。VM、使い捨てのサーバー)。(2) 決定的な許可リストと拒否リスト(マージ・force push・公開・秘密の読み取りを `deny` にする)。(3) 書き込み経路を 1 つに絞る(SIS の git-broker、Copilot の単一ブランチ)。(4) 事後のレビュー(人のマージ、承認の抜き取り、ログの定期レビュー)。LLM の分類器(auto mode)は (2) の代わりにはならない、という指摘が繰り返し出る。Latacora の指摘、赤チーム評価の 79%、Embrace The Red の 60〜80% がそれである。
- **headless では「承認を求める」が「拒否」になる。** Claude Code の公式ドキュメントでも、このリポジトリの #429 でも同じである。実践例はこれを利用して、プロンプトではなく権限の層でマージや公開を塞いでいる(nightly Ralph loop、lights-on の regulator)。この形は、このリポジトリの Command Guard と週次ジョブの「push と PR の作成はスクリプトが固定の引数で行う」に対応する。

## 2. 調べた実践例

| 実践例 | 誰が・規模 | 形 | 出典 |
|---|---|---|---|
| nightly Ralph loop | 個人(Peter Vanhee)、13 日で PR 82 件・マージ 74 件 | `ready` ラベルの issue → 夜間に headless `claude -p` → PR。マージは本人 | [cloudwired.dev](https://cloudwired.dev/notes/the-nightly-ralph-loop) |
| SIS | OSS(MIT)、チーム向け | `sis` ラベルの Jira チケット → サンドボックス → draft PR | [README](https://github.com/sis-factory/sis-factory)、[docs/handling.md](https://github.com/sis-factory/sis-factory/blob/main/docs/handling.md)、[docs/security.md](https://github.com/sis-factory/sis-factory/blob/main/docs/security.md)、[docs/review-loop.md](https://github.com/sis-factory/sis-factory/blob/main/docs/review-loop.md) |
| Instant Software Factory | OSS のブートストラップ(Claude Code routines) | 8 ロールの定期実行。マージは人の承認の後 | [README](https://github.com/mikolalysenko/instant-factory)、[BOOTSTRAP.md](https://github.com/mikolalysenko/instant-factory/blob/main/BOOTSTRAP.md)、論文 [arXiv:2610.36254](https://arxiv.org/abs/2610.36254v1) |
| lights-on boilerplate | OSS(Votito の構成が元) | コンテナ + Bash の regulator(PreToolUse)+ 決定的な orchestrator | [README](https://github.com/gojko/lights-on-software-factory)、[REGULATOR.md](https://github.com/gojko/lights-on-software-factory/blob/master/REGULATOR.md) |
| Pullboard | OSS | 人が承認した SPEC の行 → builder / verifier / coordinator。検証を通れば main に入る | [README](https://github.com/pullboard-dev/pullboard) |
| Fabrika | OSS(alpha) | 確認項目の承認 → spec の凍結 → 最終パケットのマージ判断 | [tatiyants.com/fabrika](https://tatiyants.com/fabrika/) |
| AI-DLC | AWS Labs | 5 フェーズ・33 ステージ。各ステージの終わりに承認ゲート | [README](https://github.com/awslabs/aidlc-workflows)、[07-interaction-modes.md](https://github.com/awslabs/aidlc-workflows/blob/main/docs/guide/07-interaction-modes.md) |
| HumanLayer | スタートアップ | 人がコードを読まない運用から、人がコードを読む運用へ戻した | [wsff.md](https://github.com/humanlayer/advanced-context-engineering-for-coding-agents/blob/main/wsff.md) |
| Oskar Groth | 1 人の会社(Cindori)、2 週間で PR 478 件(1 製品) | orchestrator が lane の owner に配り、人に聞くものを列挙して絞る | [oskargroth.com](https://oskargroth.com/blog/orchestrating-agents) |
| Agent Scrum | 個人の作業論文、38 日で 324 スプリント | PO 役のエージェントが計画し、scrum team のエージェントが実行する | [daveremy.github.io/agent-scrum](https://daveremy.github.io/agent-scrum/) |
| Kiro | Kiro Crew のチーム(エンジニア 3 人)、週 1,000 PR | 単一の PR Readiness シグナル、tier ごとの自動承認、conductor エージェント | [kiro.dev](https://kiro.dev/blog/software-factory-stability/) |
| Electric Twin | 専任エンジニア 1 名、13 週で 564 PR | レビューパネルが 83% を人なしで通す。6 件に 1 件ほどを人に回す | [electrictwin.com](https://www.electrictwin.com/blog/software-factory) |
| islo | スタートアップ | Linear のラベル → 実装 → 独立したレビューと動作確認 → 人が承認 | [islo.dev](https://islo.dev/blog/how-we-stopped-working-for-our-agents/) |
| Stripe Minions | Stripe、週 1,300 PR 超 | 隔離された devbox で確認を省き、人がレビューする | [stripe.dev](https://stripe.dev/blog/minions-stripes-one-shot-end-to-end-coding-agents-part-2) |
| GitHub Copilot cloud agent | GitHub の製品 | issue / PR から起動し、`copilot/` ブランチにだけ push する | [Risks and mitigations](https://docs.github.com/en/copilot/concepts/agents/coding-agent/risks-and-mitigations) |
| Anthropic | 社内、マージされるコードの約 80% を Claude が書く | コードベースをリスクで階層化し、承認を抜き取って人が見る | [claude.com/blog](https://claude.com/blog/how-anthropic-secures-its-ai-native-software-development-lifecycle) |
| OpenAI | 社内(Pragmatic Engineer の取材。有料記事の無料部分だけを確認) | 変更をリスクで分類し、低リスクは自動承認を opt-in する | [newsletter.pragmaticengineer.com](https://newsletter.pragmaticengineer.com/p/openai-software-factory) |
| StrongDM | 社内 | 「Code must not be reviewed by humans」 | [factory.strongdm.ai](https://factory.strongdm.ai) |
| Incredibuild | 社内、Bazel に upstream パッチ 6 件 | goal → … → レビューできる PR。マージの権限は人に残す | [incredibuild.com](https://www.incredibuild.com/blog/bazel-contributions-security-fix-autonomous-sdlc) |
| exe.dev | 社内 | 通知する cron を、diff とボタンを出すボットに置き換えた | [blog.exe.dev](https://blog.exe.dev/cron-vs-vm) |
| Cortex engrams | 社内 OSS | durable workflow(DBOS)の mailbox で人の返事を待つ | [builders.cortex.io](https://builders.cortex.io/blog/software-factory-automations/) |
| Jake Saunders | 個人の自宅サーバー | 使い捨てのサーバーで被害範囲を限る | [blog.jakesaunders.dev](https://blog.jakesaunders.dev/building-an-almost-fully-self-hosted-sandboxed-agentic-software-factory/) |

設計論として Addy Osmani([addyosmani.com](https://addyosmani.com/blog/software-factories/))、Latacora([latacora.com](https://www.latacora.com/blog/2026/09/18/fire-the-slop-cannons-safely-on-coding-agents-and-sandboxing/))、Firecrawl の整理([firecrawl.dev](https://www.firecrawl.dev/blog/ai-software-factory)。Stripe・Spotify・Shopify・Ramp の比較表を含む二次資料)、Will Larson([lethain.com](https://lethain.com/software-factory-experiment/))、Google の harness 評価([developers.googleblog.com](https://developers.googleblog.com/the-anatomy-of-harness-engineering-how-to-evaluate-iterate-and-guard-ai-coding-agents/))も参照した。部品としては Pinrail([README](https://github.com/forgeplane/pinrail))、Foreman([README](https://github.com/thruwire/foreman))、Local Software Factory([README](https://github.com/stratonext/software-factory))を見た。Claude Code の権限の挙動は公式ドキュメント([permission-modes](https://code.claude.com/docs/en/permission-modes.md))と auto mode のブログ([claude.com/blog](https://claude.com/blog/auto-mode-default-in-claude-code))で確かめた。

## 3. 枝ごとの手法

各表の「このリポジトリ」の列では、`GLOSSARY.md` の語を使う。

### 3.1 着手

| 手法 | 誰が使っているか | 出典 | このリポジトリ |
|---|---|---|---|
| ラベルの付いた issue だけを拾う。他は見えない | nightly Ralph loop(`ready`)、SIS(`sis`)、islo(Linear のラベル)、Firecrawl の最小構成(`agent-ready`) | Ralph: 「An issue labelled ready is approved work; everything else is invisible to the loop.」 SIS: 「Label a Jira ticket `sis`. A coding agent picks it up」 islo: 「A human adds a label to a Linear ticket and the system takes it from there」 | 対応なし。`ready-for-agent` ラベルの issue はあるが(#645)、それを拾う経路は無い |
| 起動できる人を書き込み権限で絞る。権限の無い人のコメントはエージェントに渡さない | GitHub Copilot cloud agent、SIS | Copilot: 「Only users with write access to the repository can trigger Copilot cloud agent to work. Comments from users without write access are never presented to the agent.」 SIS: PR のフィードバックは `author_association` が OWNER / MEMBER / COLLABORATOR のものだけを数える | 対応なし(issue を入力にする経路が無い)。公開リポジトリなので、入れるなら同じ絞り込みが要る(4.2 の CSA の事故) |
| 時刻で起動する(timer + ポーリング)。予算が尽きたら止まる | nightly Ralph loop(systemd timer が 18:00 に起動し、30 分ごとにポーリング)、Agent Scrum(外部タイマー) | Ralph: 「A systemd timer starts the night at 18:00; a second one polls every 30 minutes」 | 週次ジョブ(launchd、土曜 10:00)が時刻起動の前例。ただし入力は issue ではなく pending の transcript |
| 着手の前に依存の順序を書く | nightly Ralph loop(`After #N`) | 「An `After #N` line in an issue body holds it back until #N is closed — added after a batch of refactor PRs collided on CLAUDE.md and README.md.」 | 対応なし |
| 着手の前に大きさで分類し、大きいものは設計を先に通す | Kiro、SIS(handling policy)、HumanLayer | Kiro: 「A simple change can be built directly, a medium level feature needs a one-page design, and a complicated one needs a review by the whole team.」 SIS: epic と feature は分割案を人が承認する。story と task は既定では直接 PR にする | Requirements Document(Review-Verify は要件文書が無いブランチを扱わない) |
| AI が自分で課題を見つけて起票する(**#645 の範囲外**) | Instant Software Factory、Electric Twin、OpenAI の Perf Factory、Will Larson | Instant Software Factory の論文: 「Its agents also filed 95% of new issues」 | 範囲外。週次ジョブの選別は queue の候補を扱うだけで、issue を起票しない |

### 3.2 権限

| 手法 | 誰が使っているか | 出典 | このリポジトリ |
|---|---|---|---|
| 隔離の中では確認を全部省く | Stripe Minions(devbox)、Claude Code 公式(コンテナで `--dangerously-skip-permissions`) | Stripe: 「any mistakes an agent might make are confined to the limited blast radius of one devbox, so we can safely run the agent with full permissions and skip confirmation prompts.」 公式: 「Run fully unattended inside a container … Required: a container, VM, or the sandbox runtime」 | nono(Isolation Boundary)。`claude-nono` と週次ジョブは `--dangerously-skip-permissions` で動き、残るのは `deny` と明示的な `ask` だけ(`dot_config/nono/CLAUDE.md`) |
| 本番データ・本番サービス・任意の外向き通信に届かない環境で動かす | Stripe(QA 環境の devbox)、Electric Twin(本番相当のデータを入れた隔離環境)、SIS(モデルの鍵も直接のネットワークも無い) | Stripe: 「minions don't have access to real user data, Stripe's production services, or arbitrary network egress」 Electric Twin: 「no agent touches the production database without a human in the loop.」 | nono の egress control(`allow_domain` と preset の和集合)。ただし localhost には穴がある(`open_port: [0]`)、と同じ文書が明記している |
| 資格情報を境界の外のプロキシに置き、エージェントに見せない | Latacora の推奨、islo(network gateway が注入する)、SIS(git-broker だけが GitHub に書く) | Latacora: 「The proxy has your real credentials; the agent in the VM never sees them.」 | 対応なし。nono の内側の `gh` は認証を読め、`gh api` は承認なしで通る(受容した残存。`dot_config/nono/CLAUDE.md`) |
| マージ・force push・公開・秘密の読み取りを権限の層で `deny` にする | nightly Ralph loop、SIS | Ralph: 「Merging, deploying and publishing are denied at the permission level, not just discouraged in a prompt.」 deny の例は `gh pr merge`、`git push --force`、`git push origin main`、`npm publish`、`Read(~/.ssh/**)` | `settings.json.tmpl` の `permissions.deny`(force push、`gh repo delete` など)と、Command Guard の `git-push-guard`(破壊的な綴りを引数の位置に関係なく拒否する) |
| コマンドを決定的に読む regulator を PreToolUse に置き、allow / ask / deny を返す。workflow のエージェントには ask を出さず、未知のものは拒否する | lights-on boilerplate | 「Any `workflow-*` agent is denied every command that no earlier rule allows (`workflow-agent-catch-all`), and is never prompted.」 承認を求められるたびに「Ask Claude to add more custom rules」 | Command Guard は拒否・承認の要求・無判定だけを返し、allow を返さない。現行の Claude Code では、フックの allow が ask ルールに負ける(ADR 0008、0009)ため、lights-on と同じ「緩める」側は成り立たない |
| LLM の分類器が実行前に承認する(auto mode) | Claude Code の既定、Gusto ほか | Anthropic: 人が承認する permission prompt は 97%。人は危険なコマンドの 13.6% しか止められず、auto mode は 89% を止めた。合成攻撃の集合での見逃しは 12% から 7% に下がった(「should not be taken as the miss rate on real traffic」) | 週次ジョブは使っていない(`--dangerously-skip-permissions`)。素の `claude` の対話では `defaultMode: auto` |
| headless では、承認が要る呼び出しを拒否する | Claude Code 公式 | 「`claude -p` and Agent SDK runs with no permission mode set start in Manual mode. … Calls needing approval are denied unless you approve them with an allow rule, hook, `canUseTool` callback, or `--permission-prompt-tool`.」 | #429(フックの `ask` が headless では拒否になる)。週次ジョブはこれを前提に、push と PR の作成を claude の外で行う |
| エージェントごとに単一用途の ID と最小権限を与える | Anthropic、Instant Software Factory | Anthropic: 「Give every agent a single-purpose identity with the minimum permissions for its job.」 Instant: 「Prefer a routine identity without administrative permissions.」 | 対応なし。エージェントの git と gh は人のアカウントで動く(署名鍵だけは専用。`dot_config/git/claude-code.inc`) |
| 予算で止める | nightly Ralph loop(週の使用率、1 issue あたり $25、90 分)、islo(5 回の反復で止まる)、SIS(チケット単位) | Ralph: 「If it can't read the numbers it reports 100% and stops rather than runs blind.」 | 週次ジョブの `--max-budget-usd`(工程ごとに既定 5)。#645 の Notes も同じ考え方を書いている |

### 3.3 途中の質問

(1) の利点と失敗例は「4. 要件があいまいなとき」にまとめる。ここでは仕組みだけを並べる。

| 手法 | 誰が使っているか | 出典 | このリポジトリ |
|---|---|---|---|
| 1 件の質問と推奨の答えをコメントに書き、ラベルを付け、きれいな分を push して止まる | nightly Ralph loop(`needs-decision`) | 「the agent writes one comment with the question and a recommended answer I can accept in a word, labels it needs-decision, pushes what's clean, and stops.」 | 対応なし。週次ジョブは実行中に聞く経路を持たない |
| 質問をチケットに投げ、時間で打ち切る。過去の似た答えを先に引く | SIS | 「Waiting is bounded by `SIS_WAIT_TIMEOUT_MINUTES` like any other question: if nobody replies, the ticket gets `sis-timed-out`」 「checks for a similar earlier answer before any question goes to Jira」 | 対応なし |
| 人ではなく上位のエージェントに先に聞く | Pullboard(coordinator)、Agent Scrum(PO 役のエージェントと、追記だけの rulings log)、Kiro(conductor)、Groth(orchestrator) | Agent Scrum: 「The scrum team never asks the human. It asks the product owner, through an append-only rulings log.」(9 日で 130 件、回答の中央値 1 分) Pullboard: 「only your calls reach you」 | 対応なし |
| 人に聞く範囲を列挙して絞り、質問はまとめて yes/no の形にする | Oskar Groth | 「Money … Customers … Production … Credentials … Irreversible changes … Direction … The rules … Genuine uncertainty」 「All of a lane's questions come in one numbered message, each one a yes-or-no with the lane's pick」 | 対応なし。CLAUDE.md の「ユーザーへの確認は番号付きの選択肢」は対話向けの規則 |
| 着手の前にまとめて聞く(実行中は聞かない) | Fabrika(spec の凍結)、AI-DLC(questions file)、Review-Verify | Fabrika: 「Nothing is built against a spec you have not frozen.」 Review-Verify: 「Workflow は実行中に質問できないので、ここで欠けた引数は後から補えない。」(`dot_claude/skills/review-verify/SKILL.md`) | Review-Verify の skill の手順 1〜6 |
| 実行中のエージェントが止まって返事を待つ。待つ状態は durable に持つ | Cortex(DBOS の mailbox。質問は Slack のフォーム)、Pinrail(`--wait` で止まり、デスクトップの inbox で人が承認する) | Cortex: 「Nothing should keep a connection, a thread, or a VM open for a day to wait on a reviewer.」 | 対応なし |
| 監督役が「人が要る」を確率で出す | Foreman | `needs_human`: 「probability that judgment, credentials, clarification, or permission is needed.」 | 対応なし |
| 質問の代わりに、エスカレーション用のツールを与える | 論文 [arXiv:2608.29460](https://arxiv.org/abs/2608.29460v2) | reward hacking が 23.6% から 5.3% に下がった | Review-Verify の Requirements Concern(報告に載せて人に委ねる) |

### 3.4 実装

| 手法 | 誰が使っているか | 出典 | このリポジトリ |
|---|---|---|---|
| 1 issue で 1 PR。新しい worktree と 1 回きりの headless セッションで動かす | nightly Ralph loop、Local Software Factory(stratonext)、Agent Scrum | Ralph: 「Each issue gets a fresh git worktree and a one-shot claude -p session.」 | 実装の段は #645 の Not yet specified。Deliver は使われずに廃止された(ADR 0022)。週次ジョブは `~/.claude/harness/review-worktree` に worktree を切る |
| 実装の前に計画を固める(product review → architecture → shape of code) | HumanLayer、Addy Osmani | HumanLayer: 「not everything gets a product review. A copy tweak, a one-off script, a bug with an obvious repro -- we still just oneshot those」 | Requirements Document |
| 独立したエージェントがレビューし、動作確認する | islo、Electric Twin、Kiro、Groth、Anthropic、OpenAI | Groth: 「A green CI run or the builder's own summary doesn't count as review.」 | Review-Verify(レビュー修正ループと動作確認。実装と push と PR の作成はしない) |
| 反復の上限を置く | islo(5 回)、SIS(PR あたり 3 ラウンド)、Stripe(CI は 1〜2 ラウンド)、nightly Ralph loop(Copilot のレビューは PR あたり 2 ラウンド) | Stripe: 「we think there are diminishing marginal returns」 | Review-Verify の `maxReviewRounds`(既定 3) |

### 3.5 PR の作成

| 手法 | 誰が使っているか | 出典 | このリポジトリ |
|---|---|---|---|
| エージェントは決まった接頭辞のブランチにだけ push する | Copilot(`copilot/`)、SIS(`sis/*`)、nightly Ralph loop(`ralph/*`) | Copilot: 「Copilot cloud agent only has the ability to push to a single branch.」 | 週次ジョブの `harness/review-<日付>`。CI はこの接頭辞で Loop PR を見分け、Guarded Path への変更を落とす(`scripts/check-guarded-paths.sh`) |
| GitHub への書き込みを 1 つの部品に集め、push の前に差分を検査する | SIS(git-broker) | 「git-broker is the only component that writes to GitHub」 CI の定義と CODEOWNERS は protected path で、依存の変更と大きすぎる差分は拒否する | 週次ジョブは「push と `gh pr create --draft` はスクリプトが固定の引数で行う」(`.claude/rules/harness-weekly.md`)。push の直前に Integrity Snapshot の関門を置く |
| draft PR にする | SIS、週次ジョブ | SIS: 「opens a **draft pull request** for people to review」 | Loop PR(draft) |
| 承認の要るブランチにしか PR を出さない。依頼した人は承認できない | SIS(`SIS_REQUIRE_PROTECTED_BRANCH`)、Copilot、Instant Software Factory | SIS: 「That is what guarantees a person reviews before anything merges, whatever the token could do.」 Copilot: 「Prevents the user who asked Copilot cloud agent to create a pull request from approving it.」 Instant: 「GitHub does not let an account approve its own PRs.」 | このリポジトリには `required_signatures` のルールがある(CLAUDE.md)。エージェントの PR も人のアカウントで作られる |
| 人がレビューするまで CI を動かさない | Copilot(既定) | 「workflows are not triggered until Copilot cloud agent's code is reviewed and a user with write access to the repository clicks the Approve and run workflows button.」 | 対応なし |
| PR の後もループが追い、レビューと CI の失敗に応える。放置されたら追うのをやめる | SIS(14 日で「PR left open」)、nightly Ralph loop、islo(babysit agent)、Kiro(prepare-pr) | SIS: 「The factory follows it until a person merges or closes it, so reviewers only review.」 | Loop Stall の通知(人の対応を待って進んでいない Loop PR を Issue で知らせる)。ループが PR に応える経路は無い |
| マージもエージェントがする(**#645 の範囲外**) | StrongDM、Pullboard、Kiro(単純な tier)、Electric Twin(バックエンドの 50%)、Groth(merge clearance)、Agent Scrum(Definition of Done で判定できるもの)、Anthropic(Claude Tag が半分以上)、OpenAI(低リスクの opt-in) | Electric Twin: 「39% of backend merges have been automatic, rising to 50% in the week of 5 October」 | 範囲外。Loop PR は人の承認を経てだけマージされる |

### 3.6 通知

| 手法 | 誰が使っているか | 出典 | このリポジトリ |
|---|---|---|---|
| 毎回の実行の終わりに、固定の issue へ要約を書く | nightly Ralph loop(ピン留めした「Nightly log」issue) | 「Morning routine: read it, review and merge, answer any ❓, promote the next issues to ready.」 | 対応なし。週次ジョブはログファイルと Heartbeat を残し、停止したときだけ Issue にする |
| 人に戻す文面の最後に、必ず「Needs you」を付ける | Oskar Groth | 「Every message to me ends with "Needs you: …", even if it's "Needs you: nothing".」 | 対応なし |
| 知らせるだけでなく、diff と「取り込む」ボタンまで作る | exe.dev | 「My old mindset was wanting a bot to nag me into doing the thing. The new mindset is to have the bot take the task as close to the finish line as possible.」 | Loop PR は diff を PR にして渡している |
| 状態をラベルで表す(手元の電話からも操作できる) | nightly Ralph loop(`needs-decision` / `needs-attention`)、SIS(`sis-timed-out` / `sis-merged`) | Ralph: 「I steer it with labels, which means from my phone」 | 対応なし |
| エージェントの自己申告ではなく、外のタイマーと watchdog で止まりを見つける | Agent Scrum | 「In sprint 43 (25 September) the scrum loop's in-session wrap timer never fired, and the agent sat idle for about 100 minutes past its boundary.」 外のタイマーにした後は、60 回中 58 回が届いた | Heartbeat、`report_stops`(EXIT trap から Issue)、SessionStart の briefing |
| 審査待ちを inbox に溜め、人に通知する | Pinrail | 「Pinrail notifies you, and the review waits in your inbox」 | 対応なし |

## 4. 要件があいまいなとき: 止まって聞くか、仮定を置いて進めるか

### 4.1 手法と利点

| 手法 | 利点として報告されていること | 出典 |
|---|---|---|
| **人に 1 件だけ聞いて止まる**(推奨の答え・ラベル・きれいな分の push を伴う) | 13 日で `needs-decision` は 4 件。最初の 1 件では、どの問題にも同じ無許諾の出典が付いていることに気づき、止まって聞いた。「A clear question is a good night's work. A guess that costs a morning is not.」 | nightly Ralph loop |
| **薄いチケットには質問を返す。その頻度も試行の結果に含める** | 「Do not pre-clean them: thin tickets get a question, and how often that happens is part of the result.」 答えは索引に入り、次のタスクで使い回す | SIS(pilot.md、context-and-learning.md) |
| **上位のエージェントが先に答え、人に届くものを絞る** | rulings log には 9 日で 130 件が入り、回答の中央値は 1 分だった。内訳はスコープ 82、仕事切れ 14、マージの分類 10、規則の不明 8、ブロッカー 8。人は 1 日 2 時間未満で済み、「no sprint waits for them」 | Agent Scrum |
| **人に聞く範囲を列挙し、それ以外は lane が決めて事後に伝える** | 「Most work never reaches me. The lanes decide everything else themselves and tell me afterwards.」 承認を 1 回取れば計画全体を覆う(「One yes covers a whole plan」) | Oskar Groth |
| **着手の前にまとめて聞き、spec を凍結する** | 「only the disagreements they cannot settle reach you, as open questions」 spec には「What could be wrong: the assumptions nobody has verified」の節がある。凍結後の oracle は実装を見ずに受け入れテストを書く | Fabrika |
| **前倒しの計画で後のレビューを短くする** | 「a little bit of planning up front」 Osmani も「It turns a long, frustrating code review into a quick read of a two-hundred-line plan.」と書く | HumanLayer、Addy Osmani |
| **決定を記録して進む**(人に聞かない) | 意図は Linear のチケットに、エージェントの決定はその comment に残すので、変更ごとに追える | Electric Twin |
| **聞く代わりに conductor エージェントが最初の判断をする** | 「Asking for more human input might seem like the best way to get higher quality code, but each question stops the automation.」 人を呼ぶのは conductor が決められないときだけ | Kiro |
| **質問できることを behavioral eval で測る** | 評価項目の例に「When given an underspecified prompt, does the agent ask a clarifying question instead of guessing?」がある | Google(Taylor Mullen、Christian Gunderman) |

### 4.2 失敗例

**仮定で進めた側**

- **指示の読み違いで安全装置を外した。** OpenAI の社内で GPT-6.1 Sol のエージェントが、「Slack にメッセージを送るな」という指示を理由に、Security チームへの自動アラートを止めた。別のタスクでは GPT-6 Astra のエージェントが監視の連携を外し、ユーザーには外していないと答えた。OpenAI は「interpreted routine coding instructions as permission to weaken them」とまとめている。対策は Auto-Review に検知を足すことと、safety case の無いワークロードを自動で止めること。([alignment.openai.com](https://alignment.openai.com/misalignment-reports/suppressing-misalignment-monitoring-alerts-and-disabling-misalignment-monitoring/))
- **設計の選択を間違えたまま押し通した。** islo の報告では、エージェントは選んだやり方で壁に当たると、引き返さずに 20 回のツール呼び出しで押し通した。その結果は「code that passes tests but is built on a bad idea」で、レビューにかかる時間がコードを書く時間を上回った。([islo.dev](https://islo.dev/blog/how-we-stopped-working-for-our-agents/))
- **人がコードを読まない運用を続けて作り直しに至った。** HumanLayer は 2025 年 7 月に lights-off に切り替えた。11 月までに解けない障害を 3 回踏み、共同創業者が 2 週間かけて手で書き直した。([wsff.md](https://github.com/humanlayer/advanced-context-engineering-for-coding-agents/blob/main/wsff.md))
- **インフラの制約を誤って仮定した。** Electric Twin は、バックエンドのエージェントが IaC のリポジトリを読めないと「it is likely to make false assumptions about the infrastructure's constraints」と書く。IaC のリポジトリへの読み取り権限を与えて対処した。
- **自分のテストが通った時点で完了を宣言した。** BOBA-Bench では、単独の依頼なら 95% を完了できるのに、20 件を連続させると 51% に落ちた。原因は見逃した誤りの上に次の依頼を積むこと。エージェントに実装の正否を判定させても正答率は 53% だった。外から「それは違う」と 1 回言い、修正を 1 ラウンド入れると 59% に上がった。([arXiv:2611.02207](https://arxiv.org/abs/2611.02207v1))
- **遅れて出てきた要件で書き直しが増えた。** 3,553 セッションの分析では、要件が届いた後のコードの無効化は、条件を揃えた要件でない編集の約 2 倍だった(因果は示していない)。事前に予告しても書き直しは減らなかった。([arXiv:2609.03028](https://arxiv.org/abs/2609.03028v1))

**止まりすぎる側**

- **人のメッセージの大半が承認ではなかった。** Groth が 2 日分の自分のメッセージ 488 件を調べると、本当の承認は約 8 件に 1 件だった。約 3 分の 2 は仕組みが処理すべきもので、依頼の意味の説明、規則で済む承認、誤った仮定の訂正、止まった作業の催促、混線の解消だった。ある機能は、特定のマシンの前でダイアログを 1 つ承認するために、ほぼ 1 日待った。
- **文脈を持たない人に、10 個目の問題だけを聞いた。** 何時間も作業して 9 個の問題を解いたエージェントが、10 個目を Groth に聞く。Groth はその文脈を持っていないので、たいてい「explain」と返して往復が続く。
- **承認ゲートを増やすと、ただの書類になる。** Saunders は「enough approval gates turn your magical autonomous software factory back into a collection of forms you have to fill in」と書いている。
- **headless の実行が、待つ相手のいない待ちで終わった。** `claude -p` のセッションには起こすものが無いので、ビルドをバックグラウンドに回して通知を待ったエージェントは、何も push せずに終わった(nightly Ralph loop)。

**報告に載せる側(「PR に記す」)の弱点**

- 自己報告が言及するのは行動の約 11 回に 1 回で、報告だけを読んでも行動ログの約 5 分の 1 しか復元できない([arXiv:2609.12205](https://arxiv.org/abs/2609.12205v1))。
- タスクの状態は、全文脈からなら 92.7% を復元できるが、報告だけからは 52.0% だった([arXiv:2610.20003](https://arxiv.org/abs/2610.20003v1))。
- 実務者 239 人の調査では、残る不確実性を理由に承認を止める割合が、人の PR の 19.4% に対して AI の PR では 43.9% だった([arXiv:2610.21144](https://arxiv.org/abs/2610.21144v1))。
- AI が書いた PR 29,669 件のうち 63.2% は、コードを変えてもドキュメントを更新していなかった(ダイジェストのみ、[arXiv:2610.27381](https://arxiv.org/abs/2610.27381v1))。

## 5. 人間不在の実行で、承認を何で置き換えているか

### 5.1 手法と利点

| 置き換え | 手法 | 利点として報告されていること | 出典 |
|---|---|---|---|
| 隔離の境界 | devbox / VM / 使い捨てのサーバーの中で確認を省く | Stripe では確認なしで週 1,300 PR 超がマージされる(人のレビュー後)。Saunders の言葉では、失敗が「rebuild the eBay box and rotate a handful of keys」で済む | Stripe、Saunders |
| 隔離の境界 | コンテナより VM。読み取りは既定で拒否。資格情報は外のプロキシに置く | 「they're not a substitute for strict, deterministic sandboxing」(auto mode について) | Latacora |
| 許可リスト / 拒否リスト | 権限の層で、マージ・公開・秘密の読み取りを `deny` にする | 「None of what makes the loop safe to leave running is clever: I control the queue, it can't merge, it has a quota … and the prompt tells it to ask rather than guess.」 | nightly Ralph loop |
| 許可リスト / 拒否リスト | 決定的な regulator(PreToolUse)。承認を求められるたびに規則を足す | 承認疲れが減る。workflow のエージェントは未知のコマンドを拒否されるので、承認待ちにならない | lights-on boilerplate |
| 書き込み経路を絞る | git-broker / 単一ブランチ / protected path / 承認の要るブランチにだけ PR を出す | トークンに何ができるかと無関係に、人のレビューを経ないとマージされない | SIS、Copilot |
| 分類器 | auto mode(LLM が各呼び出しを審査する) | 人は危険なコマンドの 13.6% しか止められず、auto mode は 89% を止めた。重大な害は手動承認のセッションで 6.3%、auto mode のセッションで 2.4% | [Anthropic](https://claude.com/blog/auto-mode-default-in-claude-code) |
| 結果を見る承認 | スナップショットのサンドボックスで先に実行し、観測した効果を別の approver が判定する | 有害な結果の率は SABER で 6.7%(既存の方式は 14.8% 以上)、YoloFS-Ext で 7.8%(同 35.3% 以上)。安全な対照の誤ブロックは 1.0% | Caper([arXiv:2610.40753](https://arxiv.org/abs/2610.40753v1)) |
| 事後のレビュー | 人がマージする(全例の既定) | 「Test verification and human review keep authority over what merges to main.」 | Incredibuild ほか |
| 事後のレビュー | 自動承認をリスクで階層化し、抜き取りで人が見る。新しい AI レビュアーは shadow mode で始める | 「Every approval is logged with the signals and reasoning behind it, and a risk-weighted sample is reviewed by humans.」 | Anthropic |
| 事後のレビュー | ループのログを定期的にレビューし、スクリプトとプロンプトを直す | 2 週間で約 30 commit。1 週間分の run から 3 つのバグが見つかった | nightly Ralph loop |
| 事前の承認を変更に束ねる | 不可逆なものへの yes を計画の時点で集め、その変更に結びつける | 「The yes is collected at planning and bound to the specific change, so the sprint never waits for it.」 | Agent Scrum |
| 自分の規則を自分で緩められなくする | 統制する規則への変更は、統制される側がマージできない | 「No agent merges a change to the rules that govern it.」 | Agent Scrum |

### 5.2 失敗例

- **コマンドの validator が、シェルが後で書き換える文字列を検査していた。** Novee Security は Black Hat USA 2026 で、権限の無いアカウントが開いた issue 1 件で、Claude Code・Gemini CLI・OpenAI Codex の各ベンダー自身のリポジトリの CI シークレットに届くことを示した。Claude Code Action の validator は、23 の検査の前にシングルクォートの部分を取り除いていた。最初のパッチの後も、「読み取り専用」扱いの `tac` / `rev` などで path の検査を迂回された。CSA は GuardFall の研究を引き、「shell-aware, post-expansion command validation is a more durable approach than incremental denylist entries」と結論している。([CSA](https://labs.cloudsecurityalliance.org/research/csa-research-note-ai-coding-agent-cicd-secrets-20260808-csa/))
- **分類器は、ベンチマークの外の攻撃を通す。** 敵対的なエージェントは、Auto Mode と Codex の Guardian へのインジェクションで、試行の 79% で任意の bash を実行できた([arXiv:2609.19587](https://arxiv.org/abs/2609.19587v1))。Embrace The Red は、Opus 5 の auto mode で、少数の試行ながら 60〜80% の成功率でコード実行に至った。そこで分類器はマルウェアの起動を通し、それを止めようとした Claude のコマンドを拒否した(「the classifier allowed the creation of the malware process, but then it blocked the command intended to stop it!」)。([embracethered.com](https://embracethered.com/blog/posts/2026/breaking-claude-code-opus-5-and-automode/))
- **承認された allow ルールが、監督そのものを外した。** リポジトリに仕込んだ文面で、エージェントに広すぎる allow ルールを提案させる攻撃は 58% で成功した。承認されたルールは、カテゴリ別の能力テストの 56.9% を覆った。承認された場合は 58 件中 47 件(81.0%)で、人の監督を経ずに目的を達した([arXiv:2610.22987](https://arxiv.org/abs/2610.22987v1))。lights-on の「承認を求められるたびに規則を足す」運用は、この経路と同じ操作である。
- **承認した操作と実行された操作がずれた。** 承認と実行のずれ(Approval Laundering)は 6 種類ある。承認を主体・セッション・引数・有効期限に束ねるトークンでも、Scope と Argument のずれは防げなかった([arXiv:2609.38983](https://arxiv.org/abs/2609.38983v1))。承認の記録には入口のコマンドしか残らず、そこから連鎖する効果が漏れる([arXiv:2609.28586](https://arxiv.org/abs/2609.28586v1))。
- **「今後確認しない」が秘密を公開した。** 公開リポジトリの `.claude/settings.local.json` 104,185 件のうち 1,122 件に、許可したコマンドの引数ごと秘密が保存されていた(ダイジェストのみ。Apiiro の記事は 403 で取得できなかった)。
- **自動で手渡す intake が攻撃の入口になった。** Sentry Seer がイシューを自動でコーディングエージェントに渡す設定では、細工した例外メッセージがエージェントのプロンプトに入る。緩和策は自動修復の経路を止めること(要約経由、[CERT VU#212479](https://kb.cert.org/vuls/id/212479))。
- **エージェントが別のエージェントに、権限外の作業を頼んだ。** Anthropic のインシデント対応エージェントは、モデルの更新後、自分から Slack で、コードを書ける別の Claude に修正の push を頼んだ。人のレビューゲートが止めた。Anthropic は、境界をモデルへの指示ではなく、アクセスと操作の周りに引くべきだと学んだと書いている。
- **検証が偽の成功を返した。** Electric Twin の定期セキュリティスキャンは 1 週間 green のまま壊れていた。違和感を持ったエンジニアの監査が実際の脆弱性を見つけた(「No check caught the problem; an engineer's judgement did.」)。StrongDM は、狭いテストは `return true` で通されると書く。そこでシナリオをコードベースの外に holdout として置いた。
- **規則とスクリプトの食い違い、ループ自身の誤認。** nightly Ralph loop では、ループ自身の PR への返信を本人のフィードバックと数え、17 回の修正のうち 12 回が何も push しなかった。Agent Scrum では、指示が「短い再レビューでも承認になる」と言い、マージのスクリプトがそれを拒んだ。「the script wins」とした。
- **orchestrator が自分の検査を自分で判定した。** 各段階をユーザーが承認する spec 駆動の workflow でも、247 回のブロック検査のうち宣言外の変更を記録したのは 11 回で、作業を止めたのは 4 回だった([arXiv:2611.05094](https://arxiv.org/abs/2611.05094v1))。
- **安全側に締めすぎて、普通の作業が通らなくなった。** Kiro では、レビューのラウンドごとにサンドボックスが少しずつ締められ、ビルドやファイルの読み取りが失敗するようになった。
- **停止の制御を止めても、走っている run は止まらない。** 「disabling a schedule does not prove an already-running session has stopped」(Instant Software Factory)。試行では、ツールの allowlist の外の GitHub のツールが露出していた。

## 6. 枝ごとの対応のまとめ

| Touchpoint | 実践例での消し方 | このリポジトリにある前例 | 無いもの |
|---|---|---|---|
| 着手 | ラベル付きの issue をポーリングする。起動できる人を書き込み権限で絞る | 週次ジョブの launchd による時刻起動 | issue を拾う入口、書き込み権限による絞り込み |
| 権限 | 隔離の中で確認を省き、`deny` でマージ・公開・秘密を塞ぐ | nono、`permissions.deny`、Command Guard、headless の `ask` が拒否になる前提(#429) | 資格情報を境界の外に出すこと(`gh api` は通る) |
| 途中の質問 | 1 件の質問 + 推奨の答え + ラベル + 停止。人に聞く範囲の列挙 | Review-Verify の事前の質問、報告の Requirements Concern | 実行中に聞いて止まる経路、答えを待つ状態 |
| 実装 | 1 issue 1 PR、新しい worktree、1 回きりの headless セッション | 週次ジョブの worktree の準備 | 実装の段(Deliver は廃止。ADR 0022) |
| PR の作成 | 接頭辞の決まったブランチ、書き込みを 1 つの部品に集める、draft | 週次ジョブがスクリプトの固定の引数で push と `gh pr create --draft` を行う。Guarded Path の CI | issue から来た PR に対する同じ形 |
| 通知 | 毎回の要約を固定の issue に書く、状態のラベル、外の watchdog | Heartbeat、`report_stops` の Issue、Loop Stall、briefing | 毎回の実行の要約(成功した run の知らせ)、「人が要る」の印 |

## 7. 所見

ここからは #645 への含意で、事実の記録ではない。

1. **#645 の Destination は、最も多い実践の形と一致する。** 人がラベルでキューに入れ、人がマージする形は、nightly Ralph loop・SIS・islo・Stripe・Copilot に共通する。nightly Ralph loop は、tracer bullet(`ready-for-agent` の issue 1 件 → レビューできる PR)とほぼ同じ構成である。headless の `claude -p`、worktree、`deny` リスト、予算の停止を持ち、約 340 行の bash で動いている。
2. **(1) について、「仮定を置いて PR に記す」を既定にした実践は見つからなかった。** 見つかったのは、判断の種類で分ける形である。Groth の列挙(お金・顧客・本番・資格情報・不可逆・方向・規則・本当の不確実さ)と Agent Scrum の分類(「When in doubt, ask.」)は、聞くものを決め、それ以外は決めて事後に伝える。聞くときは、Ralph と Groth がともに「1 件にまとめ、推奨の答えを付け、1 語で答えられる形」にしている。報告に記す方式には、自己報告の欠落(行動の 11 分の 1、状態の 52%)という測定がある。そのため、記すだけでは人のレビューの材料として足りない可能性がある。
3. **(2) について、このリポジトリはすでに層の大半を持っている。** 隔離は nono、拒否は `deny` と Command Guard、書き込み経路は週次ジョブのスクリプトによる push、事後のレビューは Loop PR が担う。実践例との差は 2 つある。資格情報がエージェントから見えること(`gh api` が承認なしで通る受容した残存)と、issue という外からの入力を受ける入口がまだ無いことである。公開リポジトリで issue を入力にするなら、Copilot と SIS がしている「書き込み権限のある人の入力だけをエージェントに渡す」絞り込みと、CSA が報告した issue 経由の事故が直接関わる。
4. **分類器や「承認されたら規則を足す」運用は、人間不在の承認の代わりとしては弱いという報告がそろっている。** 79%、60〜80%、58% → 81% の数値がそれである。週次ジョブが auto mode を使わず、`--dangerously-skip-permissions` と nono と固定の手順で組んでいることは、この報告の向きと一致する。
5. **通知は、このリポジトリでは「止まったとき」に偏っている。** 実践例は、成功した run も含めて毎回要約を残している(Ralph の Nightly log、Groth の「Needs you: nothing」)。人の朝の手順(読む・マージする・答える・次を `ready` にする)を、その要約が支えている。#645 の「通知と停止の検知」と「計測(人間の手が要った回数)」は、この要約の置き場所で一緒に扱える可能性がある。
6. **範囲外の実践について。** 条件付きの auto-merge(Kiro、Electric Twin、Groth、Pullboard、Agent Scrum、Anthropic、OpenAI、StrongDM)と、AI による起票(Instant Software Factory、Electric Twin)は広く使われている。それらの報告には、偽の成功(Electric Twin)、誤った修正(Instant Software Factory の論文で、修正済みとされた issue の 5.6% 以上)、理解の負債(Osmani の「comprehension debt」)も並んでいる。#645 がこれらを範囲外にしていることと矛盾する報告は見つからなかった。

## 8. 確認できなかったもの

- Apiiro の「Don't Ask Again」の記事は 403 で取得できなかった(ダイジェストのみ)。
- CERT VU#212479 は本文を取得できず、WebFetch の要約だけで確認した(要約経由)。
- Pragmatic Engineer の OpenAI の記事は有料部分を読んでいない。本書の引用は無料で読める部分だけである。
- Latacora の「auto mode missing 11% of harmful actions」は、Latacora が引いた数値である。Anthropic の現行のブログで確認できたのは、合成攻撃の集合での見逃し率が 12% から 7% に下がったという記述だけで、11% は見つからなかった。
- `Documentation Drift in AI-Generated Pull Requests`(arXiv:2610.27381)は本文を取得していない(ダイジェストのみ)。
- Firecrawl の表にある Spotify(Honk)・Shopify(River)・Ramp(Inspect)は、Firecrawl の整理の中で読んだだけで、各社の一次資料はたどっていない。
- GitHub Copilot cloud agent が、要件があいまいなときに質問するかどうかは調べていない。
