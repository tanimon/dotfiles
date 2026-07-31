---
title: "未文書の Claude Code 機能はリリースバイナリの strings 二段階 grep で確定する"
date: 2026-07-30
category: developer-experience
module: claude-code-config
problem_type: developer_experience
component: tooling
severity: medium
applies_when:
  - "Claude Code の実験的機能・未公開機能を使いたいが --help にもドキュメントにも載っていない"
  - "設定キーの正式名称、受理される enum 値、有効化条件を推測ではなく確定させたい"
  - "changelog の断片的な言及だけがあり、それが機能の全体像を説明していない"
  - "ある機能が「自分のマシンでは出るが別のマシンでは出ない」理由を知りたい"
related_components:
  - documentation
  - development_workflow
tags:
  - claude-code
  - advisor-tool
  - binary-analysis
  - strings
  - undocumented-feature
  - settings-json
  - chezmoi
---

# 未文書の Claude Code 機能はリリースバイナリの strings 二段階 grep で確定する

## Context

「claude code の advisor tool を利用したい」— そう言われた時点で分かっていたのは、その機能が存在するらしいということだけだった。`claude --help` には出てこない。手元に公式ドキュメントはない。`~/.claude/cache/changelog.md` には `advisor` を含む行が 8 行あるが、いずれも断片的で、**何をすれば有効になるのか・設定キーは何という名前か・どんな値を受け付けるのか**のどれにも答えていない。

この状況で普通に取りうる手は二つある。Web を検索するか、changelog から推測するか。どちらも実験的機能には向かない — 前者は情報が存在しないか古く、後者は書かれていないことを埋められない。

三つ目の手がある。Claude Code は Bun でコンパイルされた単一実行ファイルとして `~/.local/share/claude/versions/<version>` に配置され（`~/.local/bin/claude` はそこへの symlink）、その中に minify 済みの JS バンドルがそのまま埋め込まれている。つまり**実装そのものが読める**。`strings -a` と `grep` だけで、ゲート条件の分岐ロジック、環境変数名、設定キー、enum 値、ユーザーに出る文言まで、推測を挟まずに確定できる。

この repo には同じ発想の先例がある — [`Notification` / `StopFailure` hook contract](../integration-issues/claude-code-notification-hook-contract-2026-07-25.md) は、**同じバイナリの同じバージョン**を静的に読んで hook の契約を確定させた。ただしそこには結論だけがあり、抽出手順は書かれていない。本ドキュメントはその手順の側を残すものである。

以下の記述はすべて **version 2.1.220**（`~/.local/share/claude/versions/2.1.220`、257MB）に対して実際にコマンドを実行して確認したものである。`RY`、`iZu`、`aZu`、`Z`、`Ke` といった識別子は minifier が付けた機械生成名であり、**リリースごとに変わる**。持ち越す価値があるのは手順であって、シンボル名ではない。

## Guidance

### 素朴な grep は失敗する — 二段階 grep を使う

最初に試すのはこれで、そして失敗する:

```sh
BIN=~/.local/share/claude/versions/2.1.220
strings -a "$BIN" | grep -i advisor
```

出力は **217 行で約 1.6MB**。minify された JS は 1 行が数十〜数百 KB になるため、`grep` が行全体を返した瞬間に人間もモデルも読めない塊になる。行数が少ないことが逆に罠で、`| head` を付けても何も改善しない。

機能するのは二段階構成である。

**第一段階 — 識別子を収穫する。** 行を返させず、マッチした語だけを `-o` で抜き出し、頻度で並べる:

```sh
strings -a "$BIN" | grep -oE "[A-Za-z_]*[Aa]dvisor[A-Za-z_]*" | sort | uniq -c | sort -rn | head -20
```

これで機能の内部語彙と、おおよその実装上の重みが一度に手に入る:

```
 150 advisor
  56 advisorModel
  46 Advisor
  24 advisory
  24 AdvisorTool
  21 advisor_tool_result
  18 advisories
  13 advisor_rank
   7 advisor_model
   6 advisor_tool_result_error
   5 BetaAdvisorTool
```

