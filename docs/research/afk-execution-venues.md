# AFK の実行場所(launchd・クラウドの routine・GitHub Actions)で何ができるか

日付: 2026-11-11
問い: #647(親: #645)。`ready-for-agent` の issue を人間不在で拾って処理する実行場所として、次の 3 つは何ができて何ができないか。

1. **launchd**: ローカルの launchd から nono の内側で headless の `claude -p` を起動する(既存の週次ジョブと同じ形。#397)
2. **routine**: Claude Code のクラウドの scheduled task(旧称 routines。以下 routine)
3. **Actions**: GitHub Actions の `anthropics/claude-code-action`

本書の前半(「比較表」「実行場所ごとの詳細」)には資料で確かめた事実だけを書き、判断は「所見」の節に分ける。資料で確かめられなかった項目は「未確認」と書き、末尾の「未確認の項目」に集めた。出典は `[記号]` で引き、末尾の「出典」に URL・取得日・コミット SHA を挙げる。

## 比較表

| 観点 | 1. launchd + nono + `claude -p` | 2. routine(クラウドの scheduled task) | 3. Actions(`claude-code-action`) |
|---|---|---|---|
| 起動のきっかけ | 時刻だけ(`StartCalendarInterval`)。issue のイベントでは起動しない。拾うにはスケジュールで issue を照会する [M1][L3] | スケジュール(最短 1 時間)・API(`/fire`)・GitHub のイベント(Pull request / Release / Issue。Issue は `labeled` を含む) [C1][C8] | GitHub の任意のイベント。`issues` の `labeled` と `label_trigger` 入力、`schedule`(cron)も可 [G1][A1][C9] |
| `~/.claude` の rules・skills・hooks | 効く。`--bare` を付けない `-p` は `~/.claude` を対話セッションと同じように読み込む [C6]。週次ジョブはその前提で動いている [L1] | 効かない。`~/.claude/CLAUDE.md`・`~/.claude/skills/`・ユーザー設定の hooks・plugin は持ち込まれない。リポジトリの `CLAUDE.md`・`.claude/rules/`・`.claude/skills/`・`.claude/settings.json` の hooks は効く(リポジトリが 1 つのとき) [C2][C4] | ランナーは毎回新しい VM なので、利用者のマシンの `~/.claude` は無い [G2]。action は `settings` 入力からランナーの `~/.claude/settings.json` を書き [A5]、`plugins` 入力で plugin を入れる [A1]。checkout したリポジトリの `CLAUDE.md`・`.claude/` は読む [C9][A4] |
| 隔離の境界 | nono(macOS Seatbelt、既定は全拒否)。plist が `nono run --profile claude-seal` を明示する [L2][L3][L5] | Anthropic が管理する VM(1 セッション 1 VM)。外向きの通信はセキュリティ proxy、GitHub は専用 proxy を通る。git の認証情報と署名鍵は VM の外 [C2][C3] | GitHub-hosted runner の VM(1 ジョブ 1 VM)[G2]。GitHub App の token はリポジトリ 1 つに限られた短命のもの [A2]。外向きの通信の制限は action の資料に見当たらない(未確認) |
| push と PR の作成 | スクリプトが固定の引数で `git push` と `gh pr create --draft` を行う。headless ではフックの `ask` が拒否になるため [L1][L7] | 既定で `claude/` で始まるブランチに push する。proxy はブランチの削除とタグの push を拒否する [C1][C2]。`gh pr` と `gh issue` は GraphQL を使うので 403 になり、REST の `gh api` を使う [C2] | GitHub App の token で push する [C9]。既定の設定では PR を自動では作らず、PR 作成ページへのリンクを返す [A2]。PR を作るには、プロンプトで指示し、`claude_args` でツールを許可する [C9] |
| コミット署名(`required_signatures`) | Claude Code の git は、パスフレーズの無いローカルの鍵で署名する(`claude-code.inc`)[L4]。週次ジョブの PR #638 の 3 commit は `verified=true` [L8] | 未確認。資料は「署名鍵は VM の外」と書くだけ [C3]。公式リポジトリには、2026-07〜08 に cloud の commit が Unverified になるという報告があり、`not_planned` で閉じられている [I1] | `use_commit_signing: true` は GitHub API で commit を作り、GitHub App の署名で verified になる。`ssh_signing_key` も使える [A2][A3]。このリポジトリの `claude.yml`・`security-alerts.yml` は前者を使っている [L9] |
| 認証と課金 | サブスクリプションの OAuth(macOS のキーチェーン)[C5]。nono の内側だけ未ログインになった前例がある(再ログインで解消。原因は特定していない)[L6] | 常にサブスクリプション。cloud の環境に `ANTHROPIC_API_KEY` を置いてもサブスクリプションの認証情報が優先される [C5]。利用量は対話セッションと同じ枠から引かれる [C1] | `CLAUDE_CODE_OAUTH_TOKEN`(`claude setup-token` で作る 1 年有効のトークン。サブスクリプション)か `ANTHROPIC_API_KEY`(API 課金)[C5][C9]。このリポジトリは前者を使う [L9]。public リポジトリなら標準のランナーは無料 [G2] |
| 1 回あたりの予算の上限 | `--max-budget-usd`(print mode 専用。クライアント側の見積もりに対して掛かり、上限を超えることがある)[C7]。週次ジョブは工程ごとに既定 $5 [L1] | 1 回あたりの上限を掛ける設定は資料に見当たらない。掛かるのはサブスクリプションの利用枠と、usage credits の月の支出上限だけ [C1] | `claude_args` の `--max-turns` は資料にある [C9][A3]。`--max-budget-usd` は `claude_args` のパススルーで CLI に渡るはずだが、資料に記載は無く、実測もしていない [A4]。ジョブは最長 6 時間 [G3] |
| マシンのスリープ | スリープ中に過ぎた時刻の分は、起きたときに 1 回にまとめて起動する [M1]。電源が切れている間の分は実行されない [L3](plist のコメント) | マシンに依存しない(ノート PC を閉じていても動く)[C1][C8] | マシンに依存しない。ただし `schedule` は負荷の高いときに遅れることがあり、public リポジトリで 60 日間動きが無いと止まる [G1] |

## 実行場所ごとの詳細

### 1. launchd + nono + headless `claude -p`

- **起動**: plist の `StartCalendarInterval` で土曜 10:00 に起動する。`RunAtLoad` は false [L3]。`StartCalendarInterval` は、cron と違ってスリープ中の分を飛ばさず、起きたときに 1 回にまとめて起動する。一方 `StartInterval` は、スリープ中に来た回を飛ばす [M1]。issue のイベントを受ける仕組みは launchd には無い。手動で 1 回だけ回すには `launchctl kickstart gui/$(id -u)/<label>` を使う [L1]。
- **ログインセッション**: エージェントは `~/Library/LaunchAgents` に置くユーザーごとのもの [M1]。ログアウト中にも起動するかは man に書かれておらず、未確認。
- **設定の効き方**: `--bare` を付けない `claude -p` は、hooks・skills・`CLAUDE.md`・plugin・MCP を、作業ディレクトリと `~/.claude` から対話セッションと同じように読み込む [C6]。**`--bare` は将来 `-p` の既定になる**と書かれている。`--bare` では hooks・skills・`CLAUDE.md` を読まず、OAuth もキーチェーンも読まない [C6][C5]。既定が変わると、この経路はルールが効かないまま動くか、認証で失敗する。
- **権限**: 週次ジョブは `--dangerously-skip-permissions` と `--settings '{"sandbox":{"enabled":false}}'` で起動し、境界は nono だけになる [L1]。headless ではフックの `ask` を誰も承認しないので拒否になる(git push guard と curl localhost guard)[L7]。このため push と PR の作成は claude の外のスクリプトが行う [L1]。
- **署名**: `GIT_CONFIG_GLOBAL` が指す `claude-code.inc` が、署名鍵を `~/.config/git/signing/ai-agent`(パスフレーズ無し)に、`gpg.ssh.program` を `/usr/bin/ssh-keygen` に差し替える。公開鍵を GitHub に signing key として登録しないと Unverified になる [L4]。週次ジョブの PR #638 の 3 commit は、どれも `verification.verified=true`(`reason=valid`)だった [L8]。この鍵はエージェントが読める平文の秘密鍵で、それは受容した残存リスクとして記録されている [L5]。
- **認証**: macOS ではキーチェーンに保存される [C5]。nono の内側で起動した claude だけが `Not logged in` になった前例がある。そのときは `subtype: success` のまま `is_error: true` になったので、終了コードでは失敗を見分けられない。再ログインで直ったが、原因は特定していない [L6][L1]。
- **予算**: `--max-budget-usd` は print mode でだけ効き、クライアント側の見積もりに対して掛かるので、上限を超えることがある [C7]。週次ジョブは工程ごとに既定 $5 で、Bash を 1 回呼ぶだけの起動でも固定の文脈で約 $0.4 かかると実測している [L1]。月単位の上限は無い [L2]。
- **ADR 0012 との関係**: ADR 0012 が Actions を退けた理由は 2 つある。transcript がローカルにしか無いことと、OAuth の token の失効で 1 か月止まった前例があること [L2]。issue の処理は transcript を読まないので、1 つ目の理由は今回の問いには当てはまらない。2 つ目の理由はそのまま当てはまる。

### 2. routine(クラウドの scheduled task)

- **位置づけ**: research preview で、振る舞い・上限・API は変わりうる [C1]。Pro / Max / Ultra / Team / Enterprise で使える。作るには web(claude.ai/code/routines)か CLI の `/schedule` を使う。`/schedule` を使うには claude.ai のサブスクリプションでのログインが要る [C1]。
- **起動**: スケジュール(1 時間より短い間隔の cron は拒否される)、API(`/fire` に bearer token で POST)、GitHub のイベント(Pull request / Release / Issue)の 3 種類 [C1]。GitHub のイベントで起動するには Claude GitHub App をリポジトリに入れる必要がある。`/web-setup` だけでは webhook は届かない [C1]。絞り込みのフィルタ(Labels など)は Pull request についてしか書かれておらず、Issue のイベントをラベルで絞れるかは未確認 [C1]。イベントには task ごと・アカウントごとの 1 時間の上限があり、超えた分は捨てられる。上限の数は書かれていない [C1]。誰がラベルを付けたら起動するか(書き込み権限で絞るか)も書かれておらず、未確認。
- **設定の効き方**: 毎回リポジトリを新しく clone する。リポジトリの `CLAUDE.md`・`.claude/rules/`・`.claude/skills/`・`.claude/settings.json` の hooks と権限ルールは効く(リポジトリが 1 つのとき)。`~/.claude/CLAUDE.md`、`~/.claude/skills/`、ユーザー設定だけで有効にした plugin、ユーザーの `~/.claude/settings.json` の hooks は効かない。リポジトリの `enabledPlugins` で宣言した plugin も、cloud では入らない [C2][C4]。環境の setup script で `~/.claude/CLAUDE.md` を書き出せば、ユーザーの指示として読み込まれる [C2]。
- **権限**: 起動したセッションは auto mode で始まる。ask ルールに当たった操作と、繰り返しブロックされた操作は、人が答えるまで止まる [C1]。
- **隔離**: 1 セッション 1 VM(Ubuntu 24.04、4 vCPU / 16 GB / 30 GB)。外向きの通信は既定で Limited(既定の allowlist)。GitHub は専用 proxy を通り、本物の token は VM の外に置かれる [C2][C3]。proxy は、セッションに付けたリポジトリ以外への API 要求を 403 にする。GraphQL も 403 にするので、`gh pr` と `gh issue` は使えず、`gh api repos/{owner}/{repo}/...` の REST で代わりにする [C2]。
- **push と PR**: `claude/` で始まるブランチに push する(プロンプトで変えられる)。どのブランチに push できるかは GitHub のブランチ保護・ruleset で絞る [C1]。proxy はブランチの削除とタグの push を拒否する [C2]。資料の利用例には、draft PR を開く routine が載っている [C1]。
- **commit の作者と署名**: 資料は、commit と PR は接続した GitHub のユーザーとして記録されると書く [C1]。一方、公式リポジトリの #78787(2026-07-18)の本文では、セッションの中の git の設定が `user.name=Claude`・`user.email=noreply@anthropic.com`・`gpg.format=ssh`・`gpg.ssh.program=/tmp/code-sign`(`/opt/env-runner/environment-manager` への symlink)になっている。そのうえで公開鍵のファイルが空(0 バイト)で、すべての commit が Unverified になったと報告されている。それまでの約 2 か月は Verified だったとも書かれている。この issue は `not_planned` で閉じられ、同じ症状の 2 件も `not_planned` / `duplicate` で閉じられている [I1]。資料の「署名鍵は VM の外」[C3] は、署名される前提を示すが、Verified になるとは書いていない。作者・署名とも未確認。
- **認証と課金**: 常にサブスクリプションの認証情報を使う [C5]。利用量は対話セッションと同じ枠から引かれ、VM の別料金は無い [C1][C3]。枠を使い切ったとき、usage credits を有効にしていれば従量で続き、無効なら枠が戻るまで拒否される [C1]。起動の種類ごとに 1 時間の上限がある(スケジュールの起動はアカウントで 100 回/時など)[C1]。GitHub の接続が切れると最大 72 時間は起動を飛ばし、それを過ぎると task が止まる [C1]。
- **予算**: 1 回あたりの上限を掛ける設定は、routines・cloud-environments・claude-code-on-the-web の 3 ページに見当たらない。
- **結果の判定**: 履歴の Succeeded / Failed / Cancelled は「セッションがどう終わったか」であり、プロンプトの仕事を果たしたかではない [C1]。

### 3. GitHub Actions(`anthropics/claude-code-action`)

- **起動**: `prompt` 入力を渡すと automation mode になり、任意のイベントで動く(`schedule` を含む)[C9]。issue の `labeled` は `on: issues: types: [labeled]` と `label_trigger` 入力(既定値 `claude`)で受けられる [G1][A1][A3]。issue と PR のイベントでは、起動した利用者が書き込み権限を持つことを action が確かめ、bot は `allowed_bots` に無ければ拒否する [C9][A2]。`schedule` は既定ブランチでしか動かず、負荷の高いときに遅れることがあり、public リポジトリで 60 日間動きが無いと止まる [G1]。
- **設定の効き方**: ランナーは毎回新しい VM なので [G2]、利用者のマシンの `~/.claude` は無い。action は `settingSources` を既定で `["user", "project", "local"]` にし [A4]、`settings` 入力をランナーの `~/.claude/settings.json` に書き込む [A5]。checkout したリポジトリの `CLAUDE.md` と `.claude/skills/` は使える [C9]。plugin は `plugins` / `plugin_marketplaces` 入力で入れる [A1]。PR に対して動くときは、Claude を起動する前に `.claude/`・`.mcp.json`・`.claude.json`・`.gitmodules`・`.ripgreprc`・`CLAUDE.md`・`CLAUDE.local.md`・`.husky/` を PR の base ブランチの内容に戻す [A2](「Which files come from the base branch on pull requests」。一覧は `src/github/operations/restore-config.ts` の `SENSITIVE_PATHS`)。
- **権限**: プロンプトを平文で渡すと、ツールを `--allowedTools`(`claude_args`)か `settings` の `permissions.allow` で許可するまで、シェルも GitHub API も使えない [C9]。
- **隔離**: GitHub App の token は短命で、そのリポジトリにしか効かない [A2][A6]。action は Claude に渡す環境から OIDC の token 要求の変数を消す [A4]。サブプロセスの環境から秘密を消す処理と bubblewrap による PID 名前空間の分離は、資料では `allowed_non_write_users` を設定したときに有効になると書かれている。それ以外のときに有効になるかは書かれていない [A2]。外向きの通信を制限する仕組みは action の資料に見当たらない(未確認)。
- **push と PR**: GitHub App の token で push する。既定の `GITHUB_TOKEN` で作った commit では、他のワークフローが起動しない [C9][G1]。既定の設定では PR を自動で作らず、PR 作成ページへのリンクを返す [A2]。
- **署名**: commit は既定では署名されない。`use_commit_signing: true` は GitHub API で commit を作り、GitHub App の署名で verified にする。ただし rebase などの込み入った git 操作はできない。`ssh_signing_key` は git CLI で署名し、`bot_id` / `bot_name` を鍵の持ち主の GitHub アカウントに合わせる [A2][A3]。このリポジトリの `claude.yml` と `security-alerts.yml` は `use_commit_signing: true` を使う [L9]。それらの commit が実際に verified になったかは、この調査では確かめていない。
- **認証と課金**: `claude_code_oauth_token`(サブスクリプション)か `anthropic_api_key`(API 課金)を渡す [C9]。OAuth token はそれを作った人のサブスクリプションに結びつく [C9]。`claude setup-token` の token は 1 年有効で、モデルへの要求にしか使えない(claude.ai の connector は読めない)[C5]。このリポジトリでは、失効した `CLAUDE_CODE_OAUTH_TOKEN` の 401 で、定期のワークフローが 1 か月気づかれずに止まった前例がある(CLAUDE.md の "Scheduled workflow failure alerting")。public リポジトリでは標準のランナーは無料 [G2]。
- **予算**: 資料にあるのは `--max-turns` [C9][A3]。`claude_args` の残りの引数は `extraArgs` として CLI にそのまま渡る [A4] ので、`--max-budget-usd` も渡るはずである。ただし action はこれを SDK から起動していて、`--max-budget-usd` は print mode 専用と書かれている [C7]。効くかは未計測。ジョブは最長 6 時間 [G3]。
- **バージョン**: このリポジトリは `f27be6b65a4652f08a2ba3cff79114829b588967`(v1.0.252)に固定している [L9]。本書で引いた `action.yml`・`docs/security.md` の署名の節・`base-action/src/parse-sdk-options.ts` の該当箇所は、この SHA と main(`d5f7970ae232b6039636a16ea7f251e58e814f38`)とで同じだった。

### このリポジトリの `required_signatures`

- ruleset `main branch protection`(id 14661232)は既定ブランチだけを対象にし(`~DEFAULT_BRANCH`)、`required_signatures` を含む [L10]。`claude/...` のような作業ブランチには、ruleset の規則は掛からない [L10]。
- GitHub は PR をマージできるかを、head ブランチの commit を含むテストのマージ commit で評価する。このため、**head ブランチに未署名の commit があると、GitHub が最後の squash commit に署名する場合でも、squash merge が止まる**。この記述は、ruleset の規則のページにもブランチ保護のページにもある [G5][G4]。ruleset は署名を `verified_signature?` で確かめる [G5]。
- 止まった PR をマージするには、head ブランチの未署名の commit を書き直して署名するか、保護を bypass できる人にマージを頼む [G5]。このリポジトリの ruleset の `bypass_actors` には `RepositoryRole` の id 5(`bypass_mode: always`)がある [L10]。id 5 がどのロールにあたるかは一次資料で確かめていない。このリポジトリで実際に bypass してマージできるかも試していない。
- 以上から、どの実行場所でも、作業ブランチの commit が Verified でなければ、レビュー後のマージで詰まりうる。

## 所見

### tracer bullet に向く実行場所

#645 の tracer bullet は「`ready-for-agent` の issue 1 件 → 人間がレビューできる PR」で、評価には開いている `ready-for-agent` の issue 10 件を流して、人間の手が要った回数を数える。この目的に照らすと、**最初の経路は 1(launchd + nono)が向く**。理由は次のとおり。

1. **詰まりうる 2 点を実績で越えている**: 署名(PR #638 の commit が Verified)と、headless からの push と draft PR の作成(スクリプトが固定の引数で行う)は、週次ジョブの run ですでに通っている [L1][L8]。routine はどちらも未確認である。Actions には、`use_commit_signing` と `Bash(git *),Bash(gh *)` の許可で修正を試みる `security-alerts.yml` がすでにある [L9]。ただし、その commit が Verified になったかと PR を作れたかは、この調査では確かめていない。
2. **ハーネスがそのまま効く**: `~/.claude` の rules・skills(`review-verify` など)・hooks が効く実行場所は 1 だけである。このリポジトリの skills と rules の多くは `dot_claude/`(chezmoi の source)にあり、リポジトリの `.claude/` には無い。そのため 2 と 3 では、自動では読み込まれない。「人間の手が要った回数」を測る実験で、ハーネスの有無を変数に入れずに済む。
3. **1 回あたりの予算を掛けられる**: #645 は「1 回あたりの予算上限を超えたら止めて報告する」を求めている。`--max-budget-usd` は 1 では実績があり [L1]、3 では未計測、2 では手段が見当たらない。

**1 の弱み**: issue のイベントで起動できないので、スケジュールで照会することになる。tracer bullet の段階では `launchctl kickstart` で手動起動しても足りる。マシンの電源が入っていて、ログインしていることも前提になる(ログアウト中の挙動は未確認)。**`--bare` が `-p` の既定になったら**、ルールが黙って外れるか、認証で失敗する [C6]。Claude Code の更新のたびに `is_error` と読み込まれた設定を確かめる仕組みが要る。headless ではフックの `ask` が拒否になる問題 [L7] も引き継ぐ。

### 別の見方(1 を選ばない理由になりうるもの)

- **イベント駆動とマシン非依存を最初から求めるなら、3 が次点**: `issues: labeled` で起動でき、起動者の書き込み権限を action が確かめる。`use_commit_signing` で署名でき、このリポジトリには同じ action を使うワークフローがすでに 2 本ある [L9]。代わりに、`~/.claude` のハーネスが無い状態で測ることになる。OAuth token の失効という既知の止まり方もある [L2]。public リポジトリの issue 本文を入力にする以上、prompt injection の対策は action の sanitize と、ラベルを付ける人を書き込み権限者に限ることに頼る [A2]。
- **2(routine)は、tracer bullet より後に回すのがよい**: issue のイベントで起動でき、マシンにも依存しないのは魅力である。しかし次の 4 点が tracer bullet の経路の上にある。(a) commit が Verified になるか未確認で、`required_signatures` のマージで詰まりうる。(b) `gh issue` / `gh pr` が 403 になり、REST で書き直す必要がある。(c) 1 回あたりの予算の上限が無い。(d) research preview である。1 回だけ試せば (a) と (b) の答えは出るので、後続の枝で確かめる候補にする。
- **ADR 0012 との整合**: ADR 0012 が Actions を退けた理由のうち、transcript がローカルにしか無いことは、issue の処理には当てはまらない。Actions を選び直す余地はある。

## 未確認の項目

- launchd のユーザーエージェントが、ログアウト中に `StartCalendarInterval` で起動するか(man に記載が無い)。
- routine の Issue のイベントを、ラベル(`ready-for-agent`)で絞れるか。フィルタの項目は Pull request についてしか書かれていない。
- routine の GitHub のイベントの 1 時間あたりの上限の数。
- routine で、誰がラベルを付けたら起動するか(書き込み権限で絞るか)。
- routine の commit の作者(資料は「あなたの GitHub ユーザー」、公式リポジトリの報告は `Claude <noreply@anthropic.com>`)と、それが GitHub で Verified になるか。**確かめ方**: このリポジトリで 1 回 run し、push された commit の `gh api repos/{owner}/{repo}/commits/{sha} -q .commit.verification` を見る。
- routine に 1 回あたりの予算の上限を掛ける手段(資料に見当たらない)。
- Actions で `claude_args` に渡した `--max-budget-usd` が効くか。
- Actions のランナーで、外向きの通信が制限されるか(action の資料に記載が無い)。
- このリポジトリの `claude.yml` / `security-alerts.yml` が `use_commit_signing` で作った commit が、実際に Verified になっているか。
- ruleset の `bypass_actors` の `RepositoryRole` id 5 がどのロールか。このリポジトリで実際に bypass してマージできるか。
- nono の内側で claude だけが未ログインになった原因(#418 は再ログインで閉じた)。

## 出典

取得日はすべて 2026-11-11。

**リポジトリ内**(このブランチの親コミット `95cbd23` 時点)

- [L1] `.claude/rules/harness-weekly.md`
- [L2] `docs/adr/0012-self-improvement-runs-weekly-headless-inside-nono.md`
- [L3] `private_Library/LaunchAgents/local.dotfiles.harness-weekly.plist.tmpl`(コメントと `StartCalendarInterval`)
- [L4] `dot_config/git/claude-code.inc`(「背景3 (commit 署名)」)
- [L5] `dot_config/nono/CLAUDE.md`(「1Password signing, and git/gh inside the boundary」と「Accepted security residuals」の (4))
- [L6] https://github.com/tanimon/dotfiles/issues/418 (本文と最後のコメント)
- [L7] https://github.com/tanimon/dotfiles/issues/429
- [L8] https://github.com/tanimon/dotfiles/pull/638 の commit(`gh api repos/tanimon/dotfiles/pulls/638/commits -q '.[] | .commit.verification'`)
- [L9] `.github/workflows/claude.yml`、`.github/workflows/security-alerts.yml`
- [L10] `gh api repos/tanimon/dotfiles/rulesets/14661232`、`gh api repos/tanimon/dotfiles/rules/branches/main`、`gh api repos/tanimon/dotfiles/rules/branches/claude%2Fsome-branch`(後者は規則が 0 件)

**macOS**

- [M1] `man launchd.plist`(`StartCalendarInterval` と `StartInterval` の節)、`man launchd`(FILES)。macOS 27.0.1

**Claude Code の公式ドキュメント**

- [C1] https://code.claude.com/docs/en/routines
- [C2] https://code.claude.com/docs/en/cloud-environments (What carries over from your setup / GitHub proxy / Security proxy / Resource limits / Setup scripts vs. SessionStart hooks)
- [C3] https://code.claude.com/docs/en/claude-code-on-the-web (Security and isolation / GitHub authentication options)
- [C4] https://code.claude.com/docs/en/settings#settings-in-cloud-sessions
- [C5] https://code.claude.com/docs/en/authentication (Authentication precedence / Generate a long-lived token / credential の保存先)
- [C6] https://code.claude.com/docs/en/headless (Start faster with bare mode)
- [C7] https://code.claude.com/docs/en/cli-reference (`--max-budget-usd`)
- [C8] https://code.claude.com/docs/en/scheduled-tasks#compare-scheduling-options
- [C9] https://code.claude.com/docs/en/github-actions

**claude-code-action**(https://github.com/anthropics/claude-code-action 。固定の `f27be6b65a4652f08a2ba3cff79114829b588967`(v1.0.252)と main の `d5f7970ae232b6039636a16ea7f251e58e814f38` を読んだ)

- [A1] `action.yml`(`label_trigger`・`settings`・`claude_args`・`use_commit_signing`・`ssh_signing_key`・`plugins`)
- [A2] `docs/security.md`(Repository Access / Token Permissions / Which files come from the base branch on pull requests / Pull Request Creation / Commit Signing)
- [A3] `docs/usage.md`(入力の表)
- [A4] `base-action/src/parse-sdk-options.ts`(`extraArgs` のパススルー、`max-turns`、`settingSources`、OIDC の変数の削除)
- [A5] `base-action/src/setup-claude-code-settings.ts`(`~/.claude/settings.json` の書き込み)
- [A6] `docs/faq.md`(token がリポジトリに限られること)

**GitHub の公式ドキュメント**

- [G1] https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows (`schedule` の注意、`issues` の `labeled`、`GITHUB_TOKEN` が起こすイベント)
- [G2] https://docs.github.com/en/actions/reference/runners/github-hosted-runners (1 ジョブ 1 VM、public リポジトリは無料)
- [G3] https://docs.github.com/en/actions/reference/limits (ジョブは最長 6 時間)
- [G4] https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches#require-signed-commits
- [G5] https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets#require-signed-commits

**公式リポジトリの issue**(利用者の報告であり、仕様ではない)

- [I1] https://github.com/anthropics/claude-code/issues/78787 (closed, not_planned。本文を読んだ)、https://github.com/anthropics/claude-code/issues/83609 (closed, duplicate)、https://github.com/anthropics/claude-code/issues/83257 (closed, not_planned)
