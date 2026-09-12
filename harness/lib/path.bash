#!/usr/bin/env bash
# manifest の path / source / owner に共通の「ファイルシステムのパスになる値」の拒否ルール。
# manifest.bash(harness.sh 経由)と各 adapter(file.sh)が source する。依存: jq。set は呼び出し側に従う。
#
# 正規化はせず拒否する(realpath は macOS 標準に無い): 絶対パス・"."/".." セグメント・空セグメント(//)・
# 末尾の /・制御文字(改行・タブ等)を含む値は、"./AGENTS.md" のような別表記で重複検出(生パスの文字列一致)を
# すり抜けて 1 Target に 2 owner を許したり、--root / HARNESS_SOURCE_DIR の外を指したりする(#309 レビュー Critical-1)。
# 照合は jq(Oniguruma)の test() で行い、manifest.bash と adapter が同じ正規表現・同じエンジンを使う。
#
# shellcheck disable=SC2034 # 定数は source 先(manifest.bash / file.sh)で使う
HARNESS_RELPATH_REJECT_RE='^/|(^|/)\.\.?(/|$)|//|/$|[[:cntrl:]]'
HARNESS_RELPATH_RULE_TEXT='先頭の /、. や .. のセグメント、//、末尾の /、制御文字は使えません'
# owner は adapter のファイル名(<adapterDir>/<owner>.sh)になるので 1 セグメントに限る
HARNESS_OWNER_RE='^[A-Za-z0-9_-]+$'

# relpath_rejected VALUE: VALUE が拒否ルールに当たれば 0
relpath_rejected() {
    # shellcheck disable=SC2016 # $v / $re は jq の --arg 変数
    [ "$(jq -rn --arg v "$1" --arg re "$HARNESS_RELPATH_REJECT_RE" '$v | test($re)')" = "true" ]
}
