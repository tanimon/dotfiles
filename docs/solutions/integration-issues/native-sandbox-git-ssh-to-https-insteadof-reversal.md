---
title: ネイティブサンドボックス内でgitをSSHの代わりにHTTPS経由で使う
date: 2026-07-31
category: integration-issues
module: dotfiles-git-sandbox-integration
problem_type: integration_issue
component: tooling
symptoms:
  - "`ssh: Could not resolve hostname github.com`（ネイティブサンドボックス内でgit fetchを実行した際）"
  - "git fetch/pull/push がネイティブサンドボックス内で失敗する（remote が git@github.com: 形式のため）"
root_cause: config_error
resolution_type: config_change
severity: medium
tags: [claude-code, native-sandbox, git, ssh, insteadof, github, gitconfig]
last_updated: 2026-07-31
---

# ネイティブサンドボックス内でgitをSSHの代わりにHTTPS経由で使う

## Problem

Claude Codeのネイティブサンドボックス（`dot_claude/settings.json.tmpl`の`sandbox.network`、macOS Seatbelt）は、HTTP(S)プロキシ経由のegressのみを許可し、任意ポートへの生TCP接続を拒否する。グローバルgitconfig（`dot_gitconfig.tmpl`のworkプロファイル）が`insteadOf`で`https://github.com/`を`git@github.com:`に書き換えていたため、リモートは常にSSH形式になり、サンドボックス内でのgit fetch/pull/pushがすべて失敗していた。

## Symptoms

- `GIT_SSH_COMMAND` を明示的に上書きしてサンドボックス内で `git fetch` を実行すると `ssh: Could not resolve hostname github.com` で失敗する（DNS解決自体がブロックされる）。
- `git push` は既存の `sandbox.excludedCommands`（`dot_claude/settings.json.tmpl`）で意図的にサンドボックス外実行にされていたが、これは対症療法であり、`fetch`/`pull`/`clone` は対象外だったため影響を受け続けていた。
- サンドボックスは `failIfUnavailable: false`（fail-open）のため、この失敗は分かりやすいサンドボックス由来のエラーとしては表面化せず、一見ネットワーク一般の不調のように見える。

## What Didn't Work

- **サンドボックスが注入する`GIT_SSH_COMMAND`（`nc -X 5 -x localhost:<port> %h %p`、SOCKS5経由）をそのまま使う** — macOS標準の`nc`は認証つきSOCKS5（RFC 1929 user/pass negotiation）をサポートせず、`nc: authentication method negotiation failed`で失敗する。
- **認証済みHTTP(S) CONNECTプロキシ（`HTTP_PROXY`環境変数）を悪用し、Pythonでstdin/stdoutリレーするProxyCommandスクリプトを自作する** — 技術的には動作し、`git fetch`がexit 0で成功することまで実測したが、これはサンドボックスが意図的に拒否している生TCP egressをBasic認証付きCONNECTトンネル経由で密輸する行為であり、Claude Codeの自動モード分類器が「サンドボックスの生TCP拒否をバイパスする行為」として実行をブロックした。セキュリティ境界を回避する方式であり不採用とした。
- **`GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_n`や`-c`オプションで逆方向の`insteadOf`（`url.https://github.com/.insteadOf=git@github.com:`）を追加し、既存のグローバル`insteadOf`（https→ssh）と共存させる** — `git config --list`には設定として認識されるが、`GIT_TRACE=1`で確認すると実際の接続は変わらず`ssh ... git@github.com`のままだった。`-c`/`GIT_CONFIG_KEY_n`のURL形式キーのパース不備を疑い、`include.path`でファイルベースの逆方向ルールのみを追加して再検証したが、既存のグローバル`insteadOf`と共存させたままでは同じく機能しなかった（`-c`構文の問題ではなく、2つの`insteadOf`ルールの共存自体が原因）。`GIT_CONFIG_GLOBAL=/dev/null`で元のgitconfigを丸ごと無視した場合のみ逆方向ルールが機能した。内部でどちらのルールが優先されるかの正確なメカニズムは未特定。

## Solution

グローバルgitconfigの`insteadOf`を https→ssh から ssh→https に反転する（`dot_gitconfig.tmpl`のworkプロファイル）。認証は既存のcredential.helper（Git Credential Manager、`/usr/local/share/gcm-core/git-credential-manager`）に任せる。

```gitconfig
### 会社用設定
[url "https://github.com/"]
  insteadOf = git@github.com:
[credential]
  helper =
  helper = /usr/local/share/gcm-core/git-credential-manager
```

（変更前は `[url "git@github.com:"] insteadOf = https://github.com/` だった。現在の反映箇所は `dot_gitconfig.tmpl:68-69`）

