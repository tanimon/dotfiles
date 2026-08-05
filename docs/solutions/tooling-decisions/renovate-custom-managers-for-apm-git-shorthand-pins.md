---
title: Renovate の customManagers で apm.yml の git shorthand pin を ref 形状ごとに3系統に分けて自動更新する
date: 2026-08-06
category: tooling-decisions
module: Renovate 設定 (renovate.json の customManagers / packageRules) と APM グローバルマニフェスト (dot_apm/apm.yml)
problem_type: tooling_decision
component: tooling
severity: medium
applies_when:
  - "標準マネージャが対応しない独自フォーマットの依存記述に Renovate の自動更新を効かせたいとき(例: `dot_apm/apm.yml` の `dependencies.apm` に並ぶ `owner/repo[/subpath]#ref` 形式の git shorthand pin)"
  - "同一ファイル内の pin が複数の ref 形状(素の `vX.Y.Z` タグ / リポジトリ固有プレフィックス付きタグ / タグを持たないコミット SHA)に分かれており、単一の customManager では表現しきれないとき"
  - "1つのリポジトリに無関係な複数のタグ系列が同居していて、Renovate 既定の semver 比較だと意図しない系列が最新として選ばれてしまうとき(monorepo が複数プラグインのタグを共有している場合)"
  - "タグを持たない(またはタグのコミットが現在の pin とずれている)リポジトリを `git-refs` datasource で追跡する必要があり、どのブランチを追うかという情報を設定ファイル側に持たせたいとき"
  - "`git-refs` の追跡対象が高頻度に更新されるリポジトリで、ブランチ HEAD 追従による PR の際限ない量産を抑えたいとき"
tags:
  - renovate
  - custom-managers
  - apm
  - git-refs
  - github-tags
  - versioning-template
  - dependency-automation
  - chezmoi
related_components:
  - "renovate.json"
  - "dot_apm/apm.yml"
  - ".claude/rules/renovate-external.md"
  - ".chezmoiexternal.toml"
  - "development_workflow"
---

# Renovate の customManagers で apm.yml の git shorthand pin を ref 形状ごとに3系統に分けて自動更新する

## Context

`dot_apm/apm.yml` の `dependencies.apm` は、Claude Code プラグインを git shorthand（`owner/repo[/subpath]#ref`）で列挙する。この形式は APM（microsoft/apm）独自のもので、Renovate が標準マネージャーで解釈できるパッケージフォーマットではない。そのため、この作業以前は `CLAUDE.md` 自身が「タグを持たない一部のピンは Renovate のタグベース更新の対象外であり、手動での bump が必要」と明記していた（`CLAUDE.md` の該当文は本作業で書き換え済み）。

同じリポジトリでは `.chezmoiexternal.toml` が既に `customManagers` の regex マネージャーで自動更新されており（`renovate.json` 内の最初のエントリ）、その運用契約は [renovate-external.md](../../../.claude/rules/renovate-external.md) に文書化されている。したがって「同じ手口を `dot_apm/apm.yml` にも適用する」ことが出発点だった。

**しかし、単一の汎用 regex マネージャー（`owner/repo#ref` を素朴にパースするもの）では正しく動作しない。** 設定を書く前に、9 件の `dependencies.apm` エントリそれぞれについて上流の実状を GitHub API で確認した結果、1 つのマネージャーでは扱い分けられない 3 つの異なる状況が判明したためである（以下はいずれも 2026-08-06 時点の観測。GitHub の状態は変化するので、再確認は記載のコマンドで行うこと）。