**大文字の識別子はこの正規表現では取れない。** `[Aa]dvisor` は `ADVISOR` にマッチしないため、環境変数名は上のリストに現れない。別パスが要る:

```sh
strings -a "$BIN" | grep -oE "[A-Z_]*ADVISOR[A-Z_]*" | sort | uniq -c | sort -rn
#    6 CLAUDE_CODE_ENABLE_EXPERIMENTAL_ADVISOR_TOOL
#    6 CLAUDE_CODE_DISABLE_ADVISOR_TOOL
```

環境変数・定数・SCREAMING_SNAKE_CASE は必ず別クエリで拾うこと。第一段階を一度しか回さないと、機能の**入口そのもの**を取り逃す。

**第二段階 — 収穫した識別子の周囲を固定幅で切り出す。** 行ではなく窓を返させる:

```sh
strings -a "$BIN" | grep -oE "function RY\(\).{0,600}"
strings -a "$BIN" | grep -oE "iZu=\[.{0,60}"
strings -a "$BIN" | grep -oE ".{150}advisorModel.{250}" | sort -u | head
```

`.{150}前方 + 識別子 + .{250}後方` の形にすると、minify された関数本体・zod スキーマ断片・定数配列がそのまま読める単位で返ってくる。`sort -u` は同一窓の重複を潰すために効く。

### 二段階目を繰り返すならバンドルを一度キャッシュする

`.{N}` の窓が広いと ugrep が `exceeds complexity limits` で拒否したり、257MB を毎回スキャンして分単位で待たされたりする。マッチ行を一度ファイルに落としてから grep すると桁で速くなる:

```sh
strings -a "$BIN" | grep -i advisor > "$TMPDIR/advisor-lines.txt"   # 217 行 / 1.6MB
grep -oE '.{160}_i\("userSettings",\{advisorModel.{0,120}' "$TMPDIR/advisor-lines.txt"
```

正規表現の複雑度で弾かれた場合は perl に逃がすと通る:

```sh
perl -ne 'while (/(.{0,50}--advisor.{0,300})/g) { print "$1\n---\n" }' "$TMPDIR/advisor-lines.txt" | sort -u
```

### この手順が実際に確定させたこと（2.1.220）

**有効化ゲート。** 4 分岐が 1 関数に収まっている:

```js
function RY(){if(Z.CLAUDE_CODE_DISABLE_ADVISOR_TOOL)return!1;if(xn()!=="firstParty"||!DH())return!1;if(Z.CLAUDE_CODE_ENABLE_EXPERIMENTAL_ADVISOR_TOOL)return!0;return Ke("tengu_sage_compass2",{}).enabled??!1}
```

読み下すと、(1) `CLAUDE_CODE_DISABLE_ADVISOR_TOOL` が最優先の kill switch、(2) 認証が `firstParty` でなければ不可 — Bedrock / Vertex 経由は対象外、(3) `CLAUDE_CODE_ENABLE_EXPERIMENTAL_ADVISOR_TOOL` があれば強制的に有効、(4) どれでもなければサーバー側ロールアウトフラグ `tengu_sage_compass2` 次第。

**明示的な env オプトインが要る理由はこの (4) にある。** 何も設定しなければ、機能が存在するかどうかがマシンごと・日ごとに変わる。再現しない挙動は設定として管理できない。

**設定キー。** zod スキーマに定義がある:

```js
advisorModel:E.string().optional().describe("Advisor model for the server-side advisor tool.")
```

**受理されるエイリアス。**

```js
iZu=["fable","opus","sonnet"]
```

**隠し CLI フラグ。** `--help` に出ないのは `.hideHelp()` が付いているからで、フラグ自体は登録されている:

```js
t.addOption(new id("--advisor <model>","Enable the server-side advisor tool with the specified model (alias or full ID).").hideHelp())
```

