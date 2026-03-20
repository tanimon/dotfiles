# Sandbox Claude Code via safehouse (deny-all default) or cco (fallback)
# Reads config from ~/.config/safehouse/config or ~/.config/cco/allow-paths
# Use `command claude` or `\claude` to bypass and run unsandboxed
claude() {
  if command -v safehouse &>/dev/null; then
    _claude_safehouse "$@"
  elif command -v cco &>/dev/null; then
    _claude_cco "$@"
  else
    command claude "$@"
  fi
}

_claude_safehouse() {
  local -a args=()
  local config="${XDG_CONFIG_HOME:-$HOME/.config}/safehouse/config"
  if [[ -f "$config" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" || "$line" == \#* ]] && continue
      args+=("$line")
    done < "$config"
  fi
  command safehouse "${args[@]}" -- claude --dangerously-skip-permissions "$@"
}

_claude_cco() {
  local -a cco_args=(--safe)
  local config="${XDG_CONFIG_HOME:-$HOME/.config}/cco/allow-paths"
  if [[ -f "$config" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" || "$line" == \#* ]] && continue
      cco_args+=(--add-dir "$line")
    done < "$config"
  fi
  command cco "${cco_args[@]}" "$@"
}
