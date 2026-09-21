# interface-configurator

Registers **add** and **remove** shell commands to run automatically as a
network interface whose name matches a glob pattern moves through its
lifecycle — becomes ready, goes down, comes back up, has its address
change, or is removed entirely — whether it's already present when you
install the rule or appears later (a USB NIC plugged in, a VPN tunnel
interface created by another daemon, a renamed interface, a container/VM
NIC attaching). Registration survives reboots without this script needing
to run as a background daemon itself: it's backed by a generated `udev`
rule plus a shared `systemd` service, so a per-interface watcher instance
is started and supervised entirely by the OS for as long as that interface
exists.

## Motivation

A lot of interface-specific configuration — adding a route, setting DNS,
running a script that depends on a particular NIC being present — either
has to be baked into a network manager's own configuration format, hidden
inside a hand-rolled systemd unit, or run manually after the fact. That's
extra friction for anything outside the common cases a network manager
already handles well, and it gets worse for interfaces that appear
unpredictably (hotplugged hardware, VPN/tunnel interfaces brought up by a
separate client), or whose address changes over time (DHCP renewal,
reconnection) in ways that should re-trigger whatever depends on them.

interface-configurator exists to remove that friction for exactly this
one job: "as this interface's state changes, apply or undo this
configuration." It doesn't try to manage the interface itself (bringing
it up, assigning it an address); it reacts once something else already
has, for the interface's whole lifetime — not just once.

## Requirements

- Linux with `systemd`, `udev`, and `ip` (iproute2) — this script is
  Linux-only by design (there is no macOS equivalent) and exits
  immediately with a clear error on any other platform.
- **bash 4.3+** — the watcher relies on `coproc` (bash 4.0+) and namerefs
  (bash 4.3+). Virtually every current Linux distribution ships this by
  default; this is only worth noting because it's stricter than most
  scripts in this repository need.
- `curl` — only for the optional self-upgrade check; its absence just
  disables that check, the script still runs.

## Usage

```
sudo ./interface-configurator.sh --install <interface_pattern> \
    --add <command> [--add <command>...] \
    [--remove <command> [--remove <command>...]]
sudo ./interface-configurator.sh --uninstall [<interface_pattern>]
./interface-configurator.sh --run <interface_name>
```

`--install` and `--uninstall` require root (they write to
`/etc/systemd/system/`, `/etc/udev/rules.d/`, and
`/etc/interface-configurator/rules.d/`). `--run` is invoked internally by
the generated systemd service — documented here for transparency, but not
something you run by hand.

`<interface_pattern>` uses shell glob syntax (`*`, `?`, `[...]`) — the same
syntax both `udev` and this script's own matching already use, so one
pattern string works unmodified everywhere. Each `--add`/`--remove` is a
single shell command string, with the matched interface name available as
both `$IFACE` and `$1`:

```
sudo ./interface-configurator.sh --install 'eth*' \
  --add    'ip route replace 10.0.0.0/24 via 10.0.0.1 dev "$IFACE"' \
  --remove 'ip route del 10.0.0.0/24 dev "$IFACE"'
```

## How a rule behaves over an interface's lifetime

Once a pattern is registered, a single watcher instance is started for
each currently- or later-present matching interface, and stays running
for as long as that interface exists:

| Interface event | What runs |
| --- | --- |
| Becomes ready (up + carrier) | every registered **add** command |
| Goes down (still present) | every registered **remove** command |
| Becomes ready again | every registered **add** command, again |
| Its address changes while ready | every **remove** command, then every **add** command (full reapply) |
| Is removed entirely | every **remove** command, then the watcher exits |

"Ready" means administratively up *and* carrier present — not merely
present. Some interface types (e.g. a freshly created virtual/tunnel
interface) can report as present well before they're actually usable; the
watcher waits for genuine readiness before running anything, up to 5
minutes on first startup, so an add command like setting a route doesn't
run against an interface that isn't ready to accept it yet.

## Installing a rule

`--install <pattern> --add <cmd> [--add <cmd>...] [--remove <cmd> [--remove <cmd>...]]`
registers one or more add commands, and optionally one or more remove
commands, for every interface matching `<pattern>`. Installing a pattern
that's already registered replaces its **whole** add/remove list (not an
error, not a duplicate) — this is the way to change a rule later. Multiple
independent patterns can be registered at once (e.g. `'eth*'` and
`'wlan*'` with different commands), each uninstallable on its own.

Installing applies immediately to any already-present matching interface,
in addition to registering for future hotplug events — so you don't have
to unplug/replug or reboot to see it take effect on something already
present.

## Removing a rule

`--uninstall <pattern>` removes just that pattern. `--uninstall` with no
argument removes every registered pattern. Removing a pattern that isn't
currently registered is not an error — it's logged as a no-op, so it's
safe to re-run.

Uninstalling stops the watcher for any interface no longer matched by any
remaining pattern, but **never runs remove commands** as part of that —
whatever a pattern's add commands already applied (e.g. a route) is left
in place; uninstalling deregisters the rule, it doesn't undo its effects.
An interface still matched by another registered pattern keeps its
watcher running untouched.

## Self-upgrade

On every `--install`/`--uninstall` invocation (unless `--upgrade-type none`
/ `--no-autoupdate` is given), the script checks
`github.com/jnitecki/scripts` for a newer release of itself, at or above
its own release channel (`--upgrade-level` to widen or narrow that). If one
is found, it's downloaded and validated (syntax check, plus a best-effort
content-hash check against the value declared in its release tag), then
actually run to do this invocation's real work — only a successful run
gets kept, via whichever of `replacement`/`overwrite`/`link`/`memory` this
filesystem supports (see `--help upgrade` for the full option list, or
`container-upgrader`'s own README for a more detailed walkthrough of the
same shared mechanism). `--run` never self-upgrades — invocations from the
generated systemd unit always pass `--no-autoupdate`, since a
hotplug-triggered run is unattended and the network the upgrade itself
would need may not even be up yet.

Use `--upgrade-check` to see what would happen without changing anything,
or `--upgrade-only` to perform just the upgrade and exit.

## Output

Progress and errors are logged to stderr, one timestamped line each. `--run`
itself normally only exits once its interface is removed (or it's stopped
via `--uninstall`/`systemctl stop`); an individual add/remove command
failing while it's watching is logged but doesn't stop the watcher. Exit
code reflects whether the run completed cleanly: `0` if no errors
occurred, non-zero otherwise. A failed or skipped self-upgrade check never
counts as an error for this purpose.