**`/advisor` はユーザー設定ファイルを書き換える。** 有効化は `_i("userSettings",{advisorModel:i})`、無効化は `_i("userSettings",{advisorModel:void 0})` — いずれも `~/.claude/settings.json` への書き込みである。

**ペアリング制約。** モデルは `advisor_rank` を持ち、比較関数はこうなっている:

```js
function aZu(e,t){let r=Ews(e),n=vws(t);if(r===void 0||n===void 0)return!0;return r<=n}
```

`e` が executor（メインモデル）、`t` が advisor で、成立条件は `executor の rank <= advisor の rank`。つまり **advisor はメインモデル以上でなければ main には attach されない**（同ランクは可）。どちらかの rank が未定義なら素通しになる。条件を満たさないとき、失敗は例外にならず静かに素通りする。唯一の手がかりは起動時の通知文言である:

```
Advisor will not activate on the main model (advisor is less capable); subagents may still use it and may use more tokens · /advisor
```

有効なときは `Advisor Tool (experimental) is on and may use more tokens · /advisor`。デバッグログには `[AdvisorTool] Skipping advisor - base model ${t} does not support advisor` と `[AdvisorTool] Skipping advisor - ${advisorModel} cannot advise non-configured attempt model ${mt} (configured: ${gr})` の 2 系統がある。

**推奨構成はダイアログ自身が明言している。** UI コンポーネント内の文字列:

> Recommended setup: Sonnet as the main model with Opus as the advisor. For certain workloads this gives near-Opus performance with reduced token usage.

**API 側の beta 識別子。** `advisor-tool-2026-03-01`（5 箇所）。

## Why This Matters

**推測が要らなくなる。** 上の 8 項目は、どれ一つとして changelog の 8 行からは導けない。`fable` がエイリアスとして受理されることも、`advisor_rank` によるペアリング制約が存在することも、それに違反したときの失敗が**サイレント**であることも、実装を読まなければ分からない。特に最後の一点は重要で、「設定したのに効いていない」を通知文言 1 行だけを手がかりに診断する羽目になる。事前に知っているのと知らないのとで、デバッグ時間が桁で違う。この「設定キーが黙って意味を失う」失敗は、この repo が[別の形で記録している族](../integration-issues/harness-silent-failures-scheduled-workflows-and-plugin-rename.md)と同じものである。

**ロールアウトフラグの存在は、設定戦略そのものを変える。** `tengu_sage_compass2` が最終分岐にあると分かった時点で、「とりあえず使ってみて動いたら設定に書く」という手順が成り立たなくなる。動いたのがフラグのおかげなら、明日は動かない。`CLAUDE_CODE_ENABLE_EXPERIMENTAL_ADVISOR_TOOL` を明示的に置く判断は、この 1 行を読んだ結果として出てくるものであって、試行錯誤からは出てこない。

**素朴な grep の失敗の仕方が特徴的。** エラーにならない。実行は成功し、出力も返る。ただ人間が読めないだけである。ここで「grep では分からなかった」と結論して Web 検索に戻るのが典型的な取り逃しで、実際には**クエリの形が悪かっただけ**で情報は全部そこにあった。この repo が別の文脈で繰り返し記録している「緑に見えるが何も検証していないチェック」（[verification-through-the-wrong-resolution-path](../workflow-issues/verification-through-the-wrong-resolution-path.md)）と同じ族の失敗である — 手法が答えを持っていないのではなく、答えに届かない使い方をしている。

**バージョン固定は付帯事項ではなく前提。** `RY`、`iZu`、`aZu` は minifier の生成名で、次のリリースでは別の文字列になる。ここに書いた**シンボル名を検索しても次のバージョンではヒットしない**。持ち越せるのは「二段階 grep をバンドルに当てる」という手順と、`advisorModel` / `CLAUDE_CODE_*` / `advisor_rank` のような**ソース由来で minify されない**識別子だけである。設定キー名・環境変数名・ログ文字列・ユーザー向け文言はソースの文字列リテラルなので minify を生き延びる — 逆に言えば、調査の足がかりにすべきはこちら側である。

