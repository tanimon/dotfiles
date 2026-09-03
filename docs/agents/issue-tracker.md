# Issue tracker: GitHub

このリポジトリの issue と spec は GitHub Issues に置く（`tanimon/dotfiles`）。すべての操作は `gh` CLI 経由で行う。

## Conventions

- **Create an issue**: `gh issue create --title "..." --body "..."`。複数行の body は heredoc を使う。
- **Read an issue**: `gh issue view <number> --comments`。ラベルも併せて取得し、コメントは `jq` で絞る。
- **List issues**: `gh issue list --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'`。必要に応じて `--label` / `--state` で絞る。
- **Comment on an issue**: `gh issue comment <number> --body "..."`
- **Apply / remove labels**: `gh issue edit <number> --add-label "..."` / `--remove-label "..."`
- **Close**: `gh issue close <number> --comment "..."`

リポジトリは `git remote -v` から解決される。clone 内で実行すれば `gh` が自動で判定する。

**worktree での注意**: このリポジトリの feature 作業は `~/orca/workspaces/chezmoi/<name>` の worktree で行う。`gh` は worktree でも `origin` から同じリポジトリを解決するので追加の指定は不要。

## Pull requests as a triage surface

**PRs as a request surface: no.** _(このリポジトリが外部 PR を feature request として扱うなら `yes` にする。`/triage` がこのフラグを読む。)_

`yes` にした場合、PR は issue と同じラベル・同じ状態遷移を通り、`gh pr` 系のコマンドを使う:

- **Read a PR**: `gh pr view <number> --comments` と `gh pr diff <number>`
- **List external PRs for triage**: `gh pr list --state open --json number,title,body,labels,author,authorAssociation,comments` を実行し、`authorAssociation` が `CONTRIBUTOR` / `FIRST_TIME_CONTRIBUTOR` / `NONE` のものだけ残す（`OWNER` / `MEMBER` / `COLLABORATOR` は落とす）。
- **Comment / label / close**: `gh pr comment`, `gh pr edit --add-label`/`--remove-label`, `gh pr close`

GitHub は issue と PR で番号空間を共有するため、裸の `#42` はどちらの可能性もある。`gh pr view 42` を試し、失敗したら `gh issue view 42` にフォールバックする。

## When a skill says "publish to the issue tracker"

GitHub issue を作成する。

## When a skill says "fetch the relevant ticket"

`gh issue view <number> --comments` を実行する。

## Wayfinding operations

`/wayfinder` が使う。**map** は単一の issue、**child** issue が ticket。

- **Map**: `wayfinder:map` ラベルを付けた単一 issue に Notes / Decisions-so-far / Fog の body を持たせる。`gh issue create --label wayfinder:map`
- **Child ticket**: map の GitHub sub-issue としてリンクした issue（sub-issues エンドポイントを `gh api` で叩く）。sub-issues が有効でない場合は map の body の task list に追加し、child の body 冒頭に `Part of #<map>` を書く。ラベルは `wayfinder:<type>`（`research` / `prototype` / `grilling` / `task`）。claim 後は担当開発者に assign する。
- **Blocking**: GitHub の **native issue dependencies** を使う（UI から見える正式表現）。`gh api --method POST repos/<owner>/<repo>/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-db-id>`。`<blocker-db-id>` は blocker の数値 **database id**（`gh api repos/<owner>/<repo>/issues/<n> --jq .id` で取得。`#number` や `node_id` ではない）。GitHub は `issue_dependencies_summary.blocked_by`（open な blocker のみ）を返し、これが実際のゲートになる。dependencies が使えない場合は child の body 冒頭に `Blocked by: #<n>, #<n>` 行を置いてフォールバックする。全 blocker が close された時点で unblock。
- **Frontier query**: map の open な child を列挙し（`gh issue list --state open` を map の sub-issues / task list に絞る）、open な blocker を持つもの（`issue_dependencies_summary.blocked_by > 0`、または `Blocked by` 行に open issue があるもの）と assignee が付いているものを落とす。map の順で先頭が勝ち。
- **Claim**: `gh issue edit <n> --add-assignee @me`。セッション最初の書き込み。
- **Resolve**: `gh issue comment <n> --body "<answer>"` → `gh issue close <n>` → map の Decisions-so-far に context pointer（gist + link）を追記。
