# Architecture Decision Records

このリポジトリの構成上の決定を記録する。`/domain-modeling` skill（`/grill-with-docs` と `/improve-codebase-architecture` から到達）が、決定が確定した時点で1件ずつ追加する。

形式の正典は `mattpocock-skills` の `domain-modeling/ADR-FORMAT.md`。以下はその要約と、このリポジトリ固有の補足。

## `docs/solutions/` との違い

| | 記録するもの | 問い |
|---|---|---|
| `docs/adr/` | 選択した設計と、なぜそれを選んだか | 「なぜこの方式なのか」 |
| `docs/solutions/` | 踏んだ問題とその解決 | 「何が壊れてどう直したか」 |

同じ話題を両方に書かない。決定を下したなら ADR、壊れて直したなら solution。壊れた結果として方式を変えたなら、solution に経緯を書き ADR に決定を書いて相互リンクする。

## ファイル名

`NNNN-kebab-case-title.md`（例: `0001-manage-mcp-servers-via-apm.md`）。`docs/adr/` の最大番号を見て +1 する。この README は採番の対象外。

## フォーマット

```md
# {決定の短いタイトル}

{1〜3文: どういう文脈で、何を決めて、なぜそうしたか。}
```

**これだけでよい。ADR は1段落で完結してよい。** 価値は「決定がなされた事実」と「その理由」を残すことにあり、セクションを埋めることではない。

### 任意のセクション

本当に価値があるときだけ追加する。ほとんどの ADR には不要。

- **Status** frontmatter（`proposed | accepted | deprecated | superseded by ADR-NNNN`）— 決定を後から見直す可能性があるとき
- **Considered Options** — 却下した代替案を覚えておく価値があるとき
- **Consequences** — 自明でない下流への影響を明示する必要があるとき

## ADR を書く基準

次の3つが**すべて**成り立つときだけ書く。

1. **覆すのが高い** — 後で考えを変えるコストが実質的にある
2. **文脈なしでは意外に見える** — 将来の読者が「なぜこうなっているのか」と思う
3. **本物のトレードオフの結果** — 実在する代替案があり、理由があって一方を選んだ

1つでも欠けるなら書かない。簡単に覆せるなら覆せばよいし、意外でないなら誰も理由を探さないし、代替案がなかったなら「当たり前のことをした」以上の記録は要らない。

### このリポジトリで該当しやすいもの

`CLAUDE.md` の Architecture セクションにある方式判断（chezmoi のファイルパターン選択、MCP を APM で管理する / Skill を native marketplace に戻す、nono の profile 境界、gitignore を `includeIf` で場所単位に切り替える等）は、いずれも上の3条件を満たす。既に `CLAUDE.md` と `docs/superpowers/specs/` に散在しているため、新規の決定から ADR に寄せていく（既存分の一括移送はしない）。
