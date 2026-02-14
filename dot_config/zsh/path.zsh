# PATH settings
typeset -U path PATH # Remove duplicates

path=(
  $HOME/.local/bin
  $HOME/bin
  $path
)

export PATH