- **タグを一切公開していないリポジトリ**が 2 つ存在した（`anthropics/claude-plugins-official`、`getsentry/plugin-claude`）。`gh api repos/<owner>/<repo>/tags` が空を返す。タグ datasource では追跡できず、digest 追跡が必要。
- **タグはあるが、現在ピンしているコミットがどのタグにも対応しないリポジトリ**が 1 つあった（`nolabs-ai/nono-packs`）。最も近い名前のタグ `claude-v0.1.0` は、ピン中の SHA とは別のコミットを指していた。ここでタグへ移行すると、それは「更新」ではなく別コミットへの黙ったすり替えになる。
- **同一タグリストの中に無関係な 2 系統の命名規則が混在するリポジトリ**が 1 つあった（`EveryInc/compound-engineering-plugin`）。monorepo 内の別プラグイン由来と思われる `v2.42.0` 系と、実際に必要な `compound-engineering-v3.21.x` 系が並存している。デフォルトの `semver` versioning はこの 2 系統を区別できず、誤った「最新」を選びうる。

つまり、この形式に Renovate を効かせるという課題は「正規表現を 1 本書く」問題ではなく、**ref の形状ごとに datasource と versioning を切り分ける設計**の問題だった。

## Guidance

### 1. 正規表現を書く前に、上流のタグ・デフォルトブランチを API で確認する（推測しない）

`renovate.json` に一文字も書く前に、対象エントリ全件について実際の GitHub API を叩く。

```sh
gh api repos/<owner>/<repo>/tags                    # タグを公開しているか、命名規則は何か
gh api repos/<owner>/<repo> --jq .default_branch    # デフォルトブランチは本当に main か
gh api repos/<owner>/<repo>/commits                 # コミット頻度（後述の schedule 判断に使う）
```

この確認を先に行わないと、上に挙げた 3 つの状況すべてが「設定は書けたが黙って誤動作する」形で顕在化する。`.claude/rules/renovate-external.md` はこれをルール化して「デフォルトブランチを `main` と仮定するな」と明記している。

### 2. ref の形状ごとにマネージャーを分ける（3 マネージャー構成）

`renovate.json` の `customManagers` には `dot_apm/apm.yml` 向けに 3 つの regex エントリが入っている。いずれも `managerFilePatterns: ["/dot_apm\\/apm\\.yml$/"]`（`/` デリミタ必須。これは同リポジトリの既知の落とし穴で、[renovate-managerfilepatterns-regex-delimiter.md](../integration-issues/renovate-managerfilepatterns-regex-delimiter.md) に記録がある。デリミタが無いと Renovate は minimatch glob として解釈し、マネージャーが黙って無効化される）。

| ref の形状 | マネージャー | datasource |
|---|---|---|
| 40 桁コミット SHA + 行末 `# renovate: branch=<branch>` | digest マネージャー | `git-refs` |
| `compound-engineering-vX.Y.Z`（リポジトリ固有プレフィックス） | 専用プレフィックスマネージャー | `github-tags` + `versioningTemplate` |
| `vX.Y.Z` | 汎用タグマネージャー | `github-tags`（デフォルト semver） |

### 3. プレフィックス付きタグには `extractVersionTemplate` ではなく `versioningTemplate: regex:...` を使う

これが本作業で最も重要な訂正点である。実装前のレビューで、初稿の計画にあった `extractVersionTemplate` の使用が誤りだと判明した。

- `extractVersionTemplate` は、**ファイルに書き戻される値**からマッチしたプレフィックスを剥ぎ落とす。`#compound-engineering-v3.21.0` が `#3.21.2` のような文字列に置換され、**上流に存在しない ref** になる。ピンは壊れるが、Renovate は正常に PR を作ったように見える。
- 正しい機構は `versioningTemplate` である。これは**比較**の対象を指定パターンに一致するタグだけに制約し、書き戻される値は生のタグ文字列のまま維持する。

`renovate.json` の実際の記述:

```json
"versioningTemplate": "regex:^compound-engineering-v(?<major>\\d+)\\.(?<minor>\\d+)\\.(?<patch>\\d+)$"
```

これにより、同じタグリストに混在する `v2.42.0` 系は比較候補から外れ、`compound-engineering-v*` 系だけが「最新」判定の母集団になる。

