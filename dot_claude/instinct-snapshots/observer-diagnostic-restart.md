---
id: observer-diagnostic-restart
trigger: when observer process appears stalled or analysis hangs
confidence: 0.7
domain: debugging
source: session-observation
scope: project
project_id: 23e6ae2f0a00
project_name: chezmoi
---

# Observer Process Diagnostic and Restart Cycle

## Action
When observer analysis reaches max-turns or hangs, kill the process and restart with `--reset`, then run analysis manually with `tail -n` observations to debug.

## Evidence
- Observed 4 times in session 6e0cc6bc-f31a-498c-b915-9db7e712e48c
- Pattern: Kill PID, remove `.observer.pid` and `.observer.lock` files, sleep 1s, restart with `--reset` flag
- Followed by manual invocation of `tail -n` on observations to isolate the analysis
- Last observed: 2026-04-04T14:33:07Z
