---
title: "ネイティブサンドボックス内で gh CLI が設定読み取りと TLS 検証に失敗する"
date: 2026-08-06
category: integration-issues
module: claude-code
problem_type: integration_issue
component: tooling
symptoms:
  - "`open ~/.config/gh/config.yml: operation not permitted` — sandbox.filesystem.denyRead が ~/.config/gh を含むため gh が設定を読めない"
  - "読み取り許可後も api.github.com への接続が `tls: failed to verify certificate: x509: OSStatus -26276` で失敗する（サンドボックスが com.apple.trustd.agent への Mach service lookup を遮断し、Go 製 CLI の TLS 検証が通らない）"
  - "`gh auth status` を直接叩くと成功するのに `sh -c \"gh ...\"` やラッパースクリプト（bin/gh-readonly 等）は失敗する — sandbox.excludedCommands の `gh *` はコマンド文字列がリテラルに `gh` で始まる場合にしかマッチせず、間接呼び出しはサンドボックス内で実行される"
root_cause: config_error
resolution_type: config_change
severity: medium
tags: [claude-code, native-sandbox, gh-cli, seatbelt, tls, trustd, macos, excludedcommands]
---

# ネイティブサンドボックス内で gh CLI が設定読み取りと TLS 検証に失敗する

## Problem

Claude Code の native sandbox 内で `gh` CLI を間接的に呼び出す（`sh -c "gh ..."` やラッパースクリプト経由）と、`~/.config/gh` の読み取りが拒否され、さらに TLS 証明書検証にも失敗して認証が通らない。シェルで直接 `gh auth status` と打つと成功するため、「直接叩くと動くのにスクリプト越しだと落ちる」という食い違いとして現れる。

## Symptoms

2 つの異なる失敗が順番に現れた。片方を直すまでもう片方は見えない（先に失敗するエラーに隠されている）。

**(a) ファイルシステムの読み取り拒否** — `sh -c "gh auth status"` を実行すると:

```
warning: failed to load config: open ~/.config/gh/config.yml: operation not permitted
failed to create root command: failed to read configuration: open ~/.config/gh/config.yml: operation not permitted
```

gh は設定ファイルすら読めておらず、認証ロジックに到達する前に落ちている。

**(b) TLS 証明書検証の失敗** — (a) を修正した後、`sh -c "gh api user --jq .login"` は設定の読み込みを通過して実際に HTTPS リクエストを発行したが、次で失敗した:

```
Get "https://api.github.com/user": tls: failed to verify certificate: x509: OSStatus -26276
```

## What Didn't Work

**`nono` プロファイルの調査（完全な行き止まり）**
このマシンには Claude Code とは無関係の別のサンドボックス CLI `nono` があり、dotfiles 管理下に `~/.config/nono/profiles/claude-seal.json`（`extends: "claude-code"`）というプロファイルを持っている。その `filesystem.read` には既に `"$XDG_CONFIG_HOME/gh"` が含まれていたため、これが原因・あるいは修正箇所に見えた。しかし:

```
nono why --self --path ~/.config/gh/config.yml --op read
```

の結果は

```
NOT SANDBOXED
  Not running inside a nono sandbox
```

だった。つまり Claude Code の Bash ツール呼び出しに制限をかけているのは `nono` ではない。Claude Code は macOS Seatbelt 実装の独立した native sandbox を持ち、そのプロファイルは `~/.claude/settings.json` の `sandbox` キーからコンパイルされる。`nono` の CLI / プロファイル体系とは完全に別物であり、`claude-seal.json` を編集しても何も変わらなかった（`nono` 移行の詳細は [nono-sandbox-migration-observations-2026-07-25.md](nono-sandbox-migration-observations-2026-07-25.md) 参照）。

**`$XDG_CONFIG_HOME` 未設定による変数展開の破綻という副次仮説**
「シェルで `$XDG_CONFIG_HOME` が未設定なので nono プロファイル内のテンプレート変数展開が壊れているのでは」という仮説も検証したが、`nono why --profile claude-seal --path ~/.config/gh/config.yml --op read` は `$XDG_CONFIG_HOME` 未設定のままでも ALLOWED を返した。プロファイル自体は正常で、単に enforcer ではなかっただけ。

