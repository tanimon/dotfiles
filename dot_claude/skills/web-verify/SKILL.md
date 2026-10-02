---
name: web-verify
description: >-
  Webプロジェクトで機能実装を終えた後、手動でやっていた画面の動作確認・機能検証を自動化したいときに使う。
  「動作確認して」「ブラウザで操作して確かめて」「検証結果を録画で残して」「このブランチ/PRの変更を画面で確認して」
  「前と同じ観点で再検証して」など、実装後の動作確認・デグレ確認とその再実行が話題になったら使う。
  対象はブラウザで操作できる任意のWebアプリ。そのリポジトリ専用の検証 skill があればそちらを優先する。
  単体テストの作成・静的解析・CLI/TUIアプリの検証・見つかったバグの修正そのものには使わない。
---

# web-verify — Web アプリ動作確認の自動化

機能開発後の手動動作確認を自動化する。**分析 → (初回のみ)承認 → scaffold →
環境起動 → seed → シナリオ実装 → 実行(録画) → 報告** を一周させ、
再実行可能な検証資産を対象リポに残す。

## 不変条件

- **資産は skill なしで再実行できる。** 生成物はすべて標準の `@playwright/test`
  スイートであり、`npx playwright test` だけで誰でも再実行できる形を壊さない。
  skill 独自形式の中間物をリポに持ち込まない
- **fail しても実装コードを直さない。** この skill の成果物は発見と報告。
  修正は別タスクとしてユーザーに委ねる
- **資格情報を commit しない・録画に映さない。** 資格情報は `.env`(gitignored)
  のみに置き、ログインは録画を切った auth setup に分離する

## 検証資産(対象リポ、既定 `.claude/verify/`)

```
.claude/verify/
├── README.md               # 観点一覧・実行方法(人間向け)
├── profile.md              # 起動方法・ログイン方式・seed手段(再実行の自律性の源)
├── package.json            # 自己完結の devDependency(ホストの依存を汚さない)
├── playwright.config.ts    # video:"on"、HTMLレポート、seed の配線
├── scenarios/*.spec.ts     # 1観点 = 1 test(auth.setup.ts はログイン分離用)
├── seed/setup.ts           # データ準備(冪等)
├── seed/cleanup.ts         # クリーンアップ
└── .gitignore              # 生成物(録画・レポート・.auth・.env)を除外
```

## パイプライン

### 初回(検証資産がまだ無い)

1. **分析**: `git diff <base>...HEAD` + PR description から観点を洗い出す
   → references/scenario-authoring.md
2. **profile 調査**: 起動・ログイン・seed 手段をリポから調査、不明点はユーザーに質問
   → references/scaffold.md
3. **【承認ゲート】**: 観点リスト(前提/操作/期待結果)を `AskUserQuestion` で提示し、
   修正・承認を受けるまで先へ進まない
4. **scaffold**: assets からコピーして npm install → references/scaffold.md
5. **環境起動 + readiness**: profile.md のコマンドで起動し、readiness 条件を確認。
   通らなければログを提示して中止する(ブラウザ操作に進まない)。
   URL が 200 を返すだけでは足りない。そのポートで応答しているのが対象 worktree の
   プロセスか(コンテナなら compose project 名)を確かめ、ビルド成果物を配信する構成では
   ビルド済みアセットがコードの最終時刻(後述)より新しいかも確かめる(vite dev server など HMR で配信する構成では不要)。
   別 worktree のアプリが同じポートを握っていると、無関係なブランチを検証して pass を出してしまう。
   queue worker などの常駐ワーカーも確かめる。ワーカーは起動時のコードで動き続けるので、HTTP は新しいコードで
   返しても非同期ジョブだけ古いコードで処理され、ジョブ経由の観点が古い実装に対して pass になる。
   既定では検証前にワーカーを無条件で再起動する。再起動できない構成でだけ時刻で判定し、起動時刻
   (コンテナなら `docker inspect -f '{{.State.StartedAt}}' <container>`。小数秒付きの UTC の RFC3339 なので、
   macOS では小数秒を落として `date -j -u -f '%Y-%m-%dT%H:%M:%S' "${started%%.*}" +%s` で epoch 秒に直す)を、
   コードがこの worktree に入った最終時刻と比べる。HEAD のコミット時刻は使わない — pull したコミット・
   ブランチの切り替え・未コミットの変更では、コミット時刻がワーカー起動より古くてもコードは新しい。
   最終時刻は HEAD の reflog の最新エントリが記録された時刻
   (`git reflog -1 --date=unix --format=%gd HEAD | sed 's/.*{\(.*\)}/\1/'`。`--format=%ct` はコミット時刻を返すので使わない)と、
   未コミットの変更があればそのファイルの mtime の最大値の、遅い方。
   ビルド済みアセットの鮮度も同じ最終時刻と比べる
6. **seed 実装**: 観点の前提データを seed/setup.ts に冪等に実装
7. **シナリオ実装**: 観点ごとに探索 → spec 化 → 単体実行で安定化
   → references/scenario-authoring.md
8. **全体実行**: 検証ディレクトリで `npx playwright test`(録画・trace・HTML レポート生成)
9. **報告**: pass/fail 一覧、fail の 3 分類(実装バグ / シナリオ誤り / 環境問題)、
   レポートの開き方(`npx playwright show-report report`)を提示
   → references/troubleshooting.md

### 再実行(検証資産が既にある)

- diff から**差分観点だけ**を導出して既存シナリオに追加する(承認ゲート不要。
  実行後の報告で追加観点を明示する)
- 環境起動・readiness・実行は初回と同じ(profile.md に従う)
- コード修正後の再確認だけなら観点導出も不要: 起動して `npx playwright test`

## ステージ別リファレンス

| ステージ | リファレンス |
|---|---|
| 観点導出・承認・spec 記述・探索 | references/scenario-authoring.md |
| profile 調査・scaffold・テンプレート適合 | references/scaffold.md |
| fail の切り分け・症状別対処 | references/troubleshooting.md |

各ステージに入る前に対応するリファレンスを読むこと。
