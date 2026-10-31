---
date: 2026-10-23
trigger: "ルートの CLAUDE.md / AGENTS.md のサイズ上限に余白が無く(#544)、gitignore の切り替えを触るときにしか要らない詳細が全セッションに載っていた"
paths:
  - "dot_gitconfig.tmpl"
  - "dot_gitignore.tmpl"
  - "dot_gitignore_personal.tmpl"
  - ".chezmoitemplates/gitignore-common"
  - "dot_config/git/personal.inc"
---

**リポジトリの場所ベースの gitignore 切り替え(includeIf)** — superpowers 系と削除済みの ce 系のスキルが生成する Working Document(`docs/{brainstorms,ideation,plans,residual-review-findings,superpowers}/`)は、仕事リポジトリではノイズになるため除外する。個人リポジトリでは、ブランチ上で Requirements Document として持ち回るために commit し、マージ前に正本へ抽出して消す([ADR 0025](../../docs/adr/0025-working-documents-never-land-on-main.md))。これを git の `includeIf "gitdir:..."` で場所単位に切り替える: デフォルトの `~/.gitignore`(`dot_gitignore.tmpl`)はこれらを除外し、`dot_gitconfig.tmpl` の `includeIf`(`~/ghq/github.com/tanimon/` と `~/.local/share/chezmoi/`)が `~/.config/git/personal.inc` 経由で `core.excludesfile` を `~/.gitignore_personal`(`dot_gitignore_personal.tmpl`、これらを除外しない版)に差し替える。共通部分は `.chezmoitemplates/gitignore-common` に一本化し、両 `.tmpl` が `{{ template "gitignore-common" }}` で取り込む(対象ブロック以外の重複管理を避けるため)。フェイルセーフはデフォルト除外側: 未登録の場所(仕事の新リポジトリ・OSS クローン)では commit されず、個人リポジトリの登録漏れの損害は「commit されない」だけで軽微。`gitdir` は worktree でも本体の `.git` 配下を指すため、`~/orca/workspaces/` 等に切った worktree にも本体側のルールが自動で効く。新しい個人開発の場所を増やしたら `includeIf` セクションを追記する。仕事リポジトリへの commit-then-delete(レビュー前削除)方式は検討のうえ不採用: gitignore されたファイルもローカルには存在し続けるので開発中の参照に commit は不要で、削除後も push 済みブランチの中間コミットには残り、削除忘れガードを仕事リポジトリの CI/フックに置くこともできないため。個人リポジトリでは同じ方式を採る。削除忘れガードを CI に置け、中間コミットに残ることは spec を PR から辿れるという利点になるため(ADR 0025)。