**修正 (a) 適用直後、同一セッションでの再テスト**
`settings.json` に `~/.config/gh` の `allowRead` を追加した直後、同じセッションで `sh -c "gh api user --jq .login"` を再実行しても、まったく同じ `config.yml: operation not permitted` エラーが出続けた。Claude Code の native sandbox プロファイルはセッション開始時に一度だけ `settings.json` からコンパイルされるため、セッション途中の編集は実行中のサンドボックスに遡って反映されない。セッションを再起動してから同じコマンドを実行して初めて、(a) の修正が効いていることを確認できた（そしてそこで初めて (b) の TLS エラーが表面化した）。

## Solution

`~/.claude/settings.json`（全プロジェクト共通のグローバル設定）のトップレベル `sandbox` キーに 2 箇所の変更を加えた。

**Before:**

```json
"sandbox": {
  "enabled": true,
  "failIfUnavailable": false,
  "network": {
    "allowedDomains": ["*.githubusercontent.com", "api.anthropic.com", "api.github.com", "codeload.github.com", "formulae.brew.sh", "github.com", "registry.npmjs.org", "registry.yarnpkg.com"],
    "allowLocalBinding": true,
    "allowUnixSockets": ["~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"]
  },
  "filesystem": {
    "allowWrite": ["/private/tmp", "/tmp", "/var/folders", "~/.cache", "~/.cargo", "~/.npm", "~/.rustup", "~/Library/pnpm/store", "~/go"],
    "denyRead": ["~/.aws/credentials", "~/.config/gh", "~/.git-credentials", "~/.netrc", "~/.ssh"],
    "allowRead": ["~/.ssh/config", "~/.ssh/known_hosts"]
  },
  "excludedCommands": ["docker *", "gcloud *", "gh *", "git push *", "open *", "osascript *", "terraform *"]
}
```

**After（2 箇所の追加、いずれも適用済み）:**

```json
"sandbox": {
  ...same as above except...
  "filesystem": {
    ...
    "allowRead": ["~/.ssh/config", "~/.ssh/known_hosts", "~/.config/gh"]
  },
  "excludedCommands": [...same list...],
  "enableWeakerNetworkIsolation": true
}
```

`enableWeakerNetworkIsolation` は `network` の下ではなく、`filesystem` / `excludedCommands` と同階層の `sandbox` 直下のキーである点に注意。

修正 (b) 適用後は、（既に再起動済みの）同一セッション内で追加の再起動なしにそのまま効いた。修正 (a) がセッション再起動を要したのとは非対称だが、この差の原因は突き止めていない（未解明の観察事実であり、確定した挙動として扱わないこと）。

最終確認: `sh -c "gh api user --jq .login"` が `tanimon` を返し、完全に間接的な呼び出し経路でも end-to-end で認証が通ることを確認した。

なお、デプロイ先の `settings.json` は chezmoi 管理下にあるため、同じ 2 つのキーは chezmoi のソーステンプレート `dot_claude/settings.json.tmpl` にも取り込み済み（chezmoi 管理の dotfiles を使っている場合はそちらも合わせて更新する）。

**検証の限界（正直に明記）**: 上記の確認はいずれも「許可を追加したら成功した」という片方向の観測にとどまり、[verification-through-the-wrong-resolution-path.md](../workflow-issues/verification-through-the-wrong-resolution-path.md) が警告する対比検証（contrast pair — その許可だけを外して失敗が戻ることを確認する）は行っていない。特に `enableWeakerNetworkIsolation` が同一セッション内で再起動なしに効いたという観測は、対比検証なしでは「サンドボックスが実は当たっていなかった」可能性を完全には排除できない。読者がこの構成を再現する場合は、対比検証を追加することを推奨する。

## Why This Works

**根本原因 1: `excludedCommands` は間接呼び出し（サブシェル・ラッパースクリプト経由）を捕捉しない**

