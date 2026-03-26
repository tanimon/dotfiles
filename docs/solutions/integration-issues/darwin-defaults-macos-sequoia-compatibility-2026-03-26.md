---
title: "Fix deprecated macOS defaults domains on Sequoia (15.x)"
problem_type: integration_issue
component: tooling
root_cause: config_error
resolution_type: config_change
severity: medium
tags:
  - defaults
  - macOS
  - chezmoi
  - Sequoia
  - ControlCenter
  - deprecation
created_date: 2026-03-26
status: resolved
---

# Fix deprecated macOS defaults domains on Sequoia (15.x)

## Problem

The `darwin/defaults.sh` script contained `defaults write` commands targeting deprecated preference domains that no longer work on macOS 15 (Sequoia), causing silent no-ops and incorrect system configuration.

## Symptoms

- `defaults read com.apple.dock` → "Domain com.apple.dock does not exist" (user-level plist absent on macOS 15)
- `defaults read com.apple.finder` → same domain-not-found error
- `defaults read com.apple.menuextra.battery ShowPercent` → "NOT SET"
- `defaults read com.apple.menuextra.clock DateFormat` → domain not found
- `killall "SystemUIServer"` silently fails (process no longer exists)
- Script aborts mid-execution when `set -euo pipefail` is combined with `killall` (exit code 1 when process not found)

## What Didn't Work

- **Reading individual domain keys** — Many domains (`com.apple.dock`, `com.apple.finder`) don't exist as user-level plists on macOS 15 at all, even though `defaults write` would create them
- **Searching for `activateSettings`** — The `/usr/libexec/activateSettings -u` utility (needed to apply symbolic hotkey changes without logout) does not exist on macOS 15
- **Using `defaults read` for clock settings** — No `com.apple.menuextra.clock` domain exists on macOS 15, and no equivalent key exists in `com.apple.controlcenter` or global defaults

## Solution

### Removed deprecated settings

| Setting | Reason |
|---------|--------|
| `com.apple.finder _FXShowPosixPathInTitle` | Removed in macOS 13+. `ShowPathbar` (already in script) provides path visibility |
| `com.apple.menuextra.clock DateFormat` | No `defaults` equivalent on macOS 15. Must use System Settings > Control Center > Clock |

### Migrated battery percentage

```bash
# Before (macOS 11 and earlier)
defaults write com.apple.menuextra.battery ShowPercent -string "YES"

# After (macOS 12+)
defaults -currentHost write com.apple.controlcenter BatteryShowPercentage -bool true
```

Key: the `-currentHost` flag is required — it writes to `~/Library/Preferences/ByHost/`, which is where macOS 12+ stores per-host Control Center settings.

### Updated killall target

```bash
# Before (macOS 10.x)
killall "SystemUIServer"

# After (macOS 11+)
killall "ControlCenter"
```

### Fixed set -e + killall interaction

```bash
# Before: aborts script if process not running
killall "${app}" &>/dev/null

# After: continues even if process not found
killall "${app}" &>/dev/null || true
```

`killall` returns exit code 1 when no matching process is found. `&>/dev/null` suppresses output but does NOT suppress the exit code. Under `set -e`, this causes script termination.

## Why This Works

1. **Battery percentage** moved from per-menu-extra preferences to unified ControlCenter settings in macOS 12 (Monterey). The `-currentHost` variant writes to the ByHost plist, which is how macOS stores per-host menu bar configurations.

2. **Clock format** moved entirely to System Settings UI in macOS 13+ with no command-line equivalent. Apple removed the `DateFormat` key processing from ControlCenter.

3. **SystemUIServer → ControlCenter** rename happened in macOS 11 (Big Sur) as part of the menu bar architecture overhaul.

4. **`_FXShowPosixPathInTitle`** was a Finder title bar feature that was removed when Finder adopted the tab-based window chrome. `ShowPathbar` provides equivalent path visibility in the window footer.

## macOS defaults domain migration reference

| macOS Version | Change |
|---------------|--------|
| 11 (Big Sur) | `SystemUIServer` → `ControlCenter` for menu bar items |
| 12 (Monterey) | `menuextra.battery ShowPercent` → `controlcenter BatteryShowPercentage` (requires `-currentHost`) |
| 13 (Ventura) | `_FXShowPosixPathInTitle` removed; `menuextra.clock DateFormat` deprecated |
| 15 (Sequoia) | Many Dock/Finder domains absent from user-level plists (System Settings manages internally) |

## Prevention

1. **Always verify `defaults read` on target macOS version** before adding `defaults write` to scripts:
   ```bash
   defaults read <domain> <key> 2>/dev/null || echo "Key not available"
   ```

2. **Use `|| true` on `killall`/`pkill`** in any script with `set -e`:
   ```bash
   killall "ProcessName" &>/dev/null || true
   ```

3. **Check macOS version for conditional settings** when supporting multiple versions:
   ```bash
   macos_major=$(sw_vers -productVersion | cut -d. -f1)
   if [[ "$macos_major" -ge 12 ]]; then
     defaults -currentHost write com.apple.controlcenter BatteryShowPercentage -bool true
   fi
   ```

4. **Periodically audit defaults scripts** against current macOS — Apple reorganizes preference domains with every major release without formal deprecation notices.
