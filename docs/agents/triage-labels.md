# Triage Labels

skill 側は5つの canonical な triage role で話す。このファイルはその role をこのリポジトリの issue tracker で実際に使うラベル文字列へ対応づける。

| Label in mattpocock/skills | Label in our tracker | Meaning                                  |
| -------------------------- | -------------------- | ---------------------------------------- |
| `needs-triage`             | `needs-triage`       | Maintainer needs to evaluate this issue  |
| `needs-info`               | `needs-info`         | Waiting on reporter for more information |
| `ready-for-agent`          | `ready-for-agent`    | Fully specified, ready for an AFK agent  |
| `ready-for-human`          | `ready-for-human`    | Requires human implementation            |
| `wontfix`                  | `wontfix`            | Will not be actioned                     |

skill が role に言及したとき（例:「AFK-ready の triage ラベルを当てる」）は、この表の右列のラベル文字列を使う。

実際に使っている語彙に合わせる場合は右列を編集する。

## ラベルの作成状況

`triage` skill はラベルを自作しない（`triage/` 配下に `gh label create` は存在しない）。`gh issue edit --add-label` は存在しないラベルに対して失敗するため、使う前にリポジトリ側へ作成しておく必要がある。

- `wontfix` — GitHub のデフォルトラベルとして既に存在
- `needs-triage` / `needs-info` / `ready-for-agent` / `ready-for-human` — 下記で作成する

```sh
gh label create needs-triage    --description "Maintainer needs to evaluate this issue"  --color FBCA04
gh label create needs-info      --description "Waiting on reporter for more information" --color D876E3
gh label create ready-for-agent --description "Fully specified, ready for an AFK agent"  --color 0E8A16
gh label create ready-for-human --description "Requires human implementation"            --color 1D76DB
```

既に存在するラベルに対して `gh label create` は失敗する（`--force` で上書き可）。作成済みかは `gh label list` で確認する。
