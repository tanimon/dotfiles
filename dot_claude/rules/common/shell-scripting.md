---
date: 2026-07-29
trigger: "エージェントが bash 3.2 で壊れるシェルスクリプトを書いた（`$VAR` 直後の非ASCII 文字、bash 4 以降専用構文）"
paths:
  - "*.sh"
  - "*.sh.tmpl"
---

# シェルスクリプト

## `$VAR` の直後に非ASCII 文字を置かない — `${VAR}` で囲む

日本語メッセージに変数を埋めるときは必ず `${VAR}` の形で囲む。

**誤:** `echo "対象は $COUNT件です"`
**正:** `echo "対象は ${COUNT}件です"`

**理由:** bash 3.2（macOS の `/bin/bash` 既定）は変数名のパースでマルチバイト文字を吸収するため、
`$COUNT件` は「`COUNT件` という別の変数」への参照になる。`set -u` 下では
`unbound variable` で即死し、そうでなければ**空文字に展開されて静かに壊れる**。

```console
$ /bin/bash -c 'set -u; C=3; echo "$C件"'
/bin/bash: C\xe4: unbound variable
$ /bin/bash -c 'set -u; C=3; echo "${C}件"'
3件
```

**気づきにくい理由:** bash 5（Linux / CI / homebrew の bash）では再現しない。CI が緑でも
開発機の macOS で落ちる。しかも該当の `echo` に到達した実行だけが落ちるので、
条件分岐の中にあると忘れられたまま残る。

**適用範囲:** 日本語（およびあらゆる非ASCII）を含むシェルスクリプト全般。`${VAR}` で囲むコストは
ゼロなので、直後が ASCII かどうかを判断するより「メッセージ内の変数は常に `${}`」で統一するほうが安い。
`*.sh.tmpl` のようにテンプレート拡張子が付いたシェルスクリプトも対象 — こちらは shellcheck が
構文を解釈できず lint 対象から外れるため、下記の機械チェックが唯一の防波堤になる。

**機械チェック:**

```bash
perl -ne 'next if /^\s*#/; while (/\$([A-Za-z_][A-Za-z0-9_]*)(?=[^\x00-\x7F])/g) { print "$ARGV: $&\n" } close ARGV if eof' path/to/*.sh
```

実例: あるプロジェクト専用の検証スキルの `scripts/selftest.sh` がこのチェックを回帰テストとして持っている。

## macOS の bash 3.2 で使えない構文を避ける

同じ「開発機だけで落ちる」型の落とし穴。`mapfile` / `readarray`、連想配列（`declare -A`）、
`${var^^}` / `${var,,}`（大文字小文字変換）は bash 4 以降の機能で、macOS 標準の bash では動かない。
`while IFS= read -r` ループや `tr` で代替する。

`set -u` 下では**空配列の展開**も bash 3.2 ではエラーになる（`"${ARR[@]}"` が
`unbound variable`）。空になりうる配列は要素数を確認してから展開するか、配列を使わない形に倒す。