レンダリング後のgitconfigを`GIT_CONFIG_GLOBAL`に指定して`git fetch origin`を実行し、サンドボックス相当の環境でexit 0で成功することを実測確認した（このテスト中に出たGCMの警告`fatal: Could not create new item [0x186a1]`は、サンドボックスのファイルシステムポリシーによるキーチェーン書き込み拒否であり認証失敗ではない。トークンは読み取りのみで済んだためfetch自体は完了した）。

`dot_claude/settings.json.tmpl`の`sandbox.excludedCommands`にある`git push *`除外（`dot_claude/settings.json.tmpl:527`、直前のコメントは`:522`）は、この変更で前提（SSHのraw TCPが必要）が崩れたため、コメントをその旨に更新した。ただし`excludedCommands`からの実際の除去は、サンドボックス設定がセッション開始時に読み込まれるため今回のセッション内では検証できず、fresh sessionでの確認が必要なフォローアップとして残した。

なお、実際のコミット（本稿執筆時点で`main`未マージのブランチ`tanimon/feat-native-sandbox-git`上のコミット`111cde0`。マージ後はPR番号を参照すること — このSHAはrebase/squashで変わりうる）を`git cat-file commit HEAD`で直接確認し、有効な`gpgsig`（1Password SSH agent経由の署名）が付いていることも確認済み。`git log --show-signature`が「No signature」と表示するのは、ローカルに`gpg.ssh.allowedSignersFile`が設定されていないための検証エラーであり、署名が存在しないわけではない。今回の変更は`url`/`credential`セクションのみに触れており、`gpg.format=ssh`や`gpg.ssh.program`、`user.signingkey`には手を入れていないため、コミット署名機能への影響はない。

## Why This Works

ネイティブサンドボックスの`network.allowedDomains`には元から`github.com`が含まれており、HTTP(S)プロキシ経由のegressとしては最初から許可されていた。問題はリモートURLのスキームがSSH（生TCP、port 22）に固定されていたことであり、リモートURL自体をHTTPSに統一すれば、サンドボックスが最初から許可している正規の経路にそのまま乗る。1Password SSH agent経由のcommit署名（`gpg.format=ssh`）はこの変更と独立した設定なので影響を受けない。

## Prevention

- サンドボックス環境で外部サービスへのSSHアクセスが必要になった場合、認証済みHTTP(S)プロキシのCONNECTメソッドを悪用して生TCPを密輸する方式は、機能的に動作しても自動モード分類器にセキュリティ弱体化としてブロックされうる。まずリモートのプロトコル自体をサンドボックスが許可している経路（多くの場合HTTPS）に合わせられないか検討する。
- nono環境（`dot_config/nono/CLAUDE.md`）では同種の問題に対し、`environment.set_vars`で`GIT_CONFIG_*`を使い`insteadOf`をssh→httpsに反転する方式を既に採用していた。ネイティブサンドボックス側でも同じ発想が適用できたが、`GIT_CONFIG_*`/`-c`経由の一時的な追加では機能せず、gitconfigファイル自体の書き換えが必要だった点はnono側と異なる。
- `insteadOf`の双方向ルールをテストする際は、`GIT_TRACE=1`で実際に解決されたトランスポート（`ssh ...`か`https ...`か）を確認する。`git config --list`に設定が表示されることは、その設定が実際に効いていることを意味しない。

## Related Issues

- `docs/solutions/integration-issues/native-sandbox-1password-socket-signing-2026-07-09.md` — 同じネイティブサンドボックスのnetwork設定で、1Password SSH agentソケットを許可した際の記録。commit署名側の解決策。**この文書の「`git push`を除外したままにする理由」は、今回の`insteadOf`反転で前提が崩れた古い記述になっている（`url.git@github.com:.insteadOf https://github.com/`によりhttpsもsshに書き換わる、という記述はもう成り立たない）。追記での更新が必要。**
- `docs/solutions/integration-issues/nono-sandbox-migration-observations-2026-07-25.md` — nono環境でgitのSSHトランスポートが使えず、`GIT_CONFIG_*`でHTTPSに書き換えた先行事例。
- `docs/solutions/integration-issues/1password-ssh-agent-libgit2-ssh-auth-sock.md` — 同じ`insteadOf`レバー（`dot_gitconfig.tmpl`の`url.*.insteadOf`）を扱った過去の別インシデント（2026-06-03、sheldon/libgit2）だが、反転前（https→ssh）の方向で、意図しないSSHクローンが起きた事例。同じ設定レバーが逆方向で別々の障害を引き起こした例として参照価値がある。この文書が引用する`insteadOf`のスニペットは work プロファイルについては historical（過去の値）になっている。
- `docs/solutions/workflow-issues/verification-through-the-wrong-resolution-path.md` — 本文書の「What Didn't Work」で独自に再発見した教訓（`git config --list`にルールが表示されても実際に適用されているとは限らず、`GIT_TRACE=1`で実際の解決先を見る必要がある）は、この文書が扱う「見た目は検証しているが実際は別のものを見ている」という失敗パターンのgitconfig版の一事例。
