# Changelog — interface-configurator.sh

Complete version history for `interface-configurator.sh`, newest entry
first — every version bump gets its own entry here, pre-releases included.
The script's own header keeps a much shorter, **stable-versions-only**
window (3 entries, most recent in full): a pre-release bump never gets its
own header line — every pre-release since the last stable release is
folded into one running "in progress" entry there instead. See
[docs/requirements/generic/script-maintenance-convention.md](../../../docs/requirements/generic/script-maintenance-convention.md)
section 3 for the exact rule.

## 0.0.1-dev8
Fixes a third real production bug in the same `watch_iface` coprocess,
unrelated to `0.0.1-dev2`/`0.0.1-dev6`'s fixes: `coproc IC_MON ip monitor
link addr dev "$iface"` (an explicit NAME followed by a plain external
command) turns out to never work correctly on real bash at all -
confirmed by building bash 5.1.16 (the exact version reported from a
live host still hitting this) from source and reproducing directly. It
never populates `IC_MON`/`IC_MON_PID`, prints a spurious `IC_MON: command
not found`, and the coprocess is effectively untracked the instant it
starts - on the affected host this happened on every single attempt (not
the timing-dependent race `0.0.1-dev2`/`0.0.1-dev6` were fixing), so
`watch_iface` always fell into the "coprocess exited unexpectedly" retry
path, exhausted all 5 attempts, and exited 1 every time, forever
crash-looping under systemd's `Restart=on-failure`. Fixed by dropping the
explicit NAME and using bash's own default coprocess name instead -
`coproc ip monitor ...` / `$COPROC_PID` / `${COPROC[0]}` - confirmed
correct on real bash (PID stays valid for as long as the process runs,
restarting it later also works) and still failing cleanly and locally on
bash 3.2 (`coproc: command not found` at that one line only, `bash -n`
raises no error for the rest of the file - unlike the compound-command
forms, which were tried and rejected: both `coproc NAME { cmd; }` and
`coproc NAME ( cmd )` cause `bash -n` to fail on bash 3.2 for the *whole
file*, the same file-wide corruption `0.0.1-dev1` already ruled out the
brace-group form for). Running the test suite directly against a real
bash 4.3+ interpreter (rather than only macOS's bash 3.2, which skips
every `coproc`-touching test) surfaced two further watch-loop tests that
were already silently broken by this same bug before this fix, entirely
unrelated to whatever specific test was being added at the time.

## 0.0.1-dev7
Fixes a production crash-loop caused by a *previous* `--install` run,
unrelated to `0.0.1-dev6`'s fix: `upgrade_main`'s self-upgrade trial run
(`replacement`/`overwrite`/`memory` modes) hands off to a candidate
process whose own `$0` is a transient path (a `mktemp
"${script_path}.XXXXXX"` sibling, a scratch file, or the upgrade cache),
not this script's real, enduring location. Since `--install`/
`--uninstall` are the only call sites that ever run `upgrade_main`, a
trial run that happens to itself be an `--install` had its own
`ensure_shared_unit` bake *that transient path* into the generated
systemd unit's `ExecStart` - a path that's renamed/deleted moments later
once the trial succeeds and the real replacement is persisted. The unit
was then left permanently pointing at a filename that no longer exists,
surfacing later as systemd's `Failed to locate executable ...: No such
file or directory` (status 203/EXEC) on every subsequent interface event,
with no relation to anything `--run` itself does - the corruption already
happened at `--install` time. Fixed by having `upgrade_main` pass its own
already-correct `RESOLVED_SCRIPT_PATH` through to each trial-run
candidate (`INTERFACE_CONFIGURATOR_UPGRADE_TRIAL_SCRIPT_PATH`, the same
handoff idiom as `_APPLIED_FROM`/`_APPLIED_MODE`) instead of letting it
recompute a wrong one from its own transient `$0` - except for `link`
mode, where that transient path genuinely is the enduring one. This only
prevents *future* corruption; a host already hit by this needs one more
`--install` run (any pattern) once the fixed script is in place, to let
`ensure_shared_unit`'s existing content-drift check rewrite the unit with
the correct `ExecStart`.

## 0.0.1-dev6
The `0.0.1-dev2` coprocess-death guard only covered the watch loop's own
`read -u "${IC_MON[0]}"` - it missed two other unguarded references to
`$IC_MON_PID` that run *before* the loop ever gets a chance to catch a
dead coprocess: the `log` line right after starting it, and the `log`
line right after restarting it inside the retry branch. If `ip monitor`
exits before either of those lines runs, bash unsets `IC_MON`/
`IC_MON_PID` first, and the same `unbound variable` crash under `set -u`
happens again - a real production recurrence of the exact bug
`0.0.1-dev2` was meant to fix, just one statement earlier. Both lines now
read `${IC_MON_PID:-unknown}`, matching the guard already used at every
other reference to this variable, so a coprocess that dies immediately
(even before its own startup is logged) is caught by the existing
bounded-retry-then-give-up logic instead of crashing the watcher outright.

## 0.0.1-dev5
The per-pattern rule config file (`${IC_RULES_DIR}/<slug>.conf`,
`/etc/interface-configurator/rules.d/` by default) is now a plain-text
`KEY=value` format instead of a `%q`-escaped file sourced as bash:
`PATTERN=<pattern>` once, then one `ADD=<command>` line per add command
and one `REMOVE=<command>` line per remove command (in order, unescaped)
- no more `ADD_<n>`/`REMOVE_<n>`/`ADD_COUNT`/`REMOVE_COUNT` bookkeeping;
`read_rule_config` now collects every `ADD=`/`REMOVE=` line it finds, in
file order, instead of counting up to a recorded total (the key stays
`REMOVE`, matching the `--remove` CLI flag, so the file reads naturally
against the command that produced it). The file is also no
longer sourced as bash at all - `read_rule_config` parses it by splitting
each line on its first `=` (`IFS='=' read`), so it's always plain data,
never executable code, and no value needs escaping since nothing in it is
ever evaluated as shell syntax. The one thing this format can't represent
is a literal newline embedded in a value (it would split across lines) -
`--install <pattern>`/`--add <command>`/`--remove <command>` now reject
that upfront (`reject_newline`) with a clear error, so it can never reach
the file.

## 0.0.1-dev4
The `IP4_*`/`IP6_*` convenience variables added in 0.0.1-dev3 are now
stashed to `IC_STATE_DIR` (`/run/interface-configurator/<iface>.env` by
default) whenever an add command runs, and a remove command reads that
stash back instead of re-querying `ip` live - previously, a remove
command triggered by the interface's own removal always saw them empty,
since the interface (and whatever address/gateway it had) was already
gone by the time `ip` was asked. This also makes add and remove see
consistent values for a given lifecycle transition, rather than remove
picking up whatever happens to be live at that moment (e.g. a
since-renewed DHCP lease) on the rarer occasions the interface is still
present when remove runs. Stashing/reading is best-effort (a warning, not
a fatal error, if `IC_STATE_DIR` isn't writable) and the stash is deleted
once `watch_iface` is done with that interface for good.

## 0.0.1-dev3
`--add`/`--remove` commands now get seven more variables exported
alongside `IFACE`, queried fresh at the moment each command runs:
`IP4_ADDRESS`/`IP4_NETMASK`/`IP4_PREFIX` and `IP6_ADDRESS`/`IP6_PREFIX`
(the interface's first global-scope address in each family, empty if it
has none - IPv6 gets no netmask variable, since IPv6 addresses aren't
conventionally expressed that way), and `IP4_GATEWAY`/`IP6_GATEWAY` (the
gateway of the interface's own default route in each family, independent
per family, empty if it has none). These are explicitly documented as
simple-case shortcuts only: an interface with more than one address in a
family only ever gets the first; anything beyond that (or a remove
command needing an address/gateway that's already gone by the time it
runs - e.g. on interface removal) needs its own `ip` query, or must be
captured by the paired add command itself.

## 0.0.1-dev2
Fixes a production crash-loop: `watch_iface`'s `ip monitor` coprocess
(`IC_MON`) is unset by bash the instant its process exits, so if that
process ever exited unexpectedly, the very next `read -u "${IC_MON[0]}"`
crashed with `IC_MON[0]: unbound variable` under this script's `set -u` -
systemd's `Restart=on-failure` then hit its burst limit ("Start request
repeated too quickly") within seconds, with no indication in the journal
of what actually failed, since the coprocess's own stderr was separately
being discarded (`2>/dev/null` on both `ip monitor` call sites). Now:
`watch_iface` checks whether the coprocess is still alive before reading
from it, and if not, logs it clearly and restarts it (up to 5 times
before giving up and letting systemd's own restart policy take over)
instead of crashing on the unbound variable; the coprocess's stderr, and
`wait_for_ready`'s separate `ip monitor` call, are no longer discarded, so
a real `ip monitor` failure is now visible in the journal instead of
vanishing silently.

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
