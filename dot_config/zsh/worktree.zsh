# Fuzzy-find and cd into a git worktree managed by gtr
gwt() {
  local dir
  dir=$(git gtr list --porcelain | fzf --delimiter='\t' --with-nth=2 --header 'Select worktree' | cut -f1) || return 0
  cd "$dir" || return 1
}
