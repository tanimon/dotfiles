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
  local dir_path
  if [[ -f "$config" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" || "$line" == \#* ]] && continue
      # Skip --add-dirs / --add-dirs-ro entries whose path does not exist
      if [[ "$line" == --add-dirs=* || "$line" == --add-dirs-ro=* ]]; then
        dir_path="${line#*=}"
        [[ ! -e "$dir_path" ]] && continue
      fi
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

# Bypass codex's internal Seatbelt sandbox when already inside an external sandbox.
# macOS denies nested sandbox_apply syscalls — same root cause as the Claude Code
# internal sandbox conflict. The outer sandbox (safehouse/cco) already provides isolation.
# Use `command codex` or `\codex` to bypass this wrapper.
codex() {
  if [[ -n "$APP_SANDBOX_CONTAINER_ID" ]]; then
    command codex --dangerously-bypass-approvals-and-sandbox "$@"
  else
    command codex "$@"
  fi
}
