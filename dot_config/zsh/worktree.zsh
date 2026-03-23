# Fuzzy-find and cd into a git worktree managed by gtr
gwt() {
  if ! command -v git &>/dev/null || ! git gtr version &>/dev/null 2>&1; then
    echo "gwt: git-gtr is required but not available" >&2
    return 1
  fi
  if ! command -v fzf &>/dev/null; then
    echo "gwt: fzf is required but not installed" >&2
    return 1
  fi

  local line
  line=$(git gtr list --porcelain | fzf --delimiter='\t' --with-nth=2 --header 'Select worktree') || return 0
  local dir
  dir=$(printf '%s' "$line" | cut -f1)

  if [[ -d "$dir" ]]; then
    cd "$dir" || return 1
  else
    echo "gwt: directory not found: $dir" >&2
    return 1
  fi
}
