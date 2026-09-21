# Requirement: interface-configurator — Watch a Network Interface's Lifecycle and Run Registered Commands

## Scope
Script `platforms/bash/interface-configurator/interface-configurator.sh`.
Builds on [[script-header-convention]],
[[script-versioning-changelog-help-convention]],
[[script-upgrade-convention]] (self-upgrade), and
[[script-maintenance-convention]]. `Category: networking`.

Linux-only by necessity (systemd + udev) — see "Conflict with
cross-platform-shell-compatibility" below.

## Summary
Lets an operator register **add** and **remove** shell commands to run
automatically as a network interface whose name matches a glob pattern
moves through its lifecycle — via udev hotplug, or already present at
install time:

- becomes ready (administratively up, carrier present) → add commands
- goes down (still present) → remove commands
- becomes ready again → add commands, again
- an address changes while ready → remove then add (full reapply)
- is removed entirely → remove commands, then the watcher exits

A single generated systemd service **instance per currently-present
matching interface** does this watching, for as long as that interface
exists — not a run-once task. Registration itself (which patterns exist,
and their commands) is backed by a generated udev rule plus a shared
systemd template service, so it survives reboots without this script
needing to run persistently in the background itself.

## Requirement

### 1. CLI surface
Three modes, mutually exclusive:

| Mode | Usage | Who invokes it |
| --- | --- | --- |
| Install | `interface-configurator --install <interface_pattern> --add '<cmd>' [--add '<cmd>'...] [--remove '<cmd>' [--remove '<cmd>'...]]` | Operator, interactively |
| Uninstall | `interface-configurator --uninstall [<interface_pattern>]` | Operator, interactively |
| Run (internal) | `interface-configurator --run <interface_name>` | The generated systemd service only — not intended for direct interactive use, but not hidden/secret either |

`<interface_pattern>` uses shell glob syntax (`*`, `?`, `[...]`) — the same
syntax udev's own `KERNEL==` match already expects, and the same syntax
bash's `[[ $name == $pattern ]]` uses, so one pattern string works
unmodified in both places with no translation step.

**Command model** (confirmed: [[Command types]]): exactly two primitive
command types, **add** and **remove** — every other lifecycle event is a
combination of the two (down = remove; up-again = add; address-change =
remove-then-add). Multiple commands of each type can be registered per
pattern (confirmed: [[Multiple commands]]), each a single shell command
string, e.g.:
```
interface-configurator --install 'eth*' \
  --add 'ip route replace 10.0.0.0/24 via 10.0.0.1 dev "$IFACE"' \
  --remove 'ip route del 10.0.0.0/24 dev "$IFACE"'
```

### 2. `--install`
1. **Root required.** Writes to `/etc/systemd/system/`,
   `/etc/udev/rules.d/`, and `/etc/interface-configurator/rules.d/`, and runs
   `systemctl daemon-reload` / `udevadm control --reload-rules`. Check
   `EUID -eq 0` up front; fail fast with a clear error otherwise (no partial
   writes).
2. **Standard self-upgrade flow applies first** — same as any other
   invocation of this script, per [[script-upgrade-convention]].
   `--install`/`--uninstall` are ordinary operator-facing invocations, not
   the udev-triggered path that opts out (see mode 3, `--run`).
3. **Upsert semantics.** If `<interface_pattern>` is already registered,
   this replaces its whole stored add/remove command list (not an error,
   not a duplicate entry).
4. Persist the pattern → add/remove command lists (storage format: section 4).
5. **Multiple concurrent patterns are supported** — installing `'eth*'` and
   `'wlan*'` with different commands keeps both active simultaneously, each
   independently uninstallable.
6. Ensure the shared systemd template unit
   `/etc/systemd/system/interface-configurator@.service` exists **and its
   on-disk content matches what this script version would generate**;
   create it on first `--install` ever, and **replace it (followed by
   `systemctl daemon-reload`) whenever the two differ** — e.g. after a
   self-upgrade to a version whose generated template content changed
   (section 5). `daemon-reload` alone does not stop, restart, or otherwise
   affect any already-running `interface-configurator@<iface>` instance —
   it only refreshes systemd's unit definitions for *future* starts.