なお、この「`#3.21.2` が書き戻される」という挙動は Renovate の文書化された機構からの帰結であり、本作業では実際には**実行して観測していない**（後述のとおり検証は `--dry-run=lookup` までで、書き戻し・ブランチ作成フェーズは通していない）。機構としての根拠であって観測結果ではない、という区別は保っておくべきである。

### 4. タグ無し + 高コミット頻度のリポジトリは schedule で絞る

初稿の計画では `anthropics/claude-plugins-official`（タグ無し）を `git-refs` のブランチ HEAD 追跡で、スロットリング無しに扱うつもりだった。`gh api repos/anthropics/claude-plugins-official/commits` でコミット履歴を確認すると、観測した一区間で**約 3 分間に 9 コミット**という極端な頻度だった（2026-08-06 時点）。素朴なブランチ HEAD 追跡では、Renovate がほぼ毎回「新しい最新コミット」を見つけて更新提案を出し続けることになる。

対処は `renovate.json` の `packageRules` 1 件で、**`dot_apm/apm.yml` 由来の `git-refs` datasource の更新だけ**を週次に絞る。リポジトリ内の他の Renovate 管理依存関係（`.chezmoiexternal.toml` の git-refs を含む）は通常の頻度のままにしておく点が重要である。

```json
{
  "matchManagers": ["custom.regex"],
  "matchFileNames": ["dot_apm/apm.yml"],
  "matchDatasources": ["git-refs"],
  "schedule": ["before 6am on monday"]
}
```

### 5. YAML の `#` コメント境界を理解した上でアノテーションを付ける

digest マネージャーはブランチ名をインラインコメントから読む。git shorthand 自体が `#` を ref セパレータとして使うため、一見衝突しそうに見えるが安全に共存する。

**YAML では `#` がコメントを開始するのは直前に空白がある場合のみ。** git shorthand の `#ref` セパレータには直前の空白が無いので、

```yaml
- owner/repo#deadbeef... # renovate: branch=main
```

は「`owner/repo#deadbeef...` という 1 つのスカラー」＋「本物のコメント」として解析される。この性質は `.claude/rules/renovate-external.md` に理由込みで明記した。

### 6. depName 抽出は subpath を落とす — 意図的な設計

digest マネージャーと汎用タグマネージャーの正規表現には、オプショナルな非キャプチャグループ `(?:/[\w./-]+)?` が入っている。

```
-\s+(?<depName>[\w.-]+/[\w.-]+)(?:/[\w./-]+)?#(?<currentDigest>[0-9a-f]{40})\s*#\s*renovate:\s*branch=(?<currentValue>\S+)
```

`depName` は 2 セグメントだけを捕まえ、subpath はこの非キャプチャグループが飲み込む。git 上のアイデンティティは in-repo パスではなくリポジトリだからである（`anthropics/claude-plugins-official/plugins/foo` → `anthropics/claude-plugins-official`）。結果として、同一 repo+SHA を指す複数の subpath エントリは独立した依存関係として抽出されるが、更新先 digest が同一なので追加の `packageRules` グルーピング無しに同じ Renovate ブランチ／PR に収束する。

compound-engineering 専用マネージャーにはこのグループが**無い**。当該エントリに subpath が無いためである。

### 7. マネージャー同士が食い合っていないことを確認する

汎用タグマネージャーの `currentValue` は `#` の直後にアンカーされている（`#(?<currentValue>v\d+\.\d+\.\d+)`）。`#compound-engineering-v3.21.0` は `#` の直後が `c` なのでこのパターンにマッチしない。行内に別のマッチ位置も生じない（`-\s+` という行頭のリスト項目プレフィックスが必要で、`compound-engineering` 内の `-` は直後が空白でない）。

**この推論を実際に検証できる観測値がある**: dry-run が抽出した依存関係は 9 件だった。汎用マネージャーが compound-engineering の行も二重に拾っていれば 10 件になっていたはずである。件数一致が、マネージャー間の非重複を再現可能な形で裏づけている。