`~/.claude/settings.json` の `sandbox.excludedCommands` には `"gh *"` が含まれている。これはコマンド文字列がリテラルに `gh` で始まる場合にしかマッチしない（正確なマッチング方式 — 単純な前方一致か、Bash 権限ルールと同種の word-boundary 付きグロブかは、Claude Code のバージョンに依存しうる。[native-sandbox-1password-socket-signing-2026-07-09.md](native-sandbox-1password-socket-signing-2026-07-09.md) 参照。`gh *` というパターンについてはどちらの解釈でも本件の結論は変わらない）。そのため、シェルで `gh auth status` と直接打った場合は sandbox を完全にバイパスして動く（実際に `✓ Logged in to github.com account tanimon (keyring)` / `Token: gho_...` が確認できた）。しかし `sh -c "gh ..."` やラッパースクリプト経由では、実行されるコマンド文字列が `gh` で始まらないためパターンにマッチせず、コマンドは**サンドボックス内**で実行される。「gh というコマンド群は信頼済み」という直感は、直接呼び出しにしか当てはまらない。

この KB には `excludedCommands` のマッチ規則自体の記録は既にある — [native-sandbox-1password-socket-signing-2026-07-09.md](native-sandbox-1password-socket-signing-2026-07-09.md) はこれをコマンド文字列全体に対するグロブとして扱い、Bash 権限ルールと同種のマッチングだと記録し、Claude Code のバージョンが変わるたびに再検証すべきだと注記している。しかし、そのマッチ規則から導かれる「間接呼び出し（サブシェルやラッパースクリプト経由）は境界の内側で実行される」という帰結を明示した文書はまだ無かった。[claude-code-defaultmode-auto-gh-command-gating.md](claude-code-defaultmode-auto-gh-command-gating.md) は「`gh *` は `excludedCommands` に含まれサンドボックス外で実行される」という前提で `gh` の権限ゲートを論じているが、この前提はリテラルな直接呼び出しにしか成り立たない。同様に [native-sandbox-1password-socket-signing-2026-07-09.md](native-sandbox-1password-socket-signing-2026-07-09.md) の `excludedCommands` 一覧も、直接呼び出しと間接呼び出しの区別には触れていない。両文書とも本件と矛盾はしないが、「除外に載っている = 常にサンドボックス外」という誤読を招きうる点に注意。

**なぜファイルシステムの許可付与が安全だったか**

`denyRead` の `~/.config/gh` は、`~/.aws/credentials` / `~/.ssh` / `~/.netrc` / `~/.git-credentials` と並ぶ意図的な認証情報保護だった。そのため素朴に許可するのではなく、実際に平文の秘密情報が入っているかを確認した:

- `ls -la ~/.config/gh/` → `config.yml`（317 bytes）と `hosts.yml`（80 bytes, mode 0600）のみ
- `grep -n "oauth_token\|token" ~/.config/gh/hosts.yml` → **マッチ 0 件**
- `hosts.yml` の中身（`grep -v -i token` で確認）は `github.com:` / `git_protocol: ssh` / `users:` / `tanimon:` / `user: tanimon` だけで、token フィールドは存在しない
- `gh auth status` が表示した `Token: gho_************************************ (keyring)` の `(keyring)` 表記が、実際の OAuth トークンが macOS ログインキーチェーンに保存されていてファイル側には無いことを裏付けている

この「トークンはキーチェーンにあり `hosts.yml` には無い」という事実は、約 2 週間前に `nono` サンドボックスの移行検証で既に確立されていた（[nono-sandbox-migration-observations-2026-07-25.md](nono-sandbox-migration-observations-2026-07-25.md) の「Why granting `~/.config/gh` read is not a contradiction」節、および「Row 3 — `gh`: PASS」節）。今回は native sandbox という別の enforcer 上で独立に再確認した形になる。したがって `~/.config/gh` の読み取りを許可しても、サンドボックス内のプロセスに露出するのは非機密の設定（git_protocol、editor、alias、ユーザー名）だけで、平文の認証情報は含まれない。

（余談: 診断目的であっても `cat ~/.config/gh/hosts.yml` は Claude Code 自身の auto-mode 権限分類器に「[Credential Materialization] ... prints the raw, unmasked GitHub OAuth token into tool output」という理由でブロックされた。過剰に慎重ではあるが妥当な安全網であり、上記の grep ベースの手順ならトークン形状の文字列を一切出力せずに確認できる。）

