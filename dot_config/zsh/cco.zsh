# Sandbox Claude Code via cco with --safe (hides $HOME, allowlist-based)
# Reads allow-paths from ~/.config/cco/allow-paths and passes as --add-dir
# Use `command claude` or `\claude` to bypass and run unsandboxed
claude() {
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