## When to Apply

この手順が最短経路になるのは:

- Claude Code の機能が `--help` にも公開ドキュメントにも見当たらないが、存在の痕跡（changelog、UI のちらつき、他人の言及）がある
- 設定キーの正確な綴りや、受理される値の集合を確定させたい — `"opus"` なのか `"claude-opus-5"` なのか、`true` なのか `"1"` なのか
- 「有効にしたはずなのに効かない」の原因を、条件分岐そのものから特定したい
- ある機能がマシンによって出たり出なかったりする理由を知りたい（サーバー側フラグの有無はバイナリに書いてある）

向かないのは:

- 挙動の**意図**や設計上の理由が知りたい場合 — 実装は what を答えるが why を答えない
- API 側でしか完結していない機能 — バイナリにはリクエストの組み立てまでしか無い
- バージョンをまたいで安定した知識が欲しい場合 — 得られる知識は毎回固定バージョンに紐づく

## Examples

### 失敗する形と機能する形

```sh
BIN=~/.local/share/claude/versions/2.1.220

# Before: 実行は成功するが 217 行 / 1.6MB が返るだけで読めない。
strings -a "$BIN" | grep -i advisor

# After 第一段階: 語彙と重みが一望できる。
strings -a "$BIN" | grep -oE "[A-Za-z_]*[Aa]dvisor[A-Za-z_]*" | sort | uniq -c | sort -rn | head -20
# 大文字系は別クエリ（[Aa]dvisor では ADVISOR に当たらない）。
strings -a "$BIN" | grep -oE "[A-Z_]*ADVISOR[A-Z_]*" | sort | uniq -c | sort -rn

# After 第二段階: 収穫した識別子の周囲を窓で切る。
strings -a "$BIN" | grep -oE "function RY\(\).{0,600}"
strings -a "$BIN" | grep -oE "iZu=\[.{0,60}"
strings -a "$BIN" | grep -oE ".{150}advisorModel.{250}" | sort -u | head
```

### この repo への適用

確定した事実をもとに `dot_claude/settings.json.tmpl` に 2 箇所を追加した（ブランチ `tanimon/add-claude-code-advisor` 上、**未マージ**）:

- `env` セクション: `"CLAUDE_CODE_ENABLE_EXPERIMENTAL_ADVISOR_TOOL": "1"` — ロールアウトフラグ依存を外し、マシン間で挙動を固定するため
- トップレベル: `"advisorModel": "opus"` — 既存の `"model": "sonnet"` と対にする。これはダイアログ自身が推奨として提示している組み合わせであり、同時に `aZu` の `executor rank <= advisor rank` を満たす自明な選び方でもある

検証は 2 段構えで行った。`make check-templates` は PASS したが、**それだけでは足りない** — このターゲットはテンプレートが render できることしか見ておらず、出力が妥当な JSON かも、意図した内容が入ったかも検査しない（[check-templates renders only, it does not validate JSON](../integration-issues/check-templates-render-only-no-json-validation.md)）。実際の担保は render して `jq` に通すこちら側にある:

```sh
tmpconfig=$(mktemp "${TMPDIR:-/tmp}/cc-test-XXXXXX.toml")
printf '[data]\n  profile = "personal"\n  ghOrg = "test-org"\n' > "$tmpconfig"
chezmoi execute-template --config "$tmpconfig" --source "$(pwd)" \
  < dot_claude/settings.json.tmpl \
  | jq '{advisorModel, model, advisorEnv: .env.CLAUDE_CODE_ENABLE_EXPERIMENTAL_ADVISOR_TOOL}'
rm -f "$tmpconfig"
```

```json
{
  "advisorModel": "opus",
  "model": "sonnet",
  "advisorEnv": "1"
}
```

`--source "$(pwd)"` は必須。worktree から実行する場合、これが無いと chezmoi は設定された source dir（`main`）を読み、ブランチ上の変更が反映されないまま緑になる。

