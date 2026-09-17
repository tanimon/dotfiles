---
title: PreToolUse フックの allow は permissions.ask を上書きする — 「広い ask + フックで緩める」というフェイルクローズな緩和の形
date: 2026-09-17
last_updated: 2026-09-17
category: workflow-issues
module: permission-design
problem_type: workflow_issue
component: claude_code_permissions
severity: medium
applies_when:
  - "permissions.ask にある広いエントリの一部だけを無承認にしたいが、prefix 照合では条件を表現できないとき(引数位置が自由なフラグ・URL など)"
  - "PreToolUse フックで許可判定を書こうとしていて、rule 側を外すか残すかを決めるとき"
  - "他人が書いたコマンド文字列を走査して判定するスクリプトを書くとき"
  - "承認プロンプトの頻度(承認疲れ)を下げる変更を設計していて、どの層で緩めるか迷っているとき"
symptoms:
  - "`Bash(curl http://localhost:*)` のような allow エントリを足しても、フラグが先にある実際の呼び出し(`curl -sS -H … URL`)にマッチしない"
  - "allow に足したのに ask が勝ってプロンプトが出続ける"
  - "判定フックのテストが全件通るのに、クォート付き引数を渡すと正当なコマンドが黙って拒否される"
---

## 問題

`permissions` のルールは**プレフィックス照合**なので、判定したい情報がコマンドの先頭に来ない
ケースを表現できない。このリポジトリではこれを 2 回踏んでいる:

- `git push origin main --force` — write intent がフラグ位置に移動できるため、
  `Bash(git push --force:*)` という `deny` が当たらない
- `curl -sS -H "Accept: application/json" http://localhost:3000/api` — URL がフラグの後ろに
  来るため、`Bash(curl http://localhost:*)` という `allow` が当たらない

どちらも「広いエントリを `permissions.ask` に置く」以外に手が無く、その結果として日常的な
操作まで毎回プロンプトになる(承認疲れ)。

## 分かったこと

**PreToolUse フックが返す `hookSpecificOutput.permissionDecision: "allow"` は、同じ呼び出しに
一致する `permissions.ask` ルールよりも優先される。** ドキュメントの「allow bypasses the
permission system」という記述どおりだが、一文を根拠にせず対照ペアで実測した(2026-09-17)。

```sh
# control: ask だけ → 非対話セッションなので許可待ちのままブロックされる
command claude -p '…curl を実行して…' --model haiku < /dev/null \
  --settings '{"sandbox":{"enabled":false},"permissions":{"ask":["Bash(curl:*)"],"defaultMode":"default"}}'
# => 「非インタラクティブなため許可を要求していますが応答できません」

# treatment: 同じ設定 + 常時 allow を返す PreToolUse フック → 実行される
command claude -p '…curl を実行して…' --model haiku < /dev/null \
  --settings "$(cat with-hook.json)"   # hooks.PreToolUse[].hooks[].command = 常時 allow を吐くスクリプト
# => curl 8.9.1 … (実際に実行された)
```

片側だけでは「そもそもそのコマンドが動く環境か」しか分からない。
[verification-through-the-wrong-resolution-path.md](verification-through-the-wrong-resolution-path.md)
と同じ理由で、**対で**回すこと。

### 実測時の落とし穴

- **`claude` シェル関数は使えない。** `dot_config/zsh/sandbox.zsh` のラッパーが
  `--dangerously-skip-permissions` を渡すので、権限の実測が全部素通りして「フックが効いた」と
  誤読する。必ず `command claude`。
- ネストした Seatbelt は `sandbox_apply: Operation not permitted` で落ちるので、
  `--settings` に `{"sandbox":{"enabled":false}}` を含める。
- `-p` は stdin を待つ(`no stdin data received in 3s`)ので `< /dev/null` を付ける。
- テスト用プロンプトに `$` を入れない。判定フック側が `$` を「読み切れない」として落とす設計だと、
  プロンプトの `$?` が生成コマンドに混ざって treatment が失敗し、フックのバグと誤診する。

## 設計上の含意 — フックの「向き」でフェイル方向が決まる

同じ PreToolUse フックでも、rule 側をどうするかで安全方向が逆になる。**ここが 2 つのフックを
混同しないための唯一重要な区別。**

| | 塞ぐ向き(git-push-guard) | 緩める向き(curl-localhost-guard) |
|---|---|---|
| rule 側 | `ask` を**外す** | `ask` を**残す** |
| フックの返り値 | `deny` / `ask` / 無出力 | `allow` / 無出力 |
| フックが死んだら | 無出力 = 判定なし → **フェイルオープン** | 無出力 → `ask` が出る → **フェイルクローズ** |
| `deny` の冗長エントリ | **要る**(多層防御の床) | 要らない |

緩める向きが取れるなら、そちらを選ぶ。`permissions.ask` が常に評価される土台として残るので、
フックの未配置・クラッシュ・`jq` 不在・パース不能な綴り — すべてが「従来どおりプロンプト」に
落ちる。`deny` に冗長な行を並べて多層防御を作る必要がない。

逆に塞ぐ向きを選ぶときは、フックが死んだ場合にフェイルオープンすることを設計判断として明記し、
最も一般的な綴りの `deny` 行を rule 側に残すこと(`dot_claude/settings.json.tmpl` の
force-push 3 行がそれ)。

## 実装で踏んだこと — `read -ra` はクォートを解釈しない

判定フックはコマンド文字列を自分でトークン化する必要があるが、`read -ra tokens <<<"$cmd"` は
空白でしか割らないので両方向に壊れる:

- `-H "Accept: application/json"` が 3 トークンに割れ、`application/json"` が次の引数(URL)として
  読まれる → **正当なコマンドが黙ってプロンプトに落ちる**
- `-d '{"a":"x|y"}'` の `|` をパイプと誤読する(`tr ';&|' '\n'` でセグメント分割している場合)
- `2>&1` から `&` だけ落とすと `1` が孤立し、引数として読まれる

**クォート無しの短い入力ばかりでテストすると全件通過する。** 実際 47 件中 45 件が通り、
落ちたのはクォート付き引数の 2 件だけだった。対処はクォートとエスケープを解釈する自前の 1 文字走査
で、**前提として `$` / バッククォートを含む入力を先に拒否**しておく — 展開が残っていたらどう読んでも
嘘になるので、それを落としてはじめてクォート解釈が忠実な読みになる。
ルール化: `dot_claude/rules/common/shell-scripting.md`。

## 関連

- `dot_claude/scripts/CLAUDE.md` — 両フックの詳細と残存リスク
- `docs/superpowers/specs/2026-07-25-permission-tier-model-design.md` — Tier 1(rule で強制可能)と
  hook-enforced の区別
- `test/curl-localhost-guard.bats` / `test/git-push-guard.bats` — 判定が出るべきケースと出ない
  べきケースを対で書く規約
