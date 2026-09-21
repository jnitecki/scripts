# Changelog — interface-configurator.sh

Complete version history for `interface-configurator.sh`, newest entry
first — every version bump gets its own entry here, pre-releases included.
The script's own header keeps a much shorter, **stable-versions-only**
window (3 entries, most recent in full): a pre-release bump never gets its
own header line — every pre-release since the last stable release is
folded into one running "in progress" entry there instead. See
[docs/requirements/generic/script-maintenance-convention.md](../../../docs/requirements/generic/script-maintenance-convention.md)
section 3 for the exact rule.

## 0.0.1-dev1
Initial implementation, per the [[script-maintenance-convention]] section 4
bootstrap rule (no prior `Version:` header = implicit `0.0.0`, so the first
real version is `0.0.1-dev1`, not a stable release) — not yet promoted to a
stable version. Registers **add**/**remove** command pairs per glob
pattern; a single systemd service instance per currently-present matching
interface (`interface-configurator@<iface>.service`, `Type=simple`,
`Restart=on-failure`, `BindsTo=`/`After=` that interface's own device
unit) watches it for its entire lifetime — applying add commands when it
becomes ready, remove commands when it goes down, add again when it comes
back up, remove-then-add on an address change, and remove-then-exit on
removal. Started by a per-pattern udev rule matching `ACTION=="add"` only
(the only event confirmed to reliably fire across interface types during
design work, including a real ZeroTier/TUN interface); every subsequent
transition is handled by the watcher itself via a passive `ip monitor`
loop, not further udev events. `--install` applies immediately to any
already-present matching interface (starting a fresh watcher, or applying
directly if one is already running, to avoid double-applying), and keeps
the shared unit's on-disk content in sync with what the running script
version would generate. `--uninstall` stops watchers left unmatched by any
remaining pattern, without ever running their remove commands. Requires
bash 4.3+ (namerefs, `coproc`). Self-upgrade per
`docs/requirements/generic/script-upgrade-convention.md`.
