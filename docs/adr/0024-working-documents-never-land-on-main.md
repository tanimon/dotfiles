---
status: accepted
date: 2026-10-31
---

# Working Document は main に入れず、マージ前に PR の中で正本へ抽出して消す

brainstorm・plan・spec などの Working Document は、ブランチ上では commit してよい。ただしマージ前に、価値のある部分だけを正本へ移して削除する。spec と plan はブランチ上で Requirements Document として Review-Verify に読まれる。価値があるのは「今後の判断に必要で、コード・テスト・rules・CLAUDE.md・ADR・solutions・GLOSSARY のどこにも書かれていない情報」と「調べ直しが高くつく、引用付きの事実」だけで、経緯そのものは価値に含めない。経緯は PR に残る。main に入れてから後で剪定する方式では、剪定の担当が動かず、`docs/{brainstorms,ideation,plans,residual-review-findings,superpowers}/` に約 150 件が溜まった。PR の差分という機械的に検査できる地点に寄せれば、消し忘れを CI で止められる。

## 振り分け

| 中身 | 移す先 |
|---|---|
| ADR の 3 条件を満たす決定 | `docs/adr/` |
| 壊れて直した記録・ハマりどころ | `docs/solutions/`(既存の文書があれば追記) |
| 用語 | `GLOSSARY.md` |
| 調べ直しが高くつく、引用付きの事実 | `docs/research/` |
| 上のどれにも当たらない | 削除 |

基準はディレクトリを問わず 1 本で、ディレクトリごとに違うのは判定するタイミングだけ。

- **Working Document**: 実装したブランチのマージ前に判定する。plan はコードが正本になるので、抽出するものは残らない。
- **`docs/solutions/`**: 対象の仕組みやツールがリポジトリから消えた時点で削除する。rules や CLAUDE.md の Known Pitfalls に要約済みでも、要約から辿れる「なぜ」の記録として残す。
- **`docs/research/`**: 正本として main に置き、新しい調査で置き換えられた時点で削除する。

## Considered Options

- **main に入れてから、harness-review などの定期的な剪定で消す** — 却下。main の git 履歴に本文が残るが、消し忘れが溜まる。今回の整理はその結果。
- **経緯にも価値を認め、整理は重複と陳腐化の除去に留める** — 却下。経緯は PR に残り、main に置くと読み手が今も正しいかを判断できない文書が増える。
- **仕事リポジトリと同じく、どこでも gitignore して commit しない** — 却下。`includeIf` の切り替えと CI の検査が要らなくなる。しかし spec がローカルの worktree にしか残らず、worktree を消すと PR のコミットからも辿れなくなる。
- **消した文書へのリンクを PR 番号やコミット SHA に固定したリンクに置き換える** — 却下。価値なしと判定したものを指すことになり、`dot_claude/rules/common/code-comments.md` もコメントに SHA や経緯を書かないことを求めている。

## Consequences

- squash merge なので、PR の中で消した Working Document は main の履歴に一度も入らず、PR のコミット(`refs/pull/N/head`)にだけ残る。PR の差分(Files changed)にも出ないので、レビュー中に spec を読めるように、PR 本文に削除前のコミット SHA に固定した spec へのリンクを書く。PR 本文は経緯を書く場所なので、上の却下理由には当たらない。
- ブランチ上の作業順は「実装 → Review-Verify → 抽出と削除 → マージ」になる。
- PR の差分(`origin/main...HEAD`)が Working Document の置き場所(現時点で `docs/superpowers/`)にファイルを追加していたら、CI と just のレシピで落とす。削除は通す。置き場所の一覧は 1 ファイルに持ち、gitignore の切り替え設定と同じ一覧を指す。この検査はまだ実装していない。
- 書き込み元の無い `docs/{brainstorms,ideation,plans,residual-review-findings}/` は、空にした後に gitignore の切り替え設定と `.gitignore` から記載を消す。ただし仕事リポジトリにこれらのディレクトリが残っていて、除外を外すと untracked として現れるなら、デフォルト側(`dot_gitignore.tmpl`)の除外は残す。
- 消した文書を指していたリンクは抽出先へ張り替え、抽出先が無ければリンクごと削除する。
- 個人リポジトリで Working Document を commit する `includeIf` の切り替え(`.claude/rules/gitignore-includeif.md`)はそのまま残る。目的が「開発経緯として残す」から「ブランチ上で Requirements Document として持ち回る」に変わる。
- `docs/adr/README.md` の「既存分の一括移送はしない」は取り下げ、既存の spec からも未抽出の決定を ADR へ移す。
