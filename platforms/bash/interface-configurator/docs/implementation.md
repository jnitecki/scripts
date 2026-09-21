# Implementation notes

Tracks how `interface-configurator.sh` is actually implemented, kept in
sync with the code. If a feature or its code is removed, remove its
section here too. This file covers only what's specific to this script;
the generic, cross-cutting conventions it implements live in
`docs/requirements/generic/` at the repo root (see `docs/CONTEXT.md`'s
"Per-script documentation" section for the split). Design rationale and
confirmed decisions live in
`docs/requirements/implemented/interface-configurator.md`; this file is
about the code, not the requirement.

## Self-upgrade

Requirement: `docs/requirements/generic/script-upgrade-convention.md`.
Blueprint followed: `tools/blueprints/bash.sh`. Identity:
`Upgrade-Source: github.com/jnitecki/scripts@bash/interface-configurator`.

- Copied near-verbatim from the bash blueprint, substituting only identity
  values (`SCRIPT_LANG`/`SCRIPT_NAME`/`UPGRADE_*`) and the applied-from
  environment guard variable names
  (`INTERFACE_CONFIGURATOR_UPGRADE_APPLIED_FROM`/`_MODE`).
- `upgrade_main` is called once, right after CLI argument parsing and the
  `--upgrade-check`/`--upgrade-only` early-exit branches, and after
  `require_platform`/`require_root` - but **only** for `--install`/
  `--uninstall`; `--run` skips the call site entirely (not merely passed
  `--no-autoupdate` - see "Where self-upgrade is skipped" below).

### Where self-upgrade is skipped

`--run <interface_name>` bypasses `upgrade_main` entirely - the call site
itself is skipped in the top-level flow, since `--run` is only ever
invoked by the generated systemd unit, which already bakes
`--no-autoupdate` into its own `ExecStart` (see "Shared systemd template
unit" below) as a second, redundant layer of protection.

## Bash 4.3+ requirement

Two features push the minimum interpreter version above the rest of this
repo's bash-3.2-safe baseline:
- `local -n` (namerefs, bash 4.3+) in `write_rule_config`, `cmd_install`,
  and `apply_now_for_pattern` - used to pass the caller's `ADD_COMMANDS`/
  `REMOVE_COMMANDS` arrays by reference rather than serializing them
  through a string.
- `coproc` (bash 4.0+) in `watch_iface` - runs `ip monitor` as a
  background coprocess with a known PID (`$NAME_PID`) and readable fd
  (`${NAME[0]}`), which a plain `cmd | while read; do ...; done` pipeline
  can't offer (no reliably portable way to get the piped command's PID
  back to kill it later).

This is an accepted, documented exception - see this script's own
requirements doc "Conflict with cross-platform-shell-compatibility"
section, and the general carve-out in
`docs/requirements/generic/cross-platform-shell-compatibility.md` section
0 for any script that inherently solves an OS-specific problem (this one
already requires systemd + udev, which have no macOS equivalent anyway;
requiring bash 4.3+ on top costs nothing further given the whole script
only runs on Linux, where bash 4+ is the norm).