## Why This Matters

各ルールが防いでいる失敗モードは、いずれも「静かに壊れる」種類のものである。

**`versioningTemplate` vs `extractVersionTemplate`（ピンの黙った破壊）** — `extractVersionTemplate` を使うと、Renovate は成功したように見える PR を作りながら、上流に存在しない ref をファイルに書き込む。壊れるのは PR マージ後の `apm install` 実行時、つまり Renovate の出力を見ている場所から離れたところである。Renovate の設定バリデーターもこの誤りを検出しない（文法的には正当な設定だから）。

**schedule によるスロットリング（PR スパム）** — 3 分に 9 コミットのリポジトリを無制限にブランチ HEAD 追跡すると、Renovate はほぼ毎回更新提案を出す。実害は PR ノイズそのものよりも、それによって**他の本当に重要な更新提案が埋もれる**ことにある。加えて、この種のノイズは「Renovate を無効化する」方向の対処を誘発しやすい。

**API で事前確認する（`main` 決め打ち・タグ誤対応）** — デフォルトブランチを誤ると digest マネージャーは追跡対象ブランチを見つけられない。より厄介なのは `nolabs-ai/nono-packs` のケースで、名前が近いタグ（`claude-v0.1.0`）へ機械的に移行すると、それは更新ではなく**別コミットへのすり替え**になる。名前の近さは同一性の証拠ではない。

**`managerFilePatterns` の `/` デリミタ（マネージャーの黙った無効化）** — このリポジトリでは既に一度踏んでいる（[renovate-managerfilepatterns-regex-delimiter.md](../integration-issues/renovate-managerfilepatterns-regex-delimiter.md)）。デリミタを忘れるとマネージャーはゼロファイルにマッチし、エラーも警告も出さずに「更新提案が来ない」状態になる。設定を書いた側からは、単に更新が無いのと区別がつかない。

これらに共通するのは、[verification-through-the-wrong-resolution-path.md](../workflow-issues/verification-through-the-wrong-resolution-path.md) が指す形である — **チェックが空虚に通ってしまう**。だからこの種の設定は、書いた後に実際に走らせて抽出結果を目で確認する必要がある。

## When to Apply

- **git shorthand や、それに類する構造の緩い依存記述フォーマットを Renovate の custom regex manager でピン管理するとき。** 標準マネージャーが無いフォーマット全般（独自の manifest、シェルスクリプト内のバージョン変数、Dockerfile 以外のイメージ参照など）に同じ設計判断が必要になる。
- **monorepo がサブパッケージごとにタグプレフィックスを分けているとき。** デフォルト semver は無関係なタグ系統を混同する。`versioningTemplate: regex:...` でプレフィックスに限定する。
- **追跡対象リポジトリがタグを公開しておらず、かつコミット頻度が高いとき。** digest 追跡が避けられないなら `schedule` でスロットリングする。スロットリングの範囲は、当該ファイル／datasource に限定して他の依存関係に波及させない。
- **ref の形状が 1 つのファイル内で混在しているとき。** 1 本の巨大な正規表現に詰め込むより、形状ごとにマネージャーを分けた方が、datasource と versioning を正しく割り当てられるうえ、後から形状が増えたときに既存の挙動を壊さずに追加できる。

逆に、上流が単一の一貫したタグ命名規則を持ち、コミット頻度も穏当なら、汎用タグマネージャー 1 本で足りる。3 マネージャー構成はこのファイルの実態（3 つの異なる状況が同居している）に対する応答であって、無条件に推奨される形ではない。

## Examples

`renovate-apm-manifest-support` ブランチのワーキングツリー上で実装(未コミット・未マージ)。変更は 4 ファイル。

### `renovate.json` — 3 マネージャー + 1 packageRule の追加

`.chezmoiexternal.toml` 向けの既存マネージャーは変更なし。以下 3 件を追加。

digest / git-refs マネージャー:

```json
{
  "customType": "regex",
  "managerFilePatterns": ["/dot_apm\\/apm\\.yml$/"],
  "matchStrings": [
    "-\\s+(?<depName>[\\w.-]+/[\\w.-]+)(?:/[\\w./-]+)?#(?<currentDigest>[0-9a-f]{40})\\s*#\\s*renovate:\\s*branch=(?<currentValue>\\S+)"
  ],
  "datasourceTemplate": "git-refs",
  "packageNameTemplate": "https://github.com/{{{depName}}}"
}
```

プレフィックス付きタグ専用マネージャー — `versioningTemplate` の使用が要点:

```json
{
  "customType": "regex",
  "managerFilePatterns": ["/dot_apm\\/apm\\.yml$/"],
  "matchStrings": [
    "-\\s+(?<depName>[\\w.-]+/[\\w.-]+)#(?<currentValue>compound-engineering-v\\d+\\.\\d+\\.\\d+)"
  ],
  "datasourceTemplate": "github-tags",
  "packageNameTemplate": "{{{depName}}}",
  "versioningTemplate": "regex:^compound-engineering-v(?<major>\\d+)\\.(?<minor>\\d+)\\.(?<patch>\\d+)$"
}
```

汎用 `vX.Y.Z` マネージャーはデフォルト semver のまま、subpath 対応の非キャプチャグループのみ持つ。スロットリングは `packageRules`（本文 Guidance 4 に全文掲載）。

### `dot_apm/apm.yml` — bare-SHA ピン 6 行へのインラインアノテーション

変更前（アノテーション無し。digest マネージャーがブランチを特定できない）:

```yaml
    - anthropics/claude-plugins-official/plugins/commit-commands#a473e6e809e0866cdf7798e2d534f03c0367036b
    - getsentry/plugin-claude#4b61acc29f8c5f29ad7a8851ba521a24d4f118fe
    - nolabs-ai/nono-packs/claude#58f77c73a949bad1a9e261bb824c51e323589984
```

変更後（3 リポジトリすべてのデフォルトブランチが実際に `main` であることを API で確認済み）:

```yaml
    - anthropics/claude-plugins-official/plugins/commit-commands#a473e6e809e0866cdf7798e2d534f03c0367036b # renovate: branch=main
    - getsentry/plugin-claude#4b61acc29f8c5f29ad7a8851ba521a24d4f118fe # renovate: branch=main
    - nolabs-ai/nono-packs/claude#58f77c73a949bad1a9e261bb824c51e323589984 # renovate: branch=main
```

タグでピンされている 3 行はアノテーション不要で無変更 — `obra/superpowers#v6.2.0`、`EveryInc/compound-engineering-plugin#compound-engineering-v3.21.0`、`affaan-m/everything-claude-code#v2.1.0`。

### ドキュメント側

- `CLAUDE.md` — 「タグベース更新の対象外なので手動 bump が必要」という記述が事実でなくなったため、3 マネージャー構成の要約に書き換え、`.claude/rules/renovate-external.md` へのリンクを追加。
- `.claude/rules/renovate-external.md` — スコープを `.chezmoiexternal.toml` 専用から拡張し、`dot_apm/apm.yml` の契約を追加。ref 形状 → マネージャー → datasource の対応表と、今後 `dependencies.apm` にエントリを追加する際のチェックリスト。

### 検証

実際にツールを走らせて確認した内容と、確認できていない範囲を分けて記す。

**APM 側の非破壊性（確認済み）** — 実際の APM CLI v0.27.0 で、編集後の `dot_apm/apm.yml` のコピーに対し `apm lock` を実行。9 件すべてが**変更前と同一のコミット／タグに解決**された。インラインコメント追加がこのファイルを消費する本来の依存マネージャーの挙動を変えていないことの確認。

