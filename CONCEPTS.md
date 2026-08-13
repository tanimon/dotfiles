# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## Managed files

### Source
The version-controlled file this repository owns and edits — the authority for what a managed file should contain. Naming conventions on a Source's filename encode how it maps to its Target and what permissions the Target receives, so the mapping is derived from the name rather than declared separately.

A Source is not always a literal copy of its Target. Some Sources are templates rendered per machine; others are scripts that receive the current Target and emit a modified version, letting the repository own only a subset of a file whose remainder is written by an external tool at runtime.

### Target
The deployed file in the home directory that a Source renders to. Targets are generated output: an edit made directly to a Target is overwritten the next time the repository is applied and is never version-controlled. Every "where do I change this?" resolves to the Source, never the Target.

Rendering is one-directional and is performed from whichever checkout the tool treats as its source directory — not necessarily the checkout being edited. A change that is committed but not yet present in that source directory will not appear in a Target, and the absence reads as "nothing to deploy" rather than as an error.

A Target's writers are not only the people who open it. The application a Target configures often writes its own settings back into that same file at runtime, and such a write is indistinguishable from a hand edit — it is discarded by the next apply just the same, silently and with no record of what was there. A setting that keeps being lost this way is a setting whose home is the Source.

A runtime write-back does not need to lose or change any value to still cause trouble: it can rewrite the Target's byte-level structure — an object's key order, for instance — while preserving its content exactly. Verification tooling that compares a Target byte-for-byte cannot tell that difference from a real one, and reports drift on every such write even though nothing of substance changed, burying genuine differences in the same noise. A tool-owned comparison step (a diff hook, not the Target itself) can be made to compare on a canonicalized form instead, so this class of churn stops being reported — but this only fixes the comparison step it was applied to; any other comparison that still reads the Target's raw bytes keeps reporting the churn.

When a Target is only partially owned — its Source is a script that reads the Target's current state and re-emits a modified version, rather than a template rendered from scratch — the transform re-derives the whole file from whatever it currently observes on every run. If that observation is empty or corrupted (a race with another writer, an aborted run), the Target's entire unmanaged portion can be lost even though the Source itself was never touched.

The write-back can also fail to preserve a property of the Target the transform never inspected, such as the Target being a symlink into another location: the transform faithfully reads the content through the symlink, but writes it back as an ordinary file at the symlink's own path, deleting the symlink even though the content itself was reproduced correctly.

When the runtime-written value cannot itself be declared in the Source — because the external application generates it dynamically rather than from any input the repository controls — the reconciling automation that re-asserts it must run unconditionally on every application of the Source, not only when some tracked input changes. The external application writes on its own schedule, independent of that input, so gating the reconciliation on it lets the loss recur silently on any later application where the tracked input happened not to change, even though the Source's own render still ran and still overwrote the Target.

## Permission policy

### Risk Tier
A four-level classification of a write command by how reversible its effect is and how far that effect reaches, used to decide whether the command runs unprompted or behind an approval gate. Tier 0 is local and fully reversible. Tier 1 appends to an existing container, creating no new work item and changing neither shared object state nor anyone's queue. Tier 2 changes shared object state — lifecycle transitions, mutation of existing objects, review verdicts. Tier 3 is destructive, irreversible, or rewrites history.

Tier 1 carries a second requirement beyond the append-only property merely being true: the property must be **enforceable by the permission rule syntax**. Rules match on command prefixes, so a command whose destructive spellings can be reached by moving a flag past the prefix cannot be Tier 1, however append-only its ordinary invocation appears. This requirement exists because classifying by concept rather than by what the matcher can express once silently removed a guardrail.

### Approval Gate
コマンドの実行前に操作者の承認を要求するルール。ゲートは一括許可より先に評価され、プロンプトを省略する設定下でも発火するため、無人実行を生き延びる唯一の統制手段である。

ゲートはコマンドのプレフィックスで照合するため、プレフィックスが届く綴りしかカバーしない — Risk Tier 1 を縛るのと同じ制約である。また、Isolation Boundary の外に出たコマンドに残る統制はゲートだけなので、ゲートのない Boundary Exclusion はそのコマンドを無統制にする。

