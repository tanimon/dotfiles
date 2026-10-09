#!/usr/bin/env bash
set -euo pipefail

# `apm install --global` を、~/.claude.json の symlink を一時的に外した状態で実行する。
#
# APM(0.30.0 以降。0.33.0 で確認)は MCP サーバーを prune するとき、設定パスが symlink だと
# `[x] Refusing to clean symlinked MCP config` で install 全体を失敗させる
# (追加時は逆に symlink を平のファイルに潰す)。prune 側は `CLAUDE_CONFIG_DIR` を見ず
# `~/.claude.json` を固定で使うので、環境変数で実体を指しても回避できない。
# symlink を張っているのは nono で、`nono run --profile claude-seal` のたびに張り直すため、
# 恒久的に平のファイルへ一本化することはできない。恒久解決は upstream(APM か nono)にある。
# 実体の位置は nono のバージョンで変わる(0.79.0 は `~/.claude/.claude.json`)ので固定せず、
# link の指す先から求める。
# 一次証拠・実測・事故の経緯は dot_apm/CLAUDE.md の「`~/.claude.json` symlink と APM」節。
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
link_target=""
real_path=""
if [ -L "${link_path}" ]; then
    link_target=$(readlink "${link_path}")
    case "${link_target}" in
    /*) real_path="${link_target}" ;;
    *) real_path="${home_dir}/${link_target}" ;;
    esac
fi

if ! command -v "${apm_bin}" >/dev/null 2>&1; then
    echo "apm CLI not found, skipping apm install --global" >&2
    exit 0
fi

# 実行中の nono セッションは CLAUDE_CONFIG_DIR 経由で link の実体のパスへ直接書くので、
# de-link している数秒のあいだに書き込みがあると実体が再出現し、re-link の段で exit 70 に倒れる
# (データは守られるが、両パスを人が照合して戻す必要が出る)。止める理由にはしない
# (誤検知で apply が止まるほうが困る)が、警告は出す。
# パターンは実際の argv で検証済み: `nono run --profile claude-seal --allow-cwd -- <cmd>`。
# pgrep 自体がプロセス一覧を取れない環境(サンドボックス内)では黙って何も出ないが、
# 消えるのは警告だけで de-link の判断は変わらないので、そのままにしてある。
if pgrep -f 'nono run --profile claude-seal' >/dev/null 2>&1; then
    echo "WARNING: a nono claude-seal session is running; if it writes its config while ~/.claude.json is temporarily de-linked, the real file reappears and this script aborts with exit 70" >&2
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
        echo "WARNING: ~/.claude.json is a symlink but its target ${link_target} is not a regular file; leaving the topology alone" >&2
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
        ln -s "${link_target}" "${link_path}"
    fi
fi

if [ "${apm_status}" -ne 0 ]; then
    echo "WARNING: apm install --global --target ${apm_targets} failed; re-run it manually to sync MCP servers" >&2
fi

exit "${apm_status}"