**この文書が上書きする既存の前提**: [nono-sandbox-migration-observations-2026-07-25.md](nono-sandbox-migration-observations-2026-07-25.md) の「Why granting `~/.config/gh` read is not a contradiction」節は「native sandbox 下では `gh *` が `excludedCommands` にあるので常にサンドボックス外で実行され、そこで config を拒否しても無償の多層防御になる」という前提を置いていたが、この前提は間接呼び出しには成り立たないことが今回判明した。denyRead を維持したままにすると間接呼び出しの gh がすべて壊れる、という実害が実際にあった。

**根本原因 2: trustd への Mach lookup ブロックが Go の TLS 検証を壊す**

Claude Code の sandbox のネットワーク分離は、macOS 上で `com.apple.trustd.agent` への Mach service lookup をデフォルトでブロックする。gh / gcloud / terraform といった Go 製 CLI は、トラフィックが sandbox のネットワークプロキシ層（`network.allowedDomains` の allowlist を強制する層）を経由するとき、TLS 証明書の検証にこのサービスを利用する。trustd にアクセスできないと Go の TLS スタックは証明書の信頼評価を完了できず、`OSStatus -26276` になる。`sandbox.enableWeakerNetworkIsolation` はまさにこの穴を開けるためのフラグで、設定スキーマ上の説明は次の通り:

> macOS only: Allow access to com.apple.trustd.agent in the sandbox. Needed for Go-based CLI tools (gh, gcloud, terraform, etc.) to verify TLS certificates when using httpProxyPort with a MITM proxy and custom CA. **Reduces security** — opens a potential data exfiltration vector through the trustd service. Default: false.

つまりこれはタダの修正ではなく、**明示的に文書化されたセキュリティ上のトレードオフ**（trustd 経由のデータ持ち出し経路が開く）である。そのため適用前に、(1) 有効化してトレードオフを受け入れ、間接/ラッパー経由の gh（および他の Go 製 CLI）をサンドボックス内でも動くようにする、(2) 無効のままにして、既存の `excludedCommands` バイパスで動く直接呼び出しのみを使う（間接呼び出しは失敗したまま）、(3) グローバル設定を変更せず、間接的な gh 呼び出しが必要なときだけコマンド単位の `dangerouslyDisableSandbox` を使う、という 3 択をユーザーに提示し、ユーザーが (1) を選択したうえで適用した。

この KB 内で `trustd` / `x509` / `certificate` / `TLS` / `enableWeakerNetworkIsolation` に言及した文書はこれが初めてであり、native sandbox のファイルシステム側の拒否（`operation not permitted`）とネットワーク側の拒否（`x509` エラー）が別レバーで別の見え方をする、という区別を確立した最初の記録になる。

## Prevention

「直接打つと動くのにスクリプト/ラッパー/サブシェル越しだと落ちる」というサンドボックス由来の食い違いに再び遭遇したときのために。

1. **`sandbox.excludedCommands` はコマンド文字列がリテラルにそのパターンで始まる場合にしかマッチしないことを、コマンド群が丸ごと信頼済みだと仮定する前に確認する。**（正確なマッチング方式は Claude Code のバージョンにより変わりうるので [native-sandbox-1password-socket-signing-2026-07-09.md](native-sandbox-1password-socket-signing-2026-07-09.md) の記録も参照）`sh -c`、ラッパースクリプト、`env VAR=... cmd` などを挟んだ瞬間にマッチしなくなり、直接呼び出しと間接呼び出しでまったく異なる挙動になる。まず「今実行されているコマンド文字列は本当にそのパターンで始まっているか」を疑う。

2. **「ファイル X が読めない」をサンドボックス下で診断するときは、`allowRead` 付与が危険だと決めつける前に、その秘密情報が本当にそのファイルに入っているか確認する。** ファイル名や配置場所ではなく、具体的な秘密情報のパターンを grep する（例: `grep -n "oauth_token\|token" <file>`）。macOS のキーチェーンや他のシークレットストアに実体が保存されていて、設定ファイル側には非機密の設定しか無いケースは多い。ファイル内容をそのまま出力せず grep で存在確認するだけなら、権限分類器にブロックされずに安全に検証できる。