### repo 固有の罠 — `/advisor` の書き込みは apply で消える

`/advisor` ダイアログは `_i("userSettings",{advisorModel:...})` で `~/.claude/settings.json` を直接書き換えるが、そのファイルは `dot_claude/settings.json.tmpl` が全面所有している。したがって **`/advisor` で設定した内容は次の `chezmoi apply` で無言のうちに消える**。

これ自体は新しい発見ではなく、この repo で記録される 3 例目である — [chezmoi full-template drift](../integration-issues/chezmoi-full-template-drift.md) が `/config` について、`CLAUDE.md` の Known Pitfalls が nono パックの `enabledPlugins` について、同じ形を既に述べている。`/advisor` はその新しい書き手にすぎない。一般形として押さえるべきは「`~/.claude/settings.json` に書き込むアプリ内の書き手は複数あり、そのどれもが apply で消える」であり、恒久的な設定は必ず tmpl 側に書く。`/advisor` はセッション内の一時的な切り替えとしてのみ使う。

## Verification Notes

すべて `~/.local/share/claude/versions/2.1.220` に対して本セッションで再実行して確認した: 識別子の頻度表、`CLAUDE_CODE_ENABLE_EXPERIMENTAL_ADVISOR_TOOL` / `CLAUDE_CODE_DISABLE_ADVISOR_TOOL`（各 6 箇所）、`function RY()` の全文、`iZu=["fable","opus","sonnet"]`、`advisorModel` の zod スキーマ行、`--advisor <model>` の `.hideHelp()` 付き登録、`_i("userSettings",{advisorModel:...})` の 2 形、`function aZu(e,t)` の `r<=n` 比較、起動時通知の 2 文言、推奨構成の文言、`advisor-tool-2026-03-01`（5 箇所）。`~/.claude/cache/changelog.md` の `advisor` 該当行数が 8 であることも確認済み。

素朴な grep の出力量として本文に記した「217 行 / 約 1.6MB」は本セッションでの実測値（`strings -a "$BIN" | grep -i advisor`）。grep の変種や `-o` の有無で数値は変わるため、桁として受け取るのが正しい。

`xn()`、`DH()`、`Ke()`、`Ews()`、`vws()` の各実装内容そのものは追跡していない — `RY()` 内での役割（認証種別の判定、追加ゲート、フラグ参照、rank 取得）は呼び出し文脈から読み取ったものであり、各関数本体を展開して確認したわけではない。

## Related

- [Claude Code `Notification` / `StopFailure` hook contract](../integration-issues/claude-code-notification-hook-contract-2026-07-25.md) — 同じバイナリ・同じバージョン（2.1.220）を静的に読んで未文書の契約を確定させた先行事例。結論は残っているが手順は残っていない。本ドキュメントはその手順側の補完にあたる。
- [check-templates renders only, it does not validate JSON](../integration-issues/check-templates-render-only-no-json-validation.md) — JSON 形状の `.tmpl` を編集した後に render-then-`jq` を回す必要がある理由。本ドキュメントの検証手順はここに従っている。
- [A verification that resolves a different path than the artifact under test passes vacuously](../workflow-issues/verification-through-the-wrong-resolution-path.md) — `--source "$(pwd)"` が要る理由と、「緑だが何も見ていないチェック」の一般形。
- [chezmoi full-template drift](../integration-issues/chezmoi-full-template-drift.md) — 全面所有された `.tmpl` に対して、デプロイ先を書き換える側の変更が失われる話。`/advisor` はその 3 例目の書き手。
- [Harness silent failures](../integration-issues/harness-silent-failures-scheduled-workflows-and-plugin-rename.md) — 設定キーが現実と一致しなくなり、エラーなしで機能が止まる失敗の族。advisor のペアリング制約違反も同じ形で黙って無効になる。
- `CLAUDE.md` Known Pitfalls の `enabledPlugins` の項 — 外部ツールが `~/.claude/settings.json` に書き、chezmoi が消す、という同型の失敗。