7. Write this pattern's own udev rule (section 6).
8. `udevadm control --reload-rules` so the new rule is live for the *next*
   interface add event.
9. **Apply immediately to already-present matching interfaces** (confirmed:
   [[Apply now?]]): enumerate current interfaces (`/sys/class/net/*`),
   glob-match each name against the new pattern, and for each match:
   - **if a watcher is already running** for that interface
     (`systemctl is-active interface-configurator@<iface>.service`), apply
     this pattern's add commands directly now, after the same readiness
     wait `--run` uses (section 7 step 3) — a running watcher only
     re-reads registered patterns on its own next transition (section 8),
     so a newly-registered pattern needs this direct apply to take effect
     immediately;
   - **otherwise, start the watcher instead**
     (`systemctl start interface-configurator@<iface>.service`) and let
     its own normal startup sequence (wait, then apply every matching
     pattern's add commands — section 7) do the work, rather than applying
     directly and risking a double-run once that fresh watcher also picks
     the pattern up.

   A failure here is reported but does not abort the rest of `--install`
   (the registration itself has already succeeded).

### 3. `--uninstall [<interface_pattern>]`
1. Root required, standard self-upgrade flow first — same as `--install`.
2. **With a pattern argument:** remove that pattern's stored mapping
   (section 4) and its udev rule (section 6) only.
3. **With no argument:** remove every registered pattern's mapping and
   udev rule.
4. `udevadm control --reload-rules` after any removal actually happened.
5. **Stop watchers left unmatched** (confirmed: [[Uninstall + live watchers]]):
   for every currently-present interface, if no remaining registered
   pattern matches it any more, stop its watcher
   (`systemctl stop interface-configurator@<iface>.service`) — an
   interface still matched by another pattern keeps its watcher running
   untouched. **This never runs remove commands** — registration is
   deleted *before* the stop, so when the watcher's own teardown
   (section 8) re-reads matching patterns fresh, it finds none for that
   pattern and runs nothing for it; whatever that pattern's add commands
   already applied is left as-is. This is a natural consequence of
   "always re-read fresh," not special-cased logic (see section 8).
6. If, after removal, no patterns remain registered at all, also remove
   the shared `interface-configurator@.service` unit and run `systemctl
   daemon-reload`.
7. Uninstalling a pattern that isn't currently registered is not an error
   — logged as a no-op (`nothing to remove for '<pattern>'`) so the
   command stays idempotent/safe to re-run.

### 4. Storage: pattern → add/remove command lists
`/etc/interface-configurator/rules.d/<slug>.conf`, one file per registered
pattern, containing safely-quoted bash assignments (written with
`printf '%s=%q\n'`, sourced back with `.`/`source` rather than parsed by
hand): `PATTERN`, `ADD_COUNT` plus indexed `ADD_1`..`ADD_<n>`, and
`REMOVE_COUNT` plus indexed `REMOVE_1`..`REMOVE_<m>`:
```
PATTERN=eth\*
ADD_COUNT=1
ADD_1=ip\ route\ replace\ 10.0.0.0/24\ via\ 10.0.0.1\ dev\ \"\$IFACE\"
REMOVE_COUNT=1
REMOVE_1=ip\ route\ del\ 10.0.0.0/24\ dev\ \"\$IFACE\"
```

`<slug>` is derived from the pattern so it's a safe filename: non-
`[A-Za-z0-9_-]` characters replaced with `_`, then `-` plus the first 8 hex
characters of the pattern's SHA-1 appended, to keep distinct patterns that
sanitize to the same prefix (e.g. `eth*` vs `eth?`) from colliding. The
same slug is reused for that pattern's udev rule filename (section 6).

### 5. Shared systemd template unit
`/etc/systemd/system/interface-configurator@.service`, created once, generic
across every registered pattern:
```ini
[Unit]
Description=interface-configurator: watch %i for add/remove/update events
After=sys-subsystem-net-devices-%i.device
BindsTo=sys-subsystem-net-devices-%i.device

[Service]
Type=simple
Restart=on-failure
ExecStart=<absolute-path-to-this-script> --no-autoupdate --run %i
```
- **`Type=simple`** (confirmed — supersedes an earlier `Type=oneshot`
  design): the instance is a **long-running watcher**, not a run-once
  task — it watches its interface for its entire lifetime, only exiting
  on removal or an explicit stop. `Type=oneshot` was rejected once this
  became the design: systemd only considers a oneshot unit "active" once
  its process **exits**, so `TimeoutStartSec` (~90s by default) would
  kill a genuinely long-running oneshot process before it ever finished
  "starting." `Type=simple` marks the unit active immediately on
  successful fork/exec, with no such timeout applying afterward.
- **`After=`/`BindsTo=sys-subsystem-net-devices-%i.device`** (confirmed:
  [[Removal detection]]): systemd's own native "stop this unit when this
  device disappears" mechanism — systemd sends SIGTERM automatically when
  the interface's own device unit deactivates (real removal). This is one
  of **two** removal-detection mechanisms used together (the other is the
  watcher's own direct check inside its loop — section 8) — belt and
  braces, since either alone has a plausible gap (a missed/late uevent for
  `BindsTo`; a slow poll tick for the loop's own check).
- **`Restart=on-failure`**: unchanged semantics from the original design —
  restarts only a non-zero (crashing) exit; a clean `exit 0` (device
  removed, or a deliberate stop via `systemctl stop`/`BindsTo`/
  `--uninstall`) is never restarted, and neither is an explicit stop
  request regardless of exit code (systemd never treats a stop it was
  told to perform as a "failure" to recover from).
- **`--no-autoupdate`**: baked into `ExecStart` itself, unconditionally —
  a hotplug-triggered run is unattended and self-upgrading during
  interface bring-up is undesirable on its own merits.
- **`<absolute-path-to-this-script>`**: resolved from the running script's
  own path (`readlink -f "$0"` equivalent) at `--install` time and baked
  into the unit file literally, same as the original design.

### 6. Per-pattern udev rule
`/etc/udev/rules.d/99-interface-configurator-<slug>.rules`:
```
ACTION=="add", SUBSYSTEM=="net", KERNEL=="<pattern>", TAG+="systemd", ENV{SYSTEMD_WANTS}+="interface-configurator@%k.service"
```
`ACTION=="add"` only — confirmed during design work against a real
TUN-style interface: a `change` uevent is not reliably emitted at all for
some interface types (only `add` fired across multiple real hotplug/boot
observations), and `ATTR{operstate}` can stay stuck at `unknown`
indefinitely for interfaces that never implement carrier detection the
way `operstate`'s computation expects. This rule's **only** job is to
start the watcher once, the first time the interface appears — every
subsequent transition (up/down/address-change/removal) is handled by the
watcher itself (section 7/8), which can wait and react as long as needed
rather than depending on further uevents.

### 7. `--run <interface_name>` (internal) — startup
1. **Does not** go through the standard self-upgrade flow — the unit file
   already passed `--no-autoupdate` explicitly (section 5).
2. Source every file under `/etc/interface-configurator/rules.d/` and
   determine whether **any** stored `PATTERN` glob-matches
   `<interface_name>`. No match is not an error — logs `no rule matches
   '<interface_name>'` and exits `0` immediately, without waiting (a udev
   rule firing for an interface whose registration was since removed is
   an expected race, not a failure).
3. **Wait for the interface to actually be ready** before running
   anything — empirically, the `add` uevent (section 6) can fire before
   the interface is genuinely usable (a TUN-style interface can report
   `carrier` as already `1` at creation time while `IFF_UP` is still
   pending, and a command issued at that point can fail, e.g. `ip`'s
   "Nexthop device is not up"):
   - **Ready** means both `IFF_UP` (bit `0x1` of
     `/sys/class/net/<interface_name>/flags`) and carrier
     (`/sys/class/net/<interface_name>/carrier` == `1`).
   - Check current state first; if already ready, proceed immediately.
   - Otherwise wait **passively** (event-driven, no sleep/poll loop) by
     reading the output of `ip monitor link dev <interface_name>` and
     re-checking readiness each time a line is emitted, bounded by a fixed
     300-second (5 minute) timeout (no CLI flag).
   - On timeout without becoming ready, logs a clear message and exits
     non-zero — `Restart=on-failure` (section 5) then retries the whole
     invocation, so a slow-to-attach interface keeps getting retried.
4. Run every matching pattern's **add** commands (in slug-sort order),
   each with `IFACE=<interface_name>` exported and `<interface_name>` also
   passed as `$1`. A failing command is logged but does not stop the
   remaining ones, and does not stop `--run` from proceeding to step 8's
   watch loop.

### 8. `--run` — the watch loop (confirmed: [[Watch loop]])
Once startup (section 7) has applied the initial add commands, `--run`
**does not exit** — it keeps watching this one interface for as long as it
exists:
- Watches `ip monitor link addr dev <interface_name>` **passively**
  (event-driven; a `read -t 1` poll on the monitor stream bounds each loop
  iteration to ~1s so a stop signal is noticed promptly, not a busy
  sleep/poll loop reading the interface's state on a timer) for further
  transitions, and directly checks whether `/sys/class/net/<interface_name>`
  still exists each iteration (the second removal-detection mechanism —
  see section 5's `BindsTo=` note).
- **Rules are re-read fresh from storage on every transition**, never
  cached from startup (confirmed: [[Rule freshness]]) — an
  `--install`/`--uninstall` change to a pattern matching this interface
  takes effect on the interface's *next* transition without needing to
  restart the watcher.
- Transitions:
  - **still ready, address(es) changed** (any IPv4/IPv6 address added or
    removed — confirmed: [[Update trigger]]; route/gateway changes alone
    are not watched) → run every matching pattern's remove commands, then
    every matching pattern's add commands (full reapply).
  - **was ready, now not ready, interface still present** (i.e. went
    down) → run every matching pattern's remove commands.
  - **was not ready, now ready again** → run every matching pattern's add
    commands (same as startup's initial apply).
  - **interface removed, or this process asked to stop** (SIGTERM/SIGINT
    — from systemd's `BindsTo=` on real removal, from `systemctl stop`
    during `--uninstall`, or manually) → re-read matching patterns fresh
    and run their remove commands **only if currently applied** (i.e. the
    interface was ready at the moment of exit — an interface already down
    when the stop happens never gets its remove commands run a second
    time), then exit `0`. **Uninstalling never triggers this to run
    anything**, since `--uninstall` deletes the pattern's config before
    stopping the watcher (section 3 step 5) — the re-read at this exact
    point finds nothing.
- An individual add/remove command failing during the watch loop is
  logged but does not stop the watcher or change its eventual exit code —
  only real internal errors (the initial readiness wait timing out, in
  step 7 above) produce a non-zero exit.

## Conflict with cross-platform-shell-compatibility
[[cross-platform-shell-compatibility]] requires every bash script in this
repo to "run correctly on both Linux and macOS." This script fundamentally
cannot — udev and systemd don't exist on macOS. **Confirmed resolution**:
`interface-configurator.sh` checks for `systemctl`/`udevadm`/`ip` up front
and exits immediately with a clear "requires systemd + udev, not supported
on this platform" error on any system lacking them, rather than attempting
partial behavior. This also means this script isn't bound by that doc's
bash 3.2/BSD-coreutils portability rules — it requires **bash 4.3+**
specifically (namerefs in the config-writing/apply-now functions; `coproc`,
4.0+, in the watch loop), which the generic doc's carve-out (section 0,
added for this script) already accepts for any script that inherently
solves an OS-specific problem — see
`docs/requirements/generic/cross-platform-shell-compatibility.md`.

## Rejected alternatives
- **Single active configuration, replaced on every `--install`**: rejected
  — operators want independent rules for e.g. `eth*` vs `wlan*` at once.
- **External script path instead of an inline command string**: rejected —
  adds a second file to manage/deploy per pattern for no benefit over a
  single quoted command line, which already covers multi-step logic via
  `&&`/`;`.
- **`RUN+="systemctl start ..."` udev key**: rejected in favor of
  `TAG+="systemd"`/`ENV{SYSTEMD_WANTS}` (section 6) — the latter is
  systemd-udevd's documented integration point and avoids `RUN`'s known
  quoting/synchronous-execution pitfalls.
- **`Type=oneshot`, run-once-and-exit** (the original design): rejected
  once the requirement became "watch the interface's whole lifecycle, not
  just its first appearance" — see section 5's `Type=simple` note for why
  oneshot is actively unsafe for a long-running process (`TimeoutStartSec`).
- **A single command type instead of add/remove**: rejected — down,
  up-again, and address-change all need distinguishable behavior
  (typically "undo" vs. "(re)apply"), which two primitive types cover via
  combination (down = remove; update = remove+add) without needing a
  third "update" type of its own.
- **`--uninstall` running remove commands via the stop**: rejected — an
  operator uninstalling a rule is deregistering it, not asking for
  whatever it already applied to be undone; only future events (or an
  explicit remove command the operator runs themselves) touch already-
  applied state.
- **A `wait_for_ready`-style poll loop for the ongoing watch, instead of
  `ip monitor`**: rejected for the same reason the initial readiness wait
  already avoids polling — event-driven stays responsive without a tight
  sleep loop; the `read -t 1` bound exists only so a stop signal is
  noticed promptly, not as the loop's primary re-check mechanism.

## Confirmed decisions
1. **Script deployment path assumption** (section 5) — bake in the
   caller's own resolved path at `--install` time (no self-copy step).
2. **`ACTION=="add"` only** (section 6) — the only uevent confirmed
   reliable across interface types during design work.
3. **`--help` layering** per [[script-maintenance-convention]] section 2 —
   `--install`/`--uninstall`/`--run` all appear under core `--help`.
4. **Shared template content drift** (section 2 step 6) — `--install`
   checks the on-disk template's content against what this script version
   generates, and replaces + `daemon-reload`s on mismatch.
5. **Interface readiness wait** (section 7 step 3) — both `IFF_UP` and
   carrier, passively via `ip monitor link`, fixed 300s timeout, no CLI
   flag.
6. **Command types** (section 1) — exactly two primitives, add and
   remove; every other lifecycle event is a combination of the two.
7. **Multiple commands** (section 1) — any number of `--add`/`--remove`
   per pattern, upserted as a whole list on re-`--install`.
8. **Removal detection** (section 5) — both mechanisms: systemd's
   `BindsTo=` on the interface's device unit, *and* the watch loop's own
   direct existence check.
9. **Update trigger** (section 8) — any IPv4/IPv6 address change; route/
   gateway changes are not watched.
10. **Rule freshness** (section 8) — rules are re-read from storage on
    every transition, not cached from the watcher's own startup.
11. **Uninstall + live watchers** (section 3 step 5) — stops a watcher
    once nothing registered matches its interface any more, but never
    runs remove commands as part of that stop (config is deleted first).
12. **`Type=simple`, not `Type=oneshot`** (section 5) — required once
    `--run` became a persistent watcher rather than a run-once task, to
    avoid `TimeoutStartSec` killing a unit that never "finishes starting."

## Rationale
udev is the only reliable hook for "a network interface just appeared,"
and systemd is the natural place to hand off both *running* the initial
configuration and *supervising* the interface's watcher for its remaining
lifetime, rather than this script trying to daemonize itself globally or
run under cron polling for interface changes. Splitting "operator
registers a rule" (`--install`/`--uninstall`, interactive, self-upgrading
like any other script invocation) from "the rule's watcher runs"
(`--run`, unattended, self-upgrade deliberately disabled, one instance per
currently-present matching interface) keeps the two concerns' very
different trust/network/timing assumptions from leaking into each other.
Splitting registered behavior into **add** and **remove** primitives
(rather than a single command, or three-plus event-specific ones) gives
every other lifecycle transition a well-defined meaning by combination,
without asking an operator to reason about more than two verbs.