3. **Claude Code の native sandbox プロファイルはセッション開始時にコンパイルされる。** `settings.json` を編集しても、少なくともファイルシステムのルールについては、セッションを再起動するまで実行中のサンドボックスには反映されない。修正が効いていないように見えても、再起動前の再テスト結果で判断しないこと。なお今回、ネットワーク分離側のフラグ（`enableWeakerNetworkIsolation`）は再起動なしで効いたように見えたが、この非対称性は未確認・未解明であり、確定したルールとして頼らないこと。迷ったら再起動する。

4. **Go 製 CLI（gh / gcloud / terraform）がサンドボックス下でのみ TLS 検証に失敗する場合** — 権限エラーではなく `x509` / certificate 系のエラー、特に `OSStatus -26276` が出る場合 — 対応するレバーは `sandbox.enableWeakerNetworkIsolation` である。ただしこれは trustd 経由のデータ持ち出し経路を開くという明示的なセキュリティコストを伴うので、有効化する前にそのトレードオフを受け入れるかを判断する（コマンド単位の `dangerouslyDisableSandbox` で凌ぐ選択肢もある）。

5. **許可を追加して1回成功しただけでは「その許可が効いた」ことの証明にならない。** サンドボックスは `failIfUnavailable: false` で fail-open になりうるため、成功は「許可が効いた」とも「サンドボックス自体が当たっていなかった」とも読める。可能なら対比検証（追加した許可だけを外して同じ操作が失敗に戻ることを確認する）を行う（[verification-through-the-wrong-resolution-path.md](../workflow-issues/verification-through-the-wrong-resolution-path.md) 参照）。

## Related Issues

- [nono-sandbox-migration-observations-2026-07-25.md](nono-sandbox-migration-observations-2026-07-25.md) — `~/.config/gh` の読み取り要求とキーチェーン所在の発見が約 2 週間前、別のサンドボックス（`nono`）上で先に記録されている。「native sandbox では denyRead が無償の多層防御になる」という同文書の前提は本件により一部反証される（追記を推奨、下記参照）。
- [claude-code-defaultmode-auto-gh-command-gating.md](claude-code-defaultmode-auto-gh-command-gating.md) — `gh` の書き込み系コマンドに対する権限ゲート（承認プロンプト）の話。本件（サンドボックス境界）とは直交する統制軸だが、同じ `excludedCommands` の前提を共有しており、直接呼び出し限定である点の補足が必要。
- [native-sandbox-1password-socket-signing-2026-07-09.md](native-sandbox-1password-socket-signing-2026-07-09.md) — 同じ native sandbox で「filesystem の許可では足りず、目的専用の network 側レバーが必要」という構造が先に確立されている（そちらは Unix ソケット、本件は trustd への Mach lookup）。
- [native-sandbox-temp-dir-write-denial-allowwrite.md](native-sandbox-temp-dir-write-denial-allowwrite.md) — 同じ `dot_claude/settings.json.tmpl` の `sandbox.filesystem.*` を扱う近縁の書き込み拒否事例。
- [native-sandbox-git-ssh-to-https-insteadof-reversal.md](native-sandbox-git-ssh-to-https-insteadof-reversal.md) — 同じネットワークプロキシアーキテクチャ（HTTP(S) プロキシ経由の egress のみ許可）が背景にある別事例。
- [verification-through-the-wrong-resolution-path.md](../workflow-issues/verification-through-the-wrong-resolution-path.md) — fail-open な統制機構に許可を追加して1回の成功だけで判断することの危険性、一般形。

**Refresh candidate (この文書が既存記述を一部反証):** `nono-sandbox-migration-observations-2026-07-25.md` の「Why granting `~/.config/gh` read is not a contradiction」節にある「native sandbox 下では `gh` の設定拒否は無償の多層防御である」という主張は、間接呼び出し（`sh -c`・ラッパースクリプト）が現に壊れていた以上、成り立たない。同節への日付入り追記（同文書の既存の追記慣習に合わせる）を推奨。
