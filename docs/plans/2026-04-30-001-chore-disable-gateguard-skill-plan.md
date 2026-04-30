---
title: "chore: disable everything-claude-code:gateguard skill"
type: chore
status: active
date: 2026-04-30
origin: https://github.com/tanimon/dotfiles/issues/188
---

# chore: disable everything-claude-code:gateguard skill

## Summary

`everything-claude-code` プラグインの `gateguard` スキル(Bash/Edit/Write を最初の1回毎に "Fact-Forcing Gate" でブロックする hook)をオフにし、それに付随するサンドボックス側の対症療法(`~/.gateguard` を `safehouse --add-dirs` と `cco --add-dir` の allowlist に追加 + `dot_gateguard/dot_keep` の placeholder)も巻き取りで撤去する。`ECC_DISABLED_HOOKS` 環境変数で gateguard hook 2 件 (`pre:bash:gateguard-fact-force`, `pre:edit-write:gateguard-fact-force`) を明示的に無効化する。

---

## Problem Frame

gateguard hook は本来「最初の Bash と各ファイルへの最初の Edit/Write で事実提示を強制する」機能だが、本リポジトリの agent-safehouse Seatbelt サンドボックス環境では運用負荷が高い:

- `~/.gateguard/` を読書可にするため safehouse / cco 両方の allowlist と chezmoi 管理の placeholder (`dot_gateguard/dot_keep`) という3箇所を維持し続ける必要がある(PR #186, #187 で対症)
- ファクト提示を強制するため通常作業のフローが毎回中断する(LFG・cron 系の自動パイプラインや、複数ファイルを連続編集する作業で特にコストが大きい)
- Issue #188 で「Skill を無効化したい」とユーザが明示的に要求

事実強制ゲートは設計意図としては理解できるが、本リポジトリでは費用対効果が見合わないため、hook を無効化したうえで関連する補助インフラも撤去する。

---

## Requirements

- R1. gateguard hook (`pre:bash:gateguard-fact-force`, `pre:edit-write:gateguard-fact-force`) が `chezmoi apply` 後の新規 claude セッションで発火しないこと
- R2. `~/.gateguard/` を扱う対症療法(safehouse `--add-dirs`、cco `--add-dir`、chezmoi placeholder)が削除され、関連設定がリポジトリから整合した状態で除去されること
- R3. 過去の解決ドキュメント(`docs/solutions/integration-issues/gateguard-fact-force-sandbox-state-dir-2026-04-19.md`、`safehouse-add-dirs-requires-existing-path-2026-04-30.md`)の状態が現実に合うよう、無効化された旨を明示する後追いを残すこと(完全削除はせず履歴は保持)
- R4. `make lint` と `chezmoi apply --dry-run` がローカルで通ること(secretlint / shellcheck / actionlint / sensitive scan / template check 含む)
- R5. `everything-claude-code` プラグイン全体や他の ECC hook は影響を受けないこと(`gateguard` のみを最小スコープで無効化)

---

## Scope Boundaries

- `everything-claude-code` プラグイン全体の `enabledPlugins` トグルは変更しない。プラグイン経由で提供される他のスキル/hook(continuous-learning observer, ECC briefing 等)は維持する
- gateguard skill の `SKILL.md` 自体やプラグインキャッシュ配下のファイルは編集しない(プラグイン更新で上書きされる、外部コードを直接いじらない方針)
- `safehouse` `cco` 全体の sandbox 設計には触らない。あくまで `~/.gateguard` 行のみ撤去する
- gateguard を将来再有効化する余地は残す(`ECC_DISABLED_HOOKS` を消すだけで戻せる単純な環境変数アプローチを採用する理由でもある)

### Deferred to Follow-Up Work

- gateguard を別形態(`ECC_HOOK_PROFILE=minimal` などのプロファイル切替)で運用するかの検討は現状不要。本タスクでは hook ID 単位の disable に閉じる

---

## Context & Research

### Relevant Code and Patterns

- `dot_claude/settings.json.tmpl` lines 3-11 — `env` ブロック。`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`, `CLV2_CONFIG` など既存の env 追加実績がある。ここに `ECC_DISABLED_HOOKS` を追加する
- `dot_config/safehouse/config.tmpl` の `# --- Working directories (read-write) ---` セクションに `--add-dirs={{ .chezmoi.homeDir }}/.gateguard` 行が存在する
- `dot_config/cco/allow-paths.tmpl` の `# GateGuard fact-forcing hook session state (else hook blocks every Bash)` コメント + 続く `{{ .chezmoi.homeDir }}/.gateguard` 行を削除する
- `dot_gateguard/dot_keep` (0 byte placeholder) を削除し、空になる `dot_gateguard/` ディレクトリも source ツリーから外す
- 対象 hook ID の正確な綴り:
  - `pre:bash:gateguard-fact-force` (`scripts/hooks/bash-hook-dispatcher.js` で登録)
  - `pre:edit-write:gateguard-fact-force` (`hooks/hooks.json` で登録)
- `scripts/lib/hook-flags.js` `getDisabledHookIds()`: `ECC_DISABLED_HOOKS` をカンマ区切りで読み、小文字正規化した Set にする。スペース許容(trim される)

### Institutional Learnings

- `docs/solutions/integration-issues/gateguard-fact-force-sandbox-state-dir-2026-04-19.md` — 当時の対症療法(hook を生かしたまま `~/.gateguard` を allowlist 追加)の経緯
- `docs/solutions/integration-issues/safehouse-add-dirs-requires-existing-path-2026-04-30.md` — `--add-dirs` のパス先存在トラップを発見した経緯。同 doc の "Workarounds considered and rejected" セクションで `ECC_DISABLED_HOOKS=pre:bash:gateguard-fact-force` は「便利なゲートを失う」として却下されているが、issue #188 でユーザが明示的に無効化を選択したため、本計画ではこの選択を採用する旨を doc 側で追記する
- `~/.claude/projects/-Users-akito-tanikado--local-share-chezmoi/memory/safehouse_add_dirs_startup_path_existence.md` — `--add-dirs` のランタイム追加が効かない、safehouse 起動時にパスが必要という挙動。今回は逆に "そもそも allowlist エントリが要らなくなる" 側に倒す
- `.chezmoiignore` で repo-only な `docs/` 等を除外する慣習。`dot_gateguard/` 以下を消すだけで chezmoi の管理対象から外れるので追加の `.chezmoiignore` 編集は不要(検証で確認する)

### External References

- 不要(プラグイン作者ドキュメント `scripts/lib/hook-flags.js` のコメントに `ECC_DISABLED_HOOKS=comma,separated,hook,ids` と仕様が記載されており、そこから直接動作仕様を確認済み)

---

## Key Technical Decisions

- **無効化方法は `ECC_DISABLED_HOOKS` env var を採用する**: `ECC_HOOK_PROFILE=minimal` も候補だがプラグイン全体の hook を巻き込むため過大。`enabledPlugins` での全体無効化も他の便利な ECC スキル(observer, briefing)を失うため過大。hook ID 単位の disable が最小スコープで意図と一致する
- **2 つの hook ID 両方を明示する**: `pre:bash:gateguard-fact-force` と `pre:edit-write:gateguard-fact-force` は別の dispatcher / hooks.json で登録されているため、片方だけ disable すると Edit/Write 側 (もしくは Bash 側) が残る。両方をカンマ区切りで指定する
- **対症療法を併せて撤去する**: hook が動かなくなれば `~/.gateguard/` への書き込みは発生しないため、placeholder と sandbox allowlist は無意味になる。残しておくと「なぜこれがあるのか?」という考古学的な負債になるため一緒に消す。再有効化する場合は env var を抜くだけで以前の状態に戻せる(ただし sandbox 系と placeholder の再追加が必要になる旨は doc に明記する)
- **過去 solution doc の扱いは追記方式**: 完全削除すると「なぜ allowlist にエントリがあったか」「`dot_gateguard/dot_keep` placeholder のかつての意図」を後から追えなくなる。代わりに先頭付近に「2026-04-30 時点で無効化済み(issue #188 / 本 plan へのリンク)」の注意書きを足す

---

## Open Questions

### Resolved During Planning

- `enabledPlugins` で `everything-claude-code` を `false` にする選択肢: 過大な範囲の機能を失うため不採用。本計画では env var による hook ID 単位 disable のみ
- `ECC_HOOK_PROFILE=minimal` への切替: 同様に他 ECC hook(continuous-learning 等)を巻き込むため不採用
- placeholder + allowlist を残しつつ hook だけ disable: 残す合理性が薄く、リポジトリの S/N 比を下げるため、対症療法は撤去側に倒す

### Deferred to Implementation

- 既存の `~/.gateguard/` ディレクトリ(deploy 済み)を `chezmoi apply` 後に手動削除するか: chezmoi は source からエントリが消えても deploy 済みファイルは原則消さない。実装時に `chezmoi apply --dry-run` 結果を見て、必要なら手動 `rm -rf ~/.gateguard` の手順を PR description に書く判断をする
- 既存 `~/.gateguard/state-*.json` セッション状態ファイルが残る場合: hook 無効化後は読み書きされないため放置で害はないが、apply 後の確認時に決める

---

## Implementation Units

- U1. **`ECC_DISABLED_HOOKS` env var を `settings.json.tmpl` に追加**

**Goal:** `~/.claude/settings.json` の `env` ブロックに `ECC_DISABLED_HOOKS` を追加し、gateguard hook 2 件を無効化する。

**Requirements:** R1, R5

**Dependencies:** なし

**Files:**
- Modify: `dot_claude/settings.json.tmpl`

**Approach:**
- `env` オブジェクト内に `"ECC_DISABLED_HOOKS": "pre:bash:gateguard-fact-force,pre:edit-write:gateguard-fact-force"` を追加する
- 既存 env キーは機能ごとに並んでいる(`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`, `ENABLE_TOOL_SEARCH`, `HOME`, `LANG`, `CLV2_CONFIG`, `_ZO_DOCTOR`)。新規キーは関連グループ(`CLV2_CONFIG` 付近の continuous-learning / ECC 系)の直後に配置する
- 値はカンマ区切り、空白なし。`hook-flags.js` `normalizeId` が trim+lowercase するため大文字小文字混在は許容されるが、ID は元から小文字なのでそのまま記述する
- 直前のキーには末尾カンマが必要、最後のキー(`_ZO_DOCTOR`)には末尾カンマがないことを保つ

**Patterns to follow:**
- 既存 env キーの追加例: `"CLV2_CONFIG": "{{ .chezmoi.homeDir }}/.claude/continuous-learning-config.json"` (line 9)

**Test scenarios:**
- Happy path: `chezmoi execute-template --config <test config> --source $(pwd) dot_claude/settings.json.tmpl` で期待通り JSON が生成され、`jq -r '.env.ECC_DISABLED_HOOKS'` の出力が `pre:bash:gateguard-fact-force,pre:edit-write:gateguard-fact-force` であること
- Edge case: 既存 env キーがすべてそのまま残っていること(`jq '.env | keys'` の差分は `ECC_DISABLED_HOOKS` の追加のみ)
- Integration: `chezmoi apply --dry-run` でテンプレート展開エラーが出ないこと、`make check-templates` がパスすること

**Verification:**
- `make oxfmt` (JSON フォーマット), `make check-templates`, `make lint` が通る
- `chezmoi apply` 後 `~/.claude/settings.json` の `.env.ECC_DISABLED_HOOKS` が想定値であること

---

- U2. **`dot_config/safehouse/config.tmpl` から `~/.gateguard` allowlist 行を削除**

**Goal:** safehouse サンドボックスの allowlist から `~/.gateguard` 行を撤去する。hook が動かないため不要。

**Requirements:** R2, R5

**Dependencies:** U1 (順序依存ではないが、論理的にまとめる)

**Files:**
- Modify: `dot_config/safehouse/config.tmpl`

**Approach:**
- `--- Working directories (read-write) ---` セクション内の `--add-dirs={{ .chezmoi.homeDir }}/.gateguard` 行のみを削除する
- セクション見出しコメントや前後の他エントリ(`.cache`, `.codex`, `.gstack`)はそのまま維持する
- gateguard 専用のコメント説明は元々付いていない(grep 確認済み)ため追加削除はなし

**Test scenarios:**
- Happy path: `chezmoi execute-template` で展開後、`grep gateguard` がヒットしないこと
- Edge case: 直前後の `.codex` / `.gstack` 行が削除されていないこと
- Integration: `chezmoi apply --dry-run` で safehouse 設定の差分が想定通りに表示されること

**Verification:**
- 新規 claude セッションを起動し `agent-safehouse` のログ・実行に gateguard 関連の deny ログが出ない、または出ても hook 自体が走らないため影響しないこと(目視確認)
- `make lint` が通ること

---

- U3. **`dot_config/cco/allow-paths.tmpl` から `~/.gateguard` allowlist 行を削除**

**Goal:** cco フォールバックサンドボックスの allowlist から `~/.gateguard` を撤去する。

**Requirements:** R2, R5

**Dependencies:** U1 (論理的グルーピング)

**Files:**
- Modify: `dot_config/cco/allow-paths.tmpl`

**Approach:**
- `# GateGuard fact-forcing hook session state (else hook blocks every Bash)` コメント行と直後の `{{ .chezmoi.homeDir }}/.gateguard` 行(2行ペア)を削除する
- 周辺の `# Playwright Chromium binary cache` 行や `# chezmoi config and source directory` 行など、他エントリはそのまま維持する

**Test scenarios:**
- Happy path: `chezmoi execute-template` 結果に `.gateguard` が含まれないこと
- Edge case: 直前の `# Playwright Chromium binary cache` 行と直後の `# chezmoi config and source directory` 行が無傷で残ること
- Integration: cco 経由で claude を起動するシナリオでサンドボックス起動が成功すること(可能ならテスト)。実機環境がない場合は `chezmoi apply --dry-run` での差分確認で代替

**Verification:**
- `make lint` が通ること
- `chezmoi managed | grep cco` の結果が変わらない(allow-paths.tmpl のソース管理状態は維持)

---

- U4. **`dot_gateguard/` placeholder ディレクトリを source ツリーから削除**

**Goal:** chezmoi が `~/.gateguard/` を deploy する起点になっていた `dot_gateguard/dot_keep` を撤去する。

**Requirements:** R2, R5

**Dependencies:** U2, U3 (sandbox 側で参照しなくなったあとに消す方が論理的に整合する。ただし `chezmoi apply` の順序依存ではないため commit を分けても合流させてもよい)

**Files:**
- Delete: `dot_gateguard/dot_keep`
- (delete 後の空ディレクトリ `dot_gateguard/` は git tracker から自動的に消える)

**Approach:**
- `git rm dot_gateguard/dot_keep` で削除する
- `chezmoi managed | grep gateguard` で `.gateguard` および `.gateguard/.keep` が管理対象から外れることを確認する
- 既存 deploy 済みディレクトリ `~/.gateguard/` は chezmoi `--remove` モードを使わない限り残るため、PR description で「必要に応じて手動で `rm -rf ~/.gateguard` してよい」と注釈する

**Test scenarios:**
- Happy path: `chezmoi managed | grep gateguard` の出力が空になる
- Edge case: `chezmoi apply --dry-run` で「`.gateguard/.keep` を削除」のような chezmoi 側挙動が無いこと(管理から外しても deploy 済みファイルは残るのが既定動作)
- Integration: `make check-templates` と `make lint` が通る

**Verification:**
- `chezmoi managed` の差分で `.gateguard*` が消えること
- `git status` で `dot_gateguard/dot_keep` の delete が登録されていること

---

- U5. **過去 solution doc に "現在は無効化済み" の注記を追加**

**Goal:** `gateguard-fact-force-sandbox-state-dir-2026-04-19.md` と `safehouse-add-dirs-requires-existing-path-2026-04-30.md` の冒頭に、issue #188 と本計画/PR で gateguard が無効化された旨の Update を加え、ドキュメントの真偽を現実に揃える。

**Requirements:** R3

**Dependencies:** U1〜U4(本体作業の決定事項を doc に反映するため)

**Files:**
- Modify: `docs/solutions/integration-issues/gateguard-fact-force-sandbox-state-dir-2026-04-19.md`
- Modify: `docs/solutions/integration-issues/safehouse-add-dirs-requires-existing-path-2026-04-30.md`

**Approach:**
- 既存の "Update (2026-04-30)" 注記スタイル(`safehouse-add-dirs-requires-existing-path-2026-04-30.md` 内に既存例あり)に合わせ、各 doc の上部 Summary/解決策セクション直前あたりに以下のような短い blockquote 注記を入れる:
  - "**Update (2026-04-30, supersedes this fix):** issue #188 を受けて gateguard hook 自体を `ECC_DISABLED_HOOKS` で無効化した。本ドキュメントの allowlist 追加 / placeholder 配置は新規セッションでは不要。再有効化する場合のみ参考にする。詳細は [plan](../../plans/2026-04-30-001-chore-disable-gateguard-skill-plan.md)。"
- 解決手順本体や考察は履歴として残すため削除しない
- PR 番号は実装段階で確定するため、plan へのリンクのみ確実に張り、PR 番号はマージ後に追記してもよい形にする

**Test scenarios:**
- Happy path: 両 doc の上部に Update note があり、リンクが本 plan ファイルを正しく指していること
- Edge case: 既存の "Update (2026-04-30)" note と重複しないこと(片方の doc は既に同日付の note があるため、新しい note には別の主題であることが分かる文を入れる)
- Integration: `make scan-sensitive` が通ること

**Verification:**
- `make lint` (sensitive scan 含む) が通る
- 両 doc を `cat` して目視で note が読みやすいこと

---

## System-Wide Impact

- **Interaction graph:** `everything-claude-code` プラグインの hook dispatcher (`bash-hook-dispatcher.js`, `hooks.json`)、`scripts/lib/hook-flags.js` `isHookEnabled()`、`agent-safehouse` Seatbelt プロファイル、`cco` allowlist、chezmoi の `dot_gateguard/` 管理。すべて連動して停止/撤去する
- **Error propagation:** 失敗時に最も心配なのは "settings.json テンプレート展開崩れで claude が起動しない"。U1 で `make check-templates` を必ず実行することで早期検知する。sandbox 側の allowlist 削除はセキュリティ的に厳しくなる方向の変更なので、誤って `--add-dirs` の他エントリを削ると claude が動かなくなる。差分レビューで担保
- **State lifecycle risks:** 既存 deploy 済みの `~/.gateguard/state-*.json` ファイルが残るが、hook が動かないため新規書き込みも参照もない。残しても害はないが、PR description で手動削除を推奨する
- **API surface parity:** 環境変数 `ECC_DISABLED_HOOKS` は `everything-claude-code` プラグインが消費する外部契約面。プラグインのバージョン更新でこの env var の semantics が変わるリスクは低いが、`scripts/lib/hook-flags.js` を 2.0.0-rc.1 で確認済み
- **Integration coverage:** ローカルで `chezmoi apply` → `claude` を再起動 → 任意の Bash/Edit を実行し、Fact-Forcing Gate がもう発火しないことを目視確認するシナリオは `ce-test-browser` ではカバーできないため、PR description のテスト計画として書く
- **Unchanged invariants:** 他の ECC hook(continuous-learning observer, learning briefing 等)、他のプラグイン全般、`safehouse` / `cco` の他 allowlist、`enabledPlugins` トグル、`dot_claude/settings.json.tmpl` 内の `permissions` / `hooks` ブロック、いずれも変更しない

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| `ECC_DISABLED_HOOKS` の hook ID を typo してしまい disable されない | プラグインソースから ID を直接コピーした上で `make check-templates` 後に新規 claude セッションで挙動確認する |
| 将来 ECC プラグイン更新で hook ID が改名される | プラグイン更新時に `scripts/lib/hook-flags.js` / `bash-hook-dispatcher.js` を再確認する手順を PR description に書く。本計画では現状の v2.0.0-rc.1 を前提とする |
| `dot_gateguard/dot_keep` 削除の git 操作で空ディレクトリが残り chezmoi の挙動が変わる | git は空ディレクトリを追跡しないため自動的に消える。`chezmoi managed` で確認する |
| sandbox allowlist 削除後に `~/.gateguard/` 残骸への read 試行で deny ログが出る | hook 自体が動かないので read 試行が起きない。残骸ファイルは PR description で手動削除を案内する |
| `make oxfmt` が JSON フォーマットを reformat してしまい diff が膨らむ | 事前に `pnpm exec oxfmt --write dot_claude/settings.json.tmpl` 等を流して整える(ただし .tmpl は対象外の可能性あり、その場合は手動で整える) |

---

## Documentation / Operational Notes

- PR description に以下を含める:
  - 変更概要(hook 無効化 + 関連対症療法撤去)
  - 動作確認手順: `chezmoi apply` → claude セッション再起動 → 任意の Bash/Edit が Fact-Forcing Gate に止められないことを確認
  - 任意手順: `rm -rf ~/.gateguard/` で残骸クリーンアップ
  - 再有効化手順: `settings.json.tmpl` から `ECC_DISABLED_HOOKS` を削除し、`safehouse` / `cco` allowlist と `dot_gateguard/dot_keep` を復元する(PR #186 / #187 を参照)

---

## Sources & References

- **Issue:** [tanimon/dotfiles#188](https://github.com/tanimon/dotfiles/issues/188)
- 関連 PR: #186 (safehouse allowlist 追加), #187 (`dot_gateguard/dot_keep` placeholder 追加)
- 関連 docs: `docs/solutions/integration-issues/gateguard-fact-force-sandbox-state-dir-2026-04-19.md`, `docs/solutions/integration-issues/safehouse-add-dirs-requires-existing-path-2026-04-30.md`
- プラグインソース: `~/.claude/plugins/cache/everything-claude-code/everything-claude-code/2.0.0-rc.1/scripts/lib/hook-flags.js`, `scripts/hooks/bash-hook-dispatcher.js`, `hooks/hooks.json`
