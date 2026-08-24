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
  - "(2026-08-24) `ssh_dispatch_run_fatal: Connection to UNKNOWN port 65535: Broken pipe` / `fatal: Could not read from remote repository`（remote が ssh://git@github.com/ フルURL形式のため、上記insteadOfの対象外だった）"
root_cause: config_error
resolution_type: config_change
severity: medium
tags: [claude-code, native-sandbox, git, ssh, insteadof, github, gitconfig]
last_updated: 2026-08-24
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

（変更前は `[url "git@github.com:"] insteadOf = https://github.com/` だった。現在の反映箇所は `dot_gitconfig.tmpl:80-82`）

レンダリング後のgitconfigを`GIT_CONFIG_GLOBAL`に指定して`git fetch origin`を実行し、サンドボックス相当の環境でexit 0で成功することを実測確認した（このテスト中に出たGCMの警告`fatal: Could not create new item [0x186a1]`は、サンドボックスのファイルシステムポリシーによるキーチェーン書き込み拒否であり認証失敗ではない。トークンは読み取りのみで済んだためfetch自体は完了した）。

`dot_claude/settings.json.tmpl`の`sandbox.excludedCommands`にある`git push *`除外（`dot_claude/settings.json.tmpl:539`、直前のコメントは`:534`）は、この変更で前提（SSHのraw TCPが必要）が崩れたため、コメントをその旨に更新した。ただし`excludedCommands`からの実際の除去は、サンドボックス設定がセッション開始時に読み込まれるため今回のセッション内では検証できず、fresh sessionでの確認が必要なフォローアップとして残した。

