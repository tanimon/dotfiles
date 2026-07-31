# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## Managed files

### Source
The version-controlled file this repository owns and edits — the authority for what a managed file should contain. Naming conventions on a Source's filename encode how it maps to its Target and what permissions the Target receives, so the mapping is derived from the name rather than declared separately.

A Source is not always a literal copy of its Target. Some Sources are templates rendered per machine; others are scripts that receive the current Target and emit a modified version, letting the repository own only a subset of a file whose remainder is written by an external tool at runtime.

### Target
The deployed file in the home directory that a Source renders to. Targets are generated output: an edit made directly to a Target is overwritten the next time the repository is applied and is never version-controlled. Every "where do I change this?" resolves to the Source, never the Target.

Rendering is one-directional and is performed from whichever checkout the tool treats as its source directory — not necessarily the checkout being edited. A change that is committed but not yet present in that source directory will not appear in a Target, and the absence reads as "nothing to deploy" rather than as an error.

When a Target is only partially owned — its Source is a script that reads the Target's current state and re-emits a modified version, rather than a template rendered from scratch — the transform re-derives the whole file from whatever it currently observes on every run. If that observation is empty or corrupted (a race with another writer, an aborted run), the Target's entire unmanaged portion can be lost even though the Source itself was never touched.

## Permission policy

### Risk Tier
A four-level classification of a write command by how reversible its effect is and how far that effect reaches, used to decide whether the command runs unprompted or behind an approval gate. Tier 0 is local and fully reversible. Tier 1 appends to an existing container, creating no new work item and changing neither shared object state nor anyone's queue. Tier 2 changes shared object state — lifecycle transitions, mutation of existing objects, review verdicts. Tier 3 is destructive, irreversible, or rewrites history.

Tier 1 carries a second requirement beyond the append-only property merely being true: the property must be **enforceable by the permission rule syntax**. Rules match on command prefixes, so a command whose destructive spellings can be reached by moving a flag past the prefix cannot be Tier 1, however append-only its ordinary invocation appears. This requirement exists because classifying by concept rather than by what the matcher can express once silently removed a guardrail.

### Approval Gate
コマンドの実行前に操作者の承認を要求するルール。ゲートは一括許可より先に評価され、プロンプトを省略する設定下でも発火するため、無人実行を生き延びる唯一の統制手段である。

ゲートはコマンドのプレフィックスで照合するため、プレフィックスが届く綴りしかカバーしない — Risk Tier 1 を縛るのと同じ制約である。また、Isolation Boundary の外に出たコマンドに残る統制はゲートだけなので、ゲートのない Boundary Exclusion はそのコマンドを無統制にする。

## Isolation boundary

### Isolation Boundary
コマンドがその内側で実行される境界。OS が強制し、既定では拒否する — 「エージェントがこれを実行した」を無制限な主張ではなく有界な主張にしているもの。どの実装が境界を提供するかはエージェントの起動方法で決まり、起動経路ごとに有効なのは常に 1 つだけなので、起動経路を言わずに「サンドボックス」と呼ぶのは曖昧である。
*Avoid:* サンドボックス（無限定）

境界は **fail open** に設定されうる。適用に失敗したとき、中止するのではなく無拘束のまま実行が続く。これにより「境界が不在」は「境界があって許可した」と観測上区別できなくなるため、1 回の成功実行は許可が効いたことを示さない — 何も止めなかったことしか示さない。許可が効いていると言うには、その許可だけを外して失敗が戻ることを確認する必要がある。

### Boundary Exclusion
名前を指定した 1 コマンドを Isolation Boundary の外、ホスト側で実行する例外指定。境界の内側では機能しないコマンドのために存在する。除外はそのコマンドについて隔離を外すだけで、追加の権限を与えず、追加の承認も要求しない。

除外と Approval Gate は独立した統制であり、危険なのはその積である: 除外かつ未ゲートのコマンドは、任意のホストコードを — リポジトリ自身が供給するコード、たとえばバージョン管理のフックを含めて — 何にも拘束されず何のプロンプトもなく実行する。コマンドを境界の外に出す除外より、境界の内側に留めたまま目的専用の許可を与える方を優先すること。除外せざるを得ない場合は、何がそれをゲートしているかを確認する。

## Flagged ambiguities

- 「profile」は無関係な 2 つを指してきた — 1 台のマシンの用途区分（work / personal。dotfiles のレンダリングを分岐させる）と、Isolation Boundary が何を許可するかを定義するポリシー文書。文脈だけでは決まらないので、どちらの意味かを毎回明示する。