Approval Gate は一致した時点でその呼び出しを確定させ、同じ呼び出しがより狭い一括許可にも一致する場合でも先に評価されて発火する。この優先順位はゲートと一括許可それぞれの一致範囲の広さ(具体性)には左右されない — 一括許可側にどれだけ狭い例外を書いても、ゲートが同じ呼び出しに一致する限りその例外は評価されずに終わる。ゲートを緩めるには一括許可側を狭めるのではなく、ゲート自身の一致範囲を狭めるか取り除く必要がある。

## Isolation boundary

### Isolation Boundary
コマンドがその内側で実行される境界。OS が強制し、既定では拒否する — 「エージェントがこれを実行した」を無制限な主張ではなく有界な主張にしているもの。どの実装が境界を提供するかはエージェントの起動方法で決まり、起動経路ごとに有効なのは常に 1 つだけなので、起動経路を言わずに「サンドボックス」と呼ぶのは曖昧である。
*Avoid:* サンドボックス（無限定）

境界は **fail open** に設定されうる。適用に失敗したとき、中止するのではなく無拘束のまま実行が続く。これにより「境界が不在」は「境界があって許可した」と観測上区別できなくなるため、1 回の成功実行は許可が効いたことを示さない — 何も止めなかったことしか示さない。許可が効いていると言うには、その許可だけを外して失敗が戻ることを確認する必要がある。

### Boundary Exclusion
名前を指定した 1 コマンドを Isolation Boundary の外、ホスト側で実行する例外指定。境界の内側では機能しないコマンドのために存在する。除外はそのコマンドについて隔離を外すだけで、追加の権限を与えず、追加の承認も要求しない。

除外と Approval Gate は独立した統制であり、危険なのはその積である: 除外かつ未ゲートのコマンドは、任意のホストコードを — リポジトリ自身が供給するコード、たとえばバージョン管理のフックを含めて — 何にも拘束されず何のプロンプトもなく実行する。コマンドを境界の外に出す除外より、境界の内側に留めたまま目的専用の許可を与える方を優先すること。除外せざるを得ない場合は、何がそれをゲートしているかを確認する。

除外は指定した名前でリテラルに直接起動された場合にしか効かない。サブシェル経由やラッパースクリプト経由など、同じ論理コマンドでも呼び出し文字列がその名前で始まらない間接呼び出しには効かず、その場合コマンドは除外されず Isolation Boundary の内側で実行される（マッチングがコマンド文字列の先頭にしか届かない点は Approval Gate と同種の制約 — Approval Gate の項参照）。同一の論理コマンドが呼び出し方だけで境界の内外を行き来しうるため、除外に載っていることをもって「このコマンドは常に統制不要」と判断してはならない。

## Verification

### Contrast Pair
Fail open で無効化されうる仕組み(Isolation Boundary の許可、名前解決で対象が入れ替わりうる設定ファイルなど)を検証する手法。対象の許可/設定を通した1回の成功実行だけでは、仕組みが機能して許可したのか、仕組み自体が適用されていない(または意図した対象を見ていない)のかを区別できない。その許可/設定だけを取り除いた実行をもう一度行い、結果が反転する(失敗に転じる)ことまで確認して初めて、仕組みが機能している証拠になる。
*Avoid:* 対比ペア、対照検証(いずれも同じ概念の揺れ、Contrast Pair に統一)

Contrast Pair 自体にも限界がある: 両側の実行が同じ誤った解決パス(例: 名前解決が常に別の Target を指す)を経由している場合、両側とも同じ誤った対象を検証してしまい、反転が観測できても仕組みの機能証明にはならない。Contrast Pair が示すのは「check が2つの状態を区別できること」のみで、両状態が実際に意図した対象(Source)を読んでいることまでは保証しない — 解決パスの正しさは別途確認が必要。

## Flagged ambiguities

- 「profile」は無関係な 2 つを指してきた — 1 台のマシンの用途区分（work / personal。dotfiles のレンダリングを分岐させる）と、Isolation Boundary が何を許可するかを定義するポリシー文書。文脈だけでは決まらないので、どちらの意味かを毎回明示する。
