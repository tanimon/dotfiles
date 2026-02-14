# PATH settings
typeset -U path  # Remove duplicates

path=(
  $HOME/.local/bin
  $HOME/bin
  $path
)

export PATH