なお、実際のコミット（[tanimon/dotfiles#257](https://github.com/tanimon/dotfiles/pull/257)としてmainにマージ済み）を`git cat-file commit HEAD`で直接確認し、有効な`gpgsig`（1Password SSH agent経由の署名）が付いていることも確認済み。`git log --show-signature`が「No signature」と表示するのは、ローカルに`gpg.ssh.allowedSignersFile`が設定されていないための検証エラーであり、署名が存在しないわけではない。今回の変更は`url`/`credential`セクションのみに触れており、`gpg.format=ssh`や`gpg.ssh.program`、`user.signingkey`には手を入れていないため、コミット署名機能への影響はない。

## Why This Works

ネイティブサンドボックスの`network.allowedDomains`には元から`github.com`が含まれており、HTTP(S)プロキシ経由のegressとしては最初から許可されていた。問題はリモートURLのスキームがSSH（生TCP、port 22）に固定されていたことであり、リモートURL自体をHTTPSに統一すれば、サンドボックスが最初から許可している正規の経路にそのまま乗る。1Password SSH agent経由のcommit署名（`gpg.format=ssh`）はこの変更と独立した設定なので影響を受けない。

## Prevention

- サンドボックス環境で外部サービスへのSSHアクセスが必要になった場合、認証済みHTTP(S)プロキシのCONNECTメソッドを悪用して生TCPを密輸する方式は、機能的に動作しても自動モード分類器にセキュリティ弱体化としてブロックされうる。まずリモートのプロトコル自体をサンドボックスが許可している経路（多くの場合HTTPS）に合わせられないか検討する。
- nono環境（`dot_config/nono/CLAUDE.md`）では同種の問題に対し、`environment.set_vars`で`GIT_CONFIG_*`を使い`insteadOf`をssh→httpsに反転する方式を既に採用していた。ネイティブサンドボックス側でも同じ発想が適用できたが、`GIT_CONFIG_*`/`-c`経由の一時的な追加では機能せず、gitconfigファイル自体の書き換えが必要だった点はnono側と異なる。
- `insteadOf`の双方向ルールをテストする際は、`GIT_TRACE=1`で実際に解決されたトランスポート（`ssh ...`か`https ...`か）を確認する。`git config --list`に設定が表示されることは、その設定が実際に効いていることを意味しない。
- **(2026-08-24追記)** `insteadOf`ベースの修正を書いたら、実際に運用中のリポジトリの`remote.origin.url`をスイープして、想定した1つの形式だけでなく全ての綴り（scp形式`user@host:path`・フルURL形式`ssh://user@host/path`・素の`https://`）が実際にどの割合で使われているか確認する。1つの形式向けに書いた修正を「gitのSSH全般が直った」と早合点しない。スイープ例:
  ```sh
  for d in ~/ghq/*/*/*/ ~/orca/workspaces/*/*/; do
    u=$(git -C "$d" config --get remote.origin.url 2>/dev/null) || continue
    case "$u" in ssh://*|*@*:*) echo "$d -> $u";; esac
  done
  ```

## 追記（2026-08-24）: `ssh://` フルURL形式のカバレッジ漏れを解消

本文書が反転した`insteadOf`（`[url "https://github.com/"] insteadOf = git@github.com:`）は、**scp形式**（`git@github.com:owner/repo.git`）にしかマッチせず、`ssh://git@github.com/owner/repo.git`という**フルURL形式**は対象外だった（このギャップ自体は`nono-sandbox-migration-observations-2026-07-25.md`側で先に文書化されていた）。実際に運用中の複数リポジトリの`remote.origin.url`を調べたところ、いずれも`ssh://`形式で登録されており、本来この`insteadOf`で救われるはずのリポジトリがことごとく対象外になっていた。

症状は本文書の「Symptoms」（`ssh: Could not resolve hostname github.com`）とは微妙に異なり、`ssh_dispatch_run_fatal: Connection to UNKNOWN port 65535: Broken pipe` / `fatal: Could not read from remote repository`という形で現れる — サンドボックスがgitのSSHトランスポート用に注入する`GIT_SSH_COMMAND`（`nc -X 5 -x localhost:<port> %h %p`によるSOCKS5プロキシ経由）を、macOS標準の`nc`が認証つきSOCKS5（RFC 1929）に対応していないため使えず（本文書「What Didn't Work」に記載済みの限界と同一原因）、ローカルプロキシに接続を拒否されてパイプが壊れることに由来する。DNS解決自体が拒否される生TCPの場合と、認証なしSOCKS5が拒否される場合とでは、失敗するレイヤーが違うため症状が変わる。

修正は同じ`[url "https://github.com/"]`セクションに`insteadOf`をもう1行追加するだけ：

```gitconfig
[url "https://github.com/"]
  insteadOf = git@github.com:
  insteadOf = ssh://git@github.com/
```

これは本文書の「What Didn't Work」に記載された「逆方向`insteadOf`との共存」問題とは別種の変更である — 変換先（`https://github.com/`）が同じマッチパターンを追加しているだけで、方向が対立する2ルールの共存ではない。`GIT_TRACE=1`で実際に検証済み: `ssh://git@github.com/...`が`git-remote-https ... https://github.com/...`に解決されるようになり、かつ既存のscp形式・素のhttps形式のいずれも regression なし。`includeIf`による個人リポジトリ向け`core.excludesfile`切り替えもこの変更と無関係のセクションのため影響なし。

## Related Issues

- `docs/solutions/integration-issues/native-sandbox-1password-socket-signing-2026-07-09.md` — 同じネイティブサンドボックスのnetwork設定で、1Password SSH agentソケットを許可した際の記録。commit署名側の解決策。この文書の「`git push`を除外したままにする理由」は今回の`insteadOf`反転で前提が崩れていたが、**この文書自体に2026-07-31追記済み**（「push が生TCPを必要とする」根拠はもう存在しない、ただし`excludedCommands`からの実際の除去はfresh sessionでしか検証できず未検証のまま、との記載）。
- `docs/solutions/integration-issues/nono-sandbox-migration-observations-2026-07-25.md` — nono環境でgitのSSHトランスポートが使えず、`GIT_CONFIG_*`でHTTPSに書き換えた先行事例。`ssh://`フルURL形式がこの`insteadOf`でカバーされないことは、この文書側で先に指摘されていた（上記2026-08-24追記参照）。
- `docs/solutions/integration-issues/1password-ssh-agent-libgit2-ssh-auth-sock.md` — 同じ`insteadOf`レバー（`dot_gitconfig.tmpl`の`url.*.insteadOf`）を扱った過去の別インシデント（2026-06-03、sheldon/libgit2）だが、反転前（https→ssh）の方向で、意図しないSSHクローンが起きた事例。同じ設定レバーが逆方向で別々の障害を引き起こした例として参照価値がある。この文書が引用する`insteadOf`のスニペットは work プロファイルについては historical（過去の値）になっている。
- `docs/solutions/integration-issues/native-sandbox-git-fsmonitor-ipc-socket-block.md` — 同じ`git fetch`/`pull`失敗の出力に同居して現れる、無害な`fsmonitor_ipc__send_query`stderrノイズ側の話（2026-08-24に別原因で改修）。
- `docs/solutions/workflow-issues/verification-through-the-wrong-resolution-path.md` — 本文書の「What Didn't Work」で独自に再発見した教訓（`git config --list`にルールが表示されても実際に適用されているとは限らず、`GIT_TRACE=1`で実際の解決先を見る必要がある）は、この文書が扱う「見た目は検証しているが実際は別のものを見ている」という失敗パターンのgitconfig版の一事例。
