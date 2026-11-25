# Claude Code の Bash ツールでだけ、zsh を bash の書き方で書いたコマンドが通る側に寄せる。
# エージェントは bash の書き方でコマンドを書くが、Bash ツールはログインシェルの zsh で動く。次の 4 つは、
# bash なら通るコマンドを zsh が止めるか黙って壊す箇所なので、シェルの側で bash と同じ振る舞いにする。
#   no_equals      `=cmd` 展開を切る(`echo === x` が `== not found` で止まる)
#   ksh_arrays     波括弧の無い `$VAR:h` の修飾子を切り、配列の添字を 0 から にする
#   no_nomatch     一致しない glob をそのまま渡す(`--include=*.vue` や `?` を含む URL が `no matches found` で止まる)
#   sh_word_split  クォートしない `$VAR` を単語に分ける(`G="git -c x"; $G add` が `command not found` で止まる)
# Bash ツールは起動時のシェルスナップショットに setopt の状態を写して使うので、ここで立てた option が
# スナップショット経由で効く。人の対話シェル(CLAUDECODE が立たない)は zsh の既定のまま残す。
# ~/.zshrc の末尾で source する。ツールの初期化(mise・zoxide など)は zsh の既定の option で走らせるため。
# bash に切り替える(CLAUDE_CODE_SHELL)のではなく option で寄せているのは、PATH・mise・zoxide などの環境を
# 人の対話シェルと同じ ~/.zshrc から作るため。
if [[ -n "${CLAUDECODE:-}" ]]; then
    setopt no_equals ksh_arrays no_nomatch sh_word_split
fi
