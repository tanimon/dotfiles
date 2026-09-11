# Claude Code の Bash tool 経由で実行されるgit専用の上書き設定。
# dot_claude/settings.json.tmpl の env で GIT_CONFIG_GLOBAL からこのファイルを
# 指すことで、通常の ~/.gitconfig を丸ごと include したうえで core.fsmonitor だけ
# 上書きする(単一値キーは後勝ちのため、includeより後に書く必要がある)。
#
# 背景: Claude Codeのネイティブサンドボックスはgit組み込みfsmonitorデーモンの
# IPCソケット(.git/fsmonitor--daemon.ipc)への接続を拒否するため、fsmonitor有効な
# ままだとgit status等のたびに`fsmonitor_ipc__send_query: unspecified error`が
# stderrに出る(実害なし、終了コードは0)。以前は`.zshrc`経由のCLAUDECODE条件付き
# export(GIT_CONFIG_COUNT等)でこれを抑制しようとしたが、Claude CodeのBash tool は
# 非対話シェルでコマンドを実行するため`.zshrc`は読み込まれず、また読み込まれたと
# してもシェルスナップショット機構はPATH以外のexportを保持しないため、実際には
# 一度も効いていなかった(実測: 稼働中セッションのGIT_CONFIG_COUNTはClaude Code自身が
# 設定するcredential.interactive/guiPrompt/safe.directory用の値のみで、fsmonitor
# 上書きは含まれていなかった)。GIT_CONFIG_GLOBALはsettings.json.tmplの`env`経由で
# Claude Code自身のプロセスにのみ渡るため、通常のインタラクティブなターミナル作業では
# ~/.gitconfigのfsmonitor=trueがそのまま有効(CLAUDECODE分岐が不要になった)。
#
# 背景2 (credential.helper): サンドボックスのHTTPプロキシ
# (localhost:<ランダムポート>)向けのcredential storeがGCM経由でキーチェーンに
# 書き込もうとして失敗し、git push等のたびに
# `warning: Permission denied (localhost:<port>)` と
# `fatal: Could not create new item [0x186a1]` がstderrに出る。
# helperをラッパースクリプトに差し替え、ループバック宛だけ捨てて他はGCMへ委譲する。
# credential.helperは多値キーなので、includeで積まれた分(~/.gitconfigのGCMと
# /opt/homebrew/etc/gitconfigのosxkeychain)を空値でリセットしてから追加する。
# 詳細は claude-code-credential-helper.sh のコメント参照。
[include]
  path = ~/.gitconfig
[core]
  fsmonitor = false
[credential]
  helper =
  helper = "!~/.config/git/claude-code-credential-helper.sh"

# 背景3 (commit 署名): ~/.gitconfig は 1Password SSH agent (op-ssh-sign) で署名
# するが、1Password がロック中だと署名ごとに認証ダイアログが出て、人間不在の
# 自律実行が `git commit` で止まる。Claude Code から呼ばれる git だけ、ローカルの
# AI エージェント専用署名鍵 (~/.config/git/signing/ai-agent、パスフレーズ無し) と
# 素の ssh-keygen に差し替える。対話ターミナルの署名は 1Password のまま。
# 鍵は run_once_generate-ai-agent-signing-key.sh.tmpl が生成し、公開鍵を GitHub に
# **signing key** として登録する必要がある(登録しないと Verified にならず、
# required_signatures ルールのあるリポジトリではマージ不可)。
# 置き場所を ~/.ssh にしないのは、両サンドボックス(ネイティブ denyRead / nono
# deny_credentials)が ~/.ssh の読み取りを拒否しており、その保護を崩したくないため。
# nono 側は claude-seal.json の filesystem.read_file にこのパスを明示している。
# user.signingkey はファイルパスとして解釈され、git が ~ を展開する(実測済み)。
[user]
  signingkey = ~/.config/git/signing/ai-agent
[gpg "ssh"]
  program = ssh-keygen
