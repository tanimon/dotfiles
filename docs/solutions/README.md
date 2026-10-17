# docs/solutions

過去に壊れたこと・ハマったことと、その解決や判断の記録。1 ファイル 1 件。決定の記録(ADR)は `docs/adr/` に、用語は `GLOSSARY.md` に置き、ここには書かない。

書く価値があるのは、最終的なコード・テスト・ルールから読み取れない理由づけ(なぜ効くか、何が効かなかったか、再発をどう防ぐか)だけ。コードやコミットメッセージを読めば分かる定型の修正は書かない。

この書式に合わない既存の文書(主に 2026-07 以前のもの)は書き直さない。新しく書く文書と、追記する文書の追記部分に適用する。

## 書く前に: 重複の確認

同じ問題の文書が既にあれば、新しく作らずにその文書へ追記する。

1. frontmatter の `title` / `component` / `tags` を、問題のキーワードで grep する(例: `grep -rn -i -E '^(title|component|tags):.*fsmonitor' docs/solutions`)。
2. 問題・原因・解決のうち 2 つ以上が重なる文書があれば、その文書に追記し、frontmatter に `last_updated: YYYY-MM-DD` を足す(既にあれば更新する)。path と既存の frontmatter は変えない。
3. 重なりが 1 つ以下なら新しく作り、本文の「関連」で既存の文書へリンクする。

## 置き場所とファイル名

`docs/solutions/<category>/<slug>.md`。slug は問題を表す英小文字とハイフン。日付は付けない(作成日の正本は `date:`)。日付付きの既存ファイルは改名しない。

`category` と `problem_type` は次の対応で選ぶ。種別が bug のものは本文に bug のテンプレートを、knowledge のものは knowledge のテンプレートを使う。

| category(ディレクトリ) | problem_type | 種別 | 何を書くか |
|---|---|---|---|
| `integration-issues` | `integration_issue` | bug | ツール・製品どうしの組み合わせで壊れたこと |
| `logic-errors` | `logic_error` | bug | スクリプトや設定の論理の誤り |
| `runtime-errors` | `runtime_error` | bug | 実行時に落ちる・エラーを出すもの |
| `architecture-patterns` | `architecture_pattern` | knowledge | 所有範囲や構成の型 |
| `developer-experience` | `developer_experience` | knowledge | 開発体験・ハーネスの仕組み |
| `tooling-decisions` | `tooling_decision` | knowledge | ツールの採否とその理由 |
| `workflow-issues` | `workflow_issue` | knowledge | 作業手順・検証手順の落とし穴 |

どれにも当たらないときは、近いものを選んで本文で補う。新しいディレクトリを足すときは、この表も更新する。

## frontmatter

```yaml
---
title: "問題を 1 文で"
date: YYYY-MM-DD
category: integration-issues        # ディレクトリ名だけ(docs/solutions/ を付けない)
problem_type: integration_issue     # 上の表の値
component: tooling                  # 既存の文書で使われている語を優先する
severity: medium                    # critical / high / medium / low
# bug の種別だけ必須
symptoms:
  - "観測した症状(1〜5 件)"
root_cause: config_error            # 既存の文書で使われている語を優先する
resolution_type: config_change      # 既存の文書で使われている語を優先する
# 任意
tags: [chezmoi, sandbox]            # 8 件まで。小文字とハイフン
last_updated: YYYY-MM-DD            # 追記したとき
---
```

`component` / `root_cause` / `resolution_type` は語彙を固定していない。新しい語を作る前に `grep -rh --exclude=README.md '^component:' docs/solutions | sort | uniq -c` で既存の語を確かめる。

配列の要素がバッククォート・`[`・`*`・`&`・`!`・`|`・`>`・`%`・`@`・`?` で始まるとき、または `: ` を含むときは、二重引用符で囲む(囲まないと YAML として壊れる)。

## 本文のテンプレート

本文は日本語で書く(`dot_claude/rules/common/documentation-language.md`)。節の順序は保ち、書くことの無い節は省いてよい。

bug の種別:

```markdown
# <title と同じ内容>

## 問題
## 症状
## うまくいかなかったこと
## 解決
## なぜ効くか
## 再発防止
## 関連
```

knowledge の種別:

```markdown
# <title と同じ内容>

## 背景
## 指針
## なぜ重要か
## 適用する場面
## 例
## 関連
```

追記するときは、末尾に `## 追記 (YYYY-MM-DD)` の節を足すか、該当する節に書き足す。どちらの場合も `last_updated` を更新する。
