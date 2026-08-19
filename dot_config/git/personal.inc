# 個人リポジトリ向けの上書き設定。
# ~/.gitconfig の includeIf "gitdir:..." から読み込まれ、excludesfile を
# superpowers/ce 系スキル生成ドキュメント(docs/plans/ 等)を除外しない版に差し替える。
[core]
  excludesfile = ~/.gitignore_personal
