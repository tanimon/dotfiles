# relationship の API

既存の issue に parent / blocked-by を後から張るときのコマンド。照合モードの修正と、`create-issue.sh` が終了コード 1(作成はしたが relationship の一部を張れなかった)で終わったときの張り直しに使う。新しく作る issue は `create-issue.sh` が作成と同時に張るので、これを使わない。

- database id: `gh api repos/<owner>/<repo>/issues/<n> --jq .id`(`#number` や `node_id` ではない)
- 親子: `gh api repos/<owner>/<repo>/issues/<親>/sub_issues -X POST -F sub_issue_id=<子の database id>`
- 親の付け替え: 親子のコマンドに `-F replace_parent=true` を足す(足さないと、別の親を持つ子を API が拒否する)
- 依存: `gh api repos/<owner>/<repo>/issues/<n>/dependencies/blocked_by -X POST -F issue_id=<blocker の database id>`
- 確認: `gh api repos/<owner>/<repo>/issues/<n> --jq '{parent: .parent_issue_url, deps: .issue_dependencies_summary}'`
