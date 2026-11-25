# cursor-team-kit を Claude Code の plugin として入れる

## 目的

Cursor 向けに配布されている `cursor/plugins` の `cursor-team-kit`(CI・レビュー・PR 作成まわりの skill 18 本と agent 2 本)を、Claude Code から `cursor-team-kit:<skill>` の名前で使えるようにする。

## 前提

- `cursor/plugins` の Claude Code 用 marketplace(`.claude-plugin/marketplace.json`)に載っているのは `origin-apps` と `pstack` だけで、`cursor-team-kit` は無い。`cursor-team-kit@cursor-plugins` とは書けない。
- `cursor-team-kit` には `.claude-plugin/plugin.json` が無い。manifest は任意で、無くても `skills/` と `agents/` は読み込まれる。`claude plugin validate`(上流の `41e4009` で実行)は `✔ Validation passed` を返した。

## ゴール / 非ゴール

- ゴール: skill 18 本と agent 2 本をすべて有効にする。宣言は chezmoi 管理の `dot_claude/settings.json.tmpl` に置く。
- 非ゴール: `rules/*.mdc` の取り込み(Claude Code は `.mdc` を読まない)。agent の frontmatter の書き換え(`git-subdir` は上流のファイルをそのまま使うので、書き換えられない)。既存の skill と役割が重なるものの整理。

## 検討した方法

| 方法 | トレードオフ | 判断 |
|---|---|---|
| `extraKnownMarketplaces` に `"source": "settings"` のインライン marketplace を書き、plugin の取得元を `git-subdir` にする | 変えるファイルは settings.json.tmpl の1つだけ。marketplace 用のリポジトリやディレクトリが要らない | **採用** |
| dotfiles リポジトリの直下に `.claude-plugin/marketplace.json` を置き、`github: tanimon/dotfiles` で登録する | dotfiles リポジトリが丸ごと clone される。main にマージするまで反映されない | 不採用 |
| chezmoi で `~/` に marketplace ディレクトリを配置し、`directory` ソースで登録する | ファイルが2つになる。配置先がサンドボックスで書き込めるかも考える必要がある | 不採用 |

## 設計

- `extraKnownMarketplaces` に `dotfiles` を足す。`source` は `{"source": "settings", "name": "dotfiles", "plugins": [...]}` で、`name` はキーと一致させる。
  plugin のエントリは `{"name": "cursor-team-kit", "source": {"source": "git-subdir", "url": "cursor/plugins", "path": "cursor-team-kit"}}` とする。
  marketplace の名前を `dotfiles` にするのは、今後インラインで足す plugin も同じ marketplace に載せられるようにするため(実装者の判断)。
- `autoUpdate: true` を付け、版は固定しない(ユーザーの選択)。既存の `cursor-plugins` など他の marketplace と同じ運用になる。
- `enabledPlugins` に `"cursor-team-kit@dotfiles": true` を足す。
- テンプレートのコメントには、`cursor-plugins` marketplace に載っていないためインラインで登録していることを書く。

## 確認

- ブランチ上: `chezmoi execute-template` でテンプレートを描画し、JSON として読めることを確かめる。あわせて `just lint-fast` を通す。
- マージ後に `chezmoi apply` してから、`claude plugin list` で `cursor-team-kit@dotfiles` が enabled になっていることを確かめる。`/agents` を開き、`model: fast` の agent がどのモデルで動くかも確かめる。

## 残るリスク

- 上流は Cursor 向けのリポジトリなので、`cursor-team-kit` が改名・移動されると plugin が黙って読み込まれなくなる(Known Pitfalls の「Plugin marketplace renames silently break `enabledPlugins`」と同じ種類のリスク)。
- `workflow-from-chats` は Cursor のチャット履歴を読む前提なので、Claude Code では役に立たない。すべて入れるという決定に従い、そのまま入れる。
