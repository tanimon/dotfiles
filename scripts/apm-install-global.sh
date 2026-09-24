#!/usr/bin/env bash
set -euo pipefail

# `apm install --global` を、~/.claude.json の symlink を一時的に外した状態で実行する。
#
# なぜ外すのか
# ------------
# APM 0.30.0 は MCP サーバーを prune するとき、対象の設定パスが symlink だと
# 書き込みを拒否して install 全体を失敗させる
# (`_reject_symlink_config`、apm_cli/integration/mcp_integrator.py)。
#
#   [x] Refusing to clean symlinked MCP config: ~/.claude.json (...).
#       Replace the symlink with a regular file or directory, then retry.
#
# このガードは APM 自身が以前やっていた破壊 — symlink を平のファイルで上書きして
# ~/.claude/claude.json を取り残す split-brain — の上流修正であって、こちらの構成が
# 間違っているわけではない。ただし prune が走るのは apm.yml から MCP 依存を消したときだけ
# なので、普段の install は成功し、依存を1つ消した日だけ落ちる。
#
# 追加(configure)側には同じガードが無い。APM の `atomic_write_text` は `os.replace()` で
# 書くため、**新しいサーバーを足すときは今も symlink を平のファイルに潰す**。
# 「APM が symlink を壊す」は追加時は真、prune 時は 0.30.0 で拒否に変わった、が現状。
#
# なぜ symlink を廃止して恒久解決にしないのか
# --------------------------------------------
# symlink を作っているのは nono で、Claude Code でも chezmoi でもない。nono バイナリ
# (0.72.0) が文字列として持っている:
#
#   Failed to move ~/.claude.json to ~/.claude/claude.json:
#   Failed to create ~/.claude.json symlink:
#
# `nono run --profile claude-seal` は、たとえコマンドが /bin/true でも、実行のたびに
# ~/.claude.json を ~/.claude/claude.json へ移して symlink を張り直す(実測)。
# サンドボックスが $HOME 直下を許可せず ~/.claude を丸ごと許可しているための再配置:
#
#   nono 内 `: > ~/.claude/.deadbeefcafe1234.tmp` -> OK
#   nono 内 `: > ~/.deadbeefcafe1234.tmp`         -> Operation not permitted
#
# ただしこの再配置で Claude Code の設定書き込みが救われるわけではない。その writer は
# symlink を解決せず $HOME/.claude.json.tmp.<pid>.<hex> を作るので、link の有無に関わらず
# 拒否される(dot_config/nono/CLAUDE.md の「~/.claude.json は nono 内で永続しない」)。
# ここで効くのは「手で消しても次の nono 起動で戻ってくる」という一点だけで、
# だから恒久的に平のファイルへ一本化することはできない。恒久解決は
# 「APM が、解決先が通常ファイルの symlink なら prune を許す」(upstream)か、
# nono 側の再配置をやめること。どちらもこのリポジトリの外にある。
#
# 使い方
#   bash scripts/apm-install-global.sh
#
# 環境変数(テスト用の注入口を兼ねる)
#   APM_INSTALL_HOME=<dir>   ~ の代わりに使うディレクトリ (既定: $HOME)
#   APM_BIN=<path>           apm の実体 (既定: PATH 上の apm)
#   APM_TARGETS=<list>       --target に渡す値 (既定: claude,codex)

apm_bin="${APM_BIN:-apm}"
# 配布先は dot_apm/apm.yml の targets: と意図的に二重宣言している。--target を省略すると
# APM は auto-detect にフォールバックし、検出した「global-capable」な全ランタイム
# (Gemini CLI・Kiro 等)へ fan out する。宣言が apm.yml 側だけだと、キー名の変更や
# 書式ミスでその fan out に黙って落ちる(フェイルオープン)ので冗長さを買う。
# 両者の一致は test/apm-mcp-distribution.bats が静的に照合する。
# 配布先の選定根拠と APM の所有範囲:
# docs/adr/0006-apm-owns-only-the-mcp-servers-table-of-codex-config.md
apm_targets="${APM_TARGETS:-claude,codex}"
home_dir="${APM_INSTALL_HOME:-${HOME}}"

link_path="${home_dir}/.claude.json"
real_path="${home_dir}/.claude/claude.json"

if ! command -v "${apm_bin}" >/dev/null 2>&1; then
    echo "apm CLI not found, skipping apm install --global" >&2
    exit 0
fi

# 実行中の nono セッションがあると、de-link している数秒のあいだに
# そのセッションの設定書き込みが $HOME 側へ解決してサンドボックスに落とされる。
# Claude Code はそれを EPERM として見せず「File modified」と報告して exit 0 するので、
# 黙って失われる。止める理由にはしない(誤検知で apply が止まるほうが困る)が、警告は出す。
# パターンは実際の argv で検証済み: `nono run --profile claude-seal --allow-cwd -- <cmd>`。
# pgrep 自体がプロセス一覧を取れない環境(サンドボックス内)では黙って何も出ないが、
# 消えるのは警告だけで de-link の判断は変わらないので、そのままにしてある。
if pgrep -f 'nono run --profile claude-seal' >/dev/null 2>&1; then
    echo "WARNING: a nono claude-seal session is running; its config writes may be silently dropped while ~/.claude.json is temporarily de-linked" >&2
fi

# de-link は「symlink があり、その実体が通常ファイル」のときだけ行う。
# 想定外のトポロジ(両方が通常ファイル、実体が symlink、など)では何も動かさず
# そのまま apm に渡す — 壊れた状態を推測で「直す」ほうが危険。
relink_needed=false
if [ -L "${link_path}" ]; then
    if [ -f "${real_path}" ] && [ ! -L "${real_path}" ]; then
        rm "${link_path}"
        mv "${real_path}" "${link_path}"
        relink_needed=true
    else
        echo "WARNING: ~/.claude.json is a symlink but ~/.claude/claude.json is not a regular file; leaving the topology alone" >&2
    fi
fi

apm_status=0
"${apm_bin}" install --global --target "${apm_targets}" || apm_status=$?

if [ "${relink_needed}" = true ]; then
    if [ -L "${link_path}" ]; then
        # 走っている nono がウィンドウ中に張り直した。実体も戻っているはずなので何もしない。
        echo "NOTE: ~/.claude.json was re-linked by nono during the window; leaving it as is" >&2
    elif [ -e "${real_path}" ]; then
        # ここで mv すると symlink で実体を上書きして設定を丸ごと失う。実際に起きた事故なので
        # 必ず止める。~/.claude.json は通常ファイルのまま残り、nono 外の Claude Code は
        # そのまま読めるし、次の nono 起動が張り直す。
        echo "ERROR: ${real_path} reappeared during the window; refusing to move ~/.claude.json onto it." >&2
        echo "       ~/.claude.json is left as a regular file. Inspect both paths and restore by hand." >&2
        # 専用の終了コード。呼び出し側(run_onchange)は apm 自身の失敗は警告で流すが、
        # これだけは apply を止める — 「両方が通常ファイル」は次の nono 起動が
        # 片方を上書きする前に人間が見るべき状態だから。
        exit 70
    else
        mv "${link_path}" "${real_path}"
        ln -s .claude/claude.json "${link_path}"
    fi
fi

if [ "${apm_status}" -ne 0 ]; then
    echo "WARNING: apm install --global --target ${apm_targets} failed; re-run it manually to sync MCP servers" >&2
fi

exit "${apm_status}"
