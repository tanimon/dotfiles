#!/bin/sh
# Claude Code の Bash tool サンドボックス専用の git credential helper ラッパー。
# claude-code.inc から credential.helper として指定される。
#
# 目的: サンドボックスのHTTPプロキシ(localhost:<ランダムポート>)向けの
# credential 操作だけを黙って捨て、それ以外は本来の Git Credential Manager
# (GCM) にそのまま委譲する。
#
# 背景: Claude Codeのネイティブサンドボックスは HTTP_PROXY 等に
# `http://<user>:<pass>@localhost:<port>` を設定する。gitはこのプロキシ認証を
# credential機構経由で扱うため、通信成功後に `credential approve` を発行し、
# GCMが `store` で呼ばれる。するとGCMは
#   1. ホストプロバイダ自動判定のため `http://localhost:<port>/` をプローブ
#      → サンドボックスが接続を拒否
#      → `warning: Permission denied (localhost:<port>)`
#   2. Genericプロバイダとしてプロキシ資格情報をmacOSキーチェーンへ保存
#      → サンドボックスがキーチェーン書き込みを拒否
#      → `fatal: Could not create new item [0x186a1]`
# の2つをstderrに出す(git自体は成功し終了コードは0だが、毎回ノイズになる)。
#
# なぜラッパーが必要か: `credential.<url>.helper` はポートを省略したパターンが
# ポート付きホストにマッチしない(実測: `credential.http://localhost.helper=` は
# `host=localhost:63229` に効かない。完全一致のみ)。プロキシのポートは
# セッションごとに変わるため、静的なgitconfigではURL指定で除外できない。
#
# なお、そもそもセッション限りのプロキシ資格情報をキーチェーンに永続化する
# 必要はないため、捨てて問題ない。

GCM=/usr/local/share/gcm-core/git-credential-manager

# stdin(key=value の並び)を読み切る。$(...) は末尾改行を落とすので後で復元する。
input=$(cat)

# ループバックホスト(= サンドボックスのプロキシ)宛なら何もせず終了。
# 行全体でのマッチにして `path=...host=localhost` 等の部分一致誤爆を防ぐ。
if printf '%s\n' "$input" | grep -qxE 'host=(localhost|127\.0\.0\.1|\[::1\])(:[0-9]+)?'; then
    exit 0
fi

# それ以外はGCMへ委譲。プロトコルの終端である空行を復元して渡す。
printf '%s\n\n' "$input" | exec "$GCM" "$@"
