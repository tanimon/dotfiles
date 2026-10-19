# Sandbox Claude Code via nono (kernel-enforced Seatbelt/Landlock, deny-all default).
# Policy lives in ~/.config/nono/profiles/claude-seal.json (chezmoi-managed).
#
# nono は試用中なので、明示したときだけ使う。素の `claude` は wrapper を通らずに
# 実行ファイルを起動し、Claude Code 自身の Bash サンドボックス(~/.claude/settings.json
# の sandbox ブロック)が境界になる。nono の内側で動かすときは `claude-nono` で起動する。
#
# --allow-cwd is required: workdir.access in the profile sets the access *level*,
# not the grant itself. Without it the working directory is not shared and nono
# falls back to an interactive prompt no non-interactive run can answer.
#
# --settings disables Claude Code's own Bash sandbox for this invocation only, so
# nono is the single boundary. This is load-bearing, not a nicety: nested Seatbelt
# does not degrade gracefully — every Bash tool call dies with
# `Exit code 71 / sandbox-exec: sandbox_apply: Operation not permitted`.
# 同じ理由で、claude-nono のセッションの内側(INSIDE_NONO_SANDBOX あり)から素の `claude`
# を起動すると Bash ツールが 71 で落ちる。内側から起動するときもこの --settings を付ける。
#
# nono が無いときは素の claude に落とさずに失敗する。nono を明示して呼んだのに
# 境界の違う経路で動くと、nono の内側にいると誤解したまま作業することになるため。
claude-nono() {
  if ! command -v nono &>/dev/null; then
    print -u2 'claude-nono: nono が見つからない。素の claude はそのまま `claude` で起動する'
    return 1
  fi
  command nono run --profile claude-seal --allow-cwd -- \
    claude --settings '{"sandbox":{"enabled":false}}' \
    --dangerously-skip-permissions "$@"
}

# Disable codex's own Seatbelt sandbox when already inside nono. macOS denies
# nested sandbox_apply, verified inside nono:
#   nono run --profile claude-seal --allow-cwd -- codex sandbox -- /bin/echo ok
#   -> sandbox-exec: sandbox_apply: Operation not permitted (exit 71)
# while the same command outside nono exits 0. That the flag *fixes* it is also
# demonstrated, not just inferred from the docs — a credit-free contrast pair:
#   nono run ... -- codex -c sandbox_mode=danger-full-access sandbox -- /bin/echo ok
#   -> ok
#   nono run ... -- codex sandbox -- /bin/echo ok
#   -> fails
# (-c sandbox_mode=... is the config-key form of the setting --sandbox sets; the
# wrapper uses --sandbox, the documented flag.) --sandbox danger-full-access drops
# only the nested sandbox; --ask-for-approval on-request keeps codex's approval
# flow (strictly safer than --dangerously-bypass-approvals-and-sandbox, which
# discards both). INSIDE_NONO_SANDBOX is injected by the claude-seal profile's
# environment.set_vars. Use `command codex` to bypass this wrapper.
codex() {
  if [[ -n "${INSIDE_NONO_SANDBOX:-}" ]]; then
    command codex --sandbox danger-full-access --ask-for-approval on-request "$@"
  else
    command codex "$@"
  fi
}