**Implementation note - a real parser hazard found during development.**
`coproc NAME { cmd; }` (the brace-group form) is syntactically valid on
real bash 4+, but bash 3.2 (which doesn't recognize `coproc` as a keyword
at all) doesn't just fail to parse that one line - it appears to
misinterpret the nested `{ ... }` as closing the *enclosing function's*
own brace group early, corrupting how the rest of the file is parsed
entirely (up to and including code with no relation to `watch_iface`,
observed via `--help` itself breaking with an unrelated "unbound
variable" error deep inside `watch_iface`'s body). Since `watch_iface`
only ever needs to background a single simple command (`ip monitor ...`),
the fix was to drop the brace group entirely and use the plain
`coproc NAME simple-command` form instead - `coproc IC_MON ip monitor
link addr dev "$iface"`. This form fails cleanly and
locally on bash 3.2 (`coproc: command not found`, since 3.2 doesn't
recognize the keyword and tries to run it as a literal command) without
corrupting anything else, and it's simpler than the brace-group form
regardless of bash version. Kept as the reference form for any future
`coproc` usage in this script.

## Pattern slug

`slug_for_pattern()`: sanitizes the pattern (non-`[A-Za-z0-9_-]` ->
`_`), then appends `-` plus the first 8 hex characters of the pattern's
own SHA-1 (`hash_prefix8()`). Deterministic and reused as the filename
stem for both that pattern's `.conf` file and its udev rule file, so
`--uninstall <pattern>` can locate both without a lookup - it recomputes
the slug directly from the pattern argument.

## Storage: pattern -> add/remove command lists

`write_rule_config()` takes the pattern plus the *names* of two bash
arrays (not the arrays themselves - see the nameref note above) and
writes plain-text `KEY=value` lines: one `PATTERN=<pattern>`, then one
`ADD=<command>` per add command and one `REMOVE=<command>` per remove
command, in order - no index suffix or count line. The `REMOVE` key
deliberately matches the `--remove` CLI flag name, so the file reads
naturally against the command that produced it. Values are written
**unescaped** - `printf 'ADD=%s\n' "$cmd"`, not `%q` - since nothing
reads this file back as shell syntax (see next paragraph), there's
nothing that needs escaping.

`read_rule_config()` reads the file back line by line (clearing
`PATTERN`/`ADD_CMDS`/`REMOVE_CMDS` first, since the script runs under
`set -u`) rather than sourcing it - `while IFS='=' read -r key value`,
splitting each line only on its *first* `=` (`read` with more input
fields than target variables dumps everything past the last split point
into the final variable, `=` characters included, so a value containing
its own `=` round-trips intact), and appends to `ADD_CMDS`/`REMOVE_CMDS`
on every `ADD=`/`REMOVE=` line rather than counting up to a recorded
total - an unrecognized line (or one from an older/newer format) is
silently ignored rather than erroring. Not sourcing the file also means
it's always plain data, never executable code, regardless of what a
value contains.

The one string this format can't represent is one containing a literal
embedded newline (it would split across two lines and corrupt the
structure). Rather than let that silently corrupt a config file or be
silently misread back, `reject_newline()` checks `--install <pattern>`/
`--add <command>`/`--remove <command>` as they're parsed and exits 1 with
a clear error if any of them contains one - so a value reaching
`write_rule_config` is already guaranteed newline-free.

## Shared systemd template unit

`shared_unit_content()`/`ensure_shared_unit()`: content generated fresh
from a function, compared against whatever's on disk, replaced +
`daemon-reload`d only on an actual mismatch - safe to run on every
`--install`. `Type=simple` (not `oneshot` - see the requirements doc's
"Rejected alternatives" for why oneshot became actively unsafe once
`--run` became a persistent watcher) plus `BindsTo=`/`After=
sys-subsystem-net-devices-%i.device`, systemd's own device-unit binding,
so a real interface removal sends SIGTERM automatically - one of two
removal-detection mechanisms (see "Watch loop" below for the other).

`RESOLVED_SCRIPT_PATH` (via `readlink -f "$0"`, no BSD fallback needed -
Linux-only) is baked into the generated unit's `ExecStart` literally,
separate from `SCRIPT_PATH` (`"$0"` as invoked, used only by the
self-upgrade block's own filesystem-eligibility checks).

## Per-pattern udev rule

`udev_rule_content()`: `ACTION=="add"` only - the only event confirmed
reliable across interface types (including a real ZeroTier/TUN interface
during design work) - and this rule's only job is to start the watcher
once. Every later transition is the watcher's own responsibility (see
next section), not something further udev rules need to express.

## `--run`: startup, then the watch loop

`cmd_run()`: if nothing matches, exits immediately (`any_pattern_matches`,
no bash-4.3-only construct involved - safe even under an older bash, for
whatever that's worth given the platform gate already requires Linux).
Otherwise `wait_for_ready()` (unchanged from the original oneshot design -
checks `IFF_UP`+carrier, waits passively via `ip monitor link` with a
300s timeout if not already ready), then `run_matched(iface, "add")`, then
`watch_iface(iface)` - which never returns except via `exit 0` at its own
end.

`watch_iface()`:
- `trap 'terminate=1' TERM INT` - sets a flag the loop condition checks,
  rather than trying to interrupt work mid-command.
- `coproc IC_MON ip monitor link addr dev "$iface"` - backgrounds the
  monitor process; `${IC_MON[0]}` is its readable fd, `$IC_MON_PID` its
  PID (used to `kill`/`wait` it before the function returns). Its stderr
  is left attached to this process's own (the systemd journal) rather
  than discarded, so a real `ip monitor` failure is visible.
- **Coprocess death guard.** bash unsets both `IC_MON` (the array) and
  `IC_MON_PID` the instant the coprocess's process exits - found via a
  real production crash: the next `read -u "${IC_MON[0]}"` after that
  crashed with `IC_MON[0]: unbound variable` under this script's
  `set -u`, which systemd surfaced only as a fast `Restart=on-failure`
  loop hitting its burst limit, no indication of the real cause (worsened
  by the stderr-discarding above). The loop now checks `[ -n
  "${IC_MON_PID:-}" ]` before touching `${IC_MON[0]}`; if the coprocess is
  gone, it logs the failure and restarts the coprocess (bounded to 5
  attempts per `watch_iface` call - `mon_failures` - before giving up via
  `exit 1` and deferring to systemd's own restart policy) instead of
  reading from it.
- Loop condition: `[ "$terminate" -eq 0 ] && [ -e "${IC_SYS_CLASS_NET}/${iface}" ]`
  - the second removal-detection mechanism (direct existence check),
  complementing `BindsTo=`'s SIGTERM (belt-and-braces per confirmed
  decision #8 - either alone has a plausible gap: a missed/late uevent
  for `BindsTo`, a slow poll tick for this check).
- `read -t 1 -r -u "${IC_MON[0]}" line` each iteration (when the
  coprocess is alive) - a timeout, not a blocking read, so the loop
  condition (and thus the `terminate` flag and the existence check) gets
  re-evaluated roughly once a second regardless of whether `ip monitor`
  actually emitted anything. This is what makes the loop notice a stop
  signal or removal promptly without polling the interface's own state on
  a busy timer - the *state* checks (`iface_is_ready`, `get_addresses`)
  are still only as expensive as reading a couple of sysfs files and
  running `ip -o addr show`, not a network operation, so doing them every
  ~1s regardless of whether `ip monitor` produced a line is cheap.
- State transitions (ready/not-ready via `iface_is_ready`, address set
  via `get_addresses`, compared against the previous iteration's values)
  call `run_matched(iface, "add"|"remove")` - see "Rule freshness" below.
- On loop exit (removed or `terminate`): kills/waits the coprocess, then
  runs remove commands **only if `ready` was still true** at that point -
  an interface already down when the stop happens never gets remove
  commands run a second time (they already ran when it went down).

## Rule freshness

`run_matched(iface, kind)` always re-reads every `.conf` file under
`${IC_RULES_DIR}` fresh (same `read_rule_config` loop `any_pattern_matches`
and `cmd_run`'s startup matching use) rather than caching what matched at
`--run` startup. Two consequences, both intentional (confirmed decisions
#10/#11):
- An `--install`/`--uninstall` change to a pattern matching an
  already-watched interface takes effect on that interface's next
  transition, without needing to restart its watcher.
- `--uninstall` deletes a pattern's config file *before* stopping its
  watcher (`cmd_uninstall` -> `stop_watcher_if_unmatched`), so when the
  stopped watcher's own teardown re-reads fresh, it finds nothing for
  that pattern and runs zero remove commands - no special-casing needed
  to make "`--uninstall` never runs remove commands" true; it falls out
  of the ordering plus this shared re-read logic.

## Convenience variables for add/remove commands

`run_command_for_iface()` exports `IFACE` plus seven more variables to
every `--add`/`--remove` command - see README "Convenience variables" for
the user-facing table and the documented simple-case-only caveat.
`kind` ("add"|"remove", now a third parameter passed by every caller -
`run_matched()` and `apply_now_for_pattern()`) picks how they're sourced:

- `kind="add"`: `set_iface_address_vars(iface)` and
  `set_iface_gateway_vars(iface)` query `ip` live (the interface is
  known-ready at this point - "add" only ever runs once it is), then
  `write_iface_state(iface)` stashes the result.
- `kind="remove"`: `read_iface_state(iface)` reads that same stash back,
  rather than querying `ip` again - deliberately, not just an
  optimization: by the time a remove command runs, especially one
  triggered by the interface's own removal (see watch_iface's loop
  condition), the interface itself may already be gone, so a live query
  would come back empty. Reading the add-time stash instead means remove
  always sees the same values add did for that same lifecycle
  transition, not whatever's live at that moment on the rarer occasions
  the interface happens to still be present.

`set_iface_address_vars(iface)`: `IP4_ADDRESS`/`IP4_NETMASK`/
`IP4_PREFIX` from the first line of `ip -4 -o addr show dev <iface> scope
global` (empty if none), and `IP6_ADDRESS`/`IP6_PREFIX` the same way for
`-6`, no netmask - `IP4_NETMASK` is computed from `IP4_PREFIX` by
`ipv4_prefix_to_netmask()`, since `ip` itself only reports the prefix
length, not a dotted mask.

`set_iface_gateway_vars(iface)`: `IP4_GATEWAY`/`IP6_GATEWAY` from the
`via` field of `ip -4|-6 route show default dev <iface>` (empty if the
interface has no default route in that family).

`ipv4_prefix_to_netmask(prefix)`: `0.0.0.0`-`255.255.255.255` from bash
arithmetic alone (`(0xffffffff << (32 - prefix)) & 0xffffffff`, then
split into octets) - no external tool (e.g. `ipcalc`) needed. The `/0`
edge case works without special-casing: bash's arithmetic is 64-bit, so
shifting the 32-bit all-ones mask left by 32 pushes it entirely out of
the low 32 bits, and masking back down with `0xffffffff` correctly
yields `0`.

### State stash (`IC_STATE_DIR`, `/run/interface-configurator` by default)

One `<iface>.env` file per interface (not per pattern - the
address/gateway it holds is a property of the interface, shared by every
pattern watching it), holding the seven `IP4_*`/`IP6_*` variables as
`%q`-quoted `KEY=value` lines, sourced back directly (`. "$path"`) rather
than parsed:

- `iface_state_path(iface)`: `"${IC_STATE_DIR}/${iface}.env"`.
- `write_iface_state(iface)`: writes the current `IP4_*`/`IP6_*` globals
  (already set by the two live-query helpers above). Best-effort - if
  `IC_STATE_DIR` can't be created/written (e.g. `--run` invoked by hand
  as a non-root user for testing), logs a warning and returns 0 rather
  than failing the add command over it.
- `read_iface_state(iface)`: clears all seven variables first (empty
  string, never left unset - this script runs under `set -u`), then
  sources the state file only if it exists. A remove command for an
  interface that never got a successful add (so no stash was ever
  written) simply sees them all empty, the same as a live query that
  found nothing would have produced.
- `remove_iface_state(iface)`: deletes the state file. Called once from
  `watch_iface`'s own exit path (after its own final remove commands, if
  any), not from `run_command_for_iface`/`run_matched` - a stash outlives
  any single remove command, since only the watcher going away for good
  means this interface's stashed values are no longer relevant (a later
  reused interface name starts fresh, via its own next add).
- `/run` (tmpfs, cleared on reboot) is the correct home for this: stashed
  state from a previous boot is never valid for the current one.

Both live-query helpers set their variables as plain (non-`local`)
assignments so `run_command_for_iface`/`write_iface_state` can read them
back after calling them; every variable is always initialized (empty
string, not left unset) by whichever path populates them, so a lookup
that finds nothing never trips this script's `set -u`.

## `--install`'s apply-now step

`apply_now_for_pattern()` (array name passed by reference, same nameref
pattern as `write_rule_config`): for each already-present matching
interface, checks `systemctl is-active --quiet
interface-configurator@<iface>.service` first.
- **Active already** (a watcher is running, started by an earlier `add`
  uevent before this pattern existed) - applies this pattern's add
  commands directly, after the same `wait_for_ready` call `--run` itself
  uses. The running watcher won't otherwise notice a newly-registered
  pattern until its own next transition (per "Rule freshness" above), so
  this direct apply is what makes `--install` actually immediate.
- **Not active** - `systemctl start`s the watcher instead of applying
  directly, letting its normal startup sequence (`cmd_run`'s own
  wait-then-`run_matched add`) do the work. Applying directly here too
  would double-run this pattern's add commands once the freshly-started
  watcher also picks it up at its own startup.

## `--uninstall`

`cmd_uninstall()`: removes pattern config(s) first
(`remove_pattern`/`read_rule_config` loop, unchanged mechanism from the
original design), reloads udev rules if anything was actually removed,
then - only if something was removed - walks every currently-present
interface (`list_interfaces`) and calls `stop_watcher_if_unmatched`,
which stops that interface's unit only if `any_pattern_matches` now
returns false for it (an interface still matched by another registered
pattern is left running). Finally removes the shared unit +
`daemon-reload`s if no patterns remain registered at all (unchanged from
the original design).

## Platform gate

`require_platform()`: checks `systemctl`/`udevadm`/`ip` are all on
`PATH`, exits with a clear "not supported on this platform" error
otherwise. Called once, after CLI parsing determines which mode was
requested, before any of `--install`/`--uninstall`/`--run` does real
work - before `require_root` too, since there's no point checking
privilege on a platform that can't run this script at all.

## Testability (overridable paths)

Every real-filesystem/real-system touchpoint is overridable via an
environment variable, defaulted with `: "${VAR:=default}"`:
`IC_SYSTEMD_DIR`, `IC_UDEV_RULES_DIR`, `IC_RULES_DIR`, `IC_SYS_CLASS_NET`,
`IC_READY_TIMEOUT_SECONDS`. `test-interface-configurator.sh` uses this to
run against a scratch filesystem with stubbed `systemctl`/`udevadm`/`ip`/
`timeout`/`id` on `PATH`, without root and without a real systemd/udev
system.

**Bash-version-gated tests.** Since the script itself now requires bash
4.3+ (see above), any test exercising `write_rule_config`/`cmd_install`/
`apply_now_for_pattern` (namerefs) or `watch_iface` (`coproc`) can only
run correctly against a bash 4.3+ interpreter - resolved the same way the
shipped script resolves it, via `#!/usr/bin/env bash`. The test suite
detects the resolved bash's version once at startup (`HAVE_BASH43`) and
clearly **skips** (not silently passes, not falsely fails) every affected
test when it's false, printing the found version. This matters
concretely on macOS, whose system `bash` is still 3.2: the suite's
`--help`/argument-validation/root-check/platform-gate/`--run`-with-no-
match/`--run`-never-ready tests all still run for real there (none of
them reach a nameref or `coproc` codepath), while the install/uninstall/
watch-loop tests are skipped with an explanatory message rather than run
against the wrong interpreter.
