#!/usr/bin/env bash
# precheck.sh と postcheck.sh が共有する定義。source 専用で、set は呼び出し側に従う。

# 起動前の値を起動後の確認へ渡すファイルのパス。--dir の下に置く。
review_verify_state_path() { # <dir>
    printf '%s/state.json' "$1"
}

# 検査を実行できない(引数の不備など)ときと、precheck の中止。どちらも終了コード 2 にする。
review_verify_die() {
    printf '%s\n' "$1" >&2
    exit 2
}