**Renovate の抽出（確認済み）** — `npx renovate --platform=local --dry-run=lookup` を、編集後の実ファイルに対して実行（`RENOVATE_TOKEN` に実 GitHub トークンが必要。`RENOVATE_HOST_RULES` のみでは `github-token-required` でスキップされる）。9 件全件について `depName` / `packageName` / `currentValue` / `currentDigest` が意図どおり抽出された。`anthropics/claude-plugins-official/plugins/...` の 4 行の subpath 除去も含む。抽出件数が 10 でなく 9 だったことが、マネージャー間の非重複の裏づけになっている（Guidance 7 参照）。

**lookup フェーズ（部分的）** — `github-tags` の 3 件は lookup を正常通過。`git-refs` の 6 件は raw git protocol に対するサンドボックスのプロキシ制限（`Proxy CONNECT aborted`）でのみ失敗した。これを環境要因と判断した根拠は**対照**である: 同一実行内で、既存かつ動作実績のある `.chezmoiexternal.toml` の git-refs マネージャーが**まったく同じ失敗モード**を示した。新設定固有の欠陥なら、既存マネージャーは通っていたはずである。ただしこれは環境要因であることの強い証拠であって、git-refs 側の lookup が本番で成功することの直接的な証明ではない。同様に、書き戻し・ブランチ作成フェーズは `--dry-run=lookup` の範囲外なので通していない。

**その他（確認済み）** — `npx --package renovate -- renovate-config-validator` がスキーマ検証を通過。`make oxfmt`、`make check-templates`、`make scan-sensitive` いずれも指摘なし。

## Related

- [renovate-external.md](../../../.claude/rules/renovate-external.md) — この変更で拡張した、`.chezmoiexternal.toml` と `dot_apm/apm.yml` 両方を対象とする Renovate 運用契約の本体。ref 形状 → マネージャー → datasource の対応表と、今後のエントリ追加チェックリストはここにある。本ドキュメントはその実装経緯・調査過程を記録するものであり、契約そのものを重複記載しない。
- [chezmoi-external-script-repo-with-renovate-sha-pinning.md](../integration-issues/chezmoi-external-script-repo-with-renovate-sha-pinning.md) — `type = "archive"` + SHA-in-URL + `# renovate: branch=` + git-refs カスタムマネージャーという元々のパターンの由来。本ドキュメントの digest マネージャーはこのパターンをそのまま再利用している。**リフレッシュ候補**: 同ドキュメントの Key Insight #2「Renovate regex requires strict line adjacency」は TOML 前提の説明（`\s+` が空行を許容し TOML キーの割り込みを許容しない、という書き方）に留まっており、YAML 側（本ドキュメントが実装した `dot_apm/apm.yml` の契約）の「`#` の直前の空白が YAML コメント境界を決める」という異なる、より厳密な力学までは踏み込んでいない。フォーマットごとに契約が異なる旨を一般化するか、本ドキュメントへの参照を追加する形での更新を推奨する（`ce-compound-refresh` の対象候補）。
- [renovate-managerfilepatterns-regex-delimiter.md](../integration-issues/renovate-managerfilepatterns-regex-delimiter.md) — `managerFilePatterns` に `/.../` デリミタが無いと minimatch glob として解釈され、マネージャーが黙って無効化される既知の落とし穴。本ドキュメントの 3 マネージャーはすべて `/dot_apm\/apm\.yml$/` の形でこのルールに従っている。
- [verification-through-the-wrong-resolution-path.md](../workflow-issues/verification-through-the-wrong-resolution-path.md) — 「チェックが空虚に通ってしまう」失敗パターンの一般形。本ドキュメントの検証がなぜ `apm lock` と実際の `renovate --dry-run=lookup` の両方を要求したかの背景。
- `docs/superpowers/specs/2026-08-02-apm-skill-mcp-management-design.md` — `dependencies.apm` の git shorthand ピン形式そのものを導入した APM 移行設計（マーケットプレイス参照ではなく git shorthand を選んだことで、そもそも Renovate 追跡が可能になった）。
