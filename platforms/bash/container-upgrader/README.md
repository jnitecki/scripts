# container-upgrader

Iterates running Docker/Podman containers, pulls the latest image for each
(once per unique image), and recreates every container whose image actually
changed — or every targeted container if `--restart-all` is given — using
the same runtime settings as before.

## Motivation

In a home-lab or small self-hosted setup where Docker or Podman is used
directly (without a heavier orchestrator), keeping containers up to date
is a bigger logistical challenge than it first appears. Tagging a
container with `latest` doesn't mean it stays current — the image is
only re-pulled when the container is actually (re)started, and even
`--pull=always` (which forces a fresh pull on every `run`) has a sharp
edge: if that pull fails, the container fails to start instead of
falling back to the last-known-good image that's still cached locally.
On top of that, restarting a container correctly means reproducing every
original run flag, which in practice means maintaining a separate script
to (re)start it — unless startup is already delegated to systemd or a
similar service manager.

container-upgrader exists to remove that friction: it pulls the newest
image for each tag in use, detects which containers are actually
affected by a change, and restarts only those — reproducing their
original configuration automatically. In its default `safe` mode, it
also protects against a bad upgrade: if the new container fails to
start, or fails a post-upgrade health check within a configurable
timeout, it automatically rolls back to the previous image (this
doesn't apply to containers using Docker/Podman's `--rm` auto-removal,
or to containers that were already unhealthy before the upgrade — both
fall back to the simpler, non-rolling-back restart path automatically).
Containers managed by **Podman Quadlet**, or by a hand-written systemd
unit, are handled correctly too: instead of restarting the container
directly, container-upgrader restarts the systemd unit that owns it,
letting it regenerate the container the way it's meant to.

Finally, container-upgrader keeps itself current the same way it keeps
your containers current — via the repository's standard self-upgrade
mechanism — so there's one less thing to remember to update by hand.

## Requirements

- `docker` (or `podman`, see `--engine`)
- `jq`
- `curl` — only for the optional self-upgrade check; its absence just
  disables that check, the script still runs

The run command for each container is reconstructed locally from
`<engine> inspect` JSON — no external image or socket-mounted helper needed.

## Usage

```
./container-upgrader.sh [options] [container names...]
```

If no container names are given, all running containers are targeted.

## Restart modes

- **simple** — stop, remove, run the new container under the original name.
  Fast, but there is a window with no container running, and no automatic
  rollback if the new image is broken.
- **safe** (default) — stop the old container, rename it out of the way,
  start the new container under the original name, compare its runtime
  config against the original (catches flags the run-command reconstruction
  missed), then monitor it for `--timeout` seconds.
  - If everything checks out, the old (renamed) container is removed.
  - If something fails and the container was healthy before the upgrade, it
    is rolled back: the failed new container is stopped/removed, the old one
    is renamed back and started.
  - If the container was already crashing before the upgrade, it is **not**
    rolled back even if it is still failing on the new image (see
    `--skip-crashing` to opt out of attempting these at all).
  - A container started with `--rm` (AutoRemove) is destroyed by the engine
    the instant it stops, which the rename-based rollback above cannot
    survive. Such containers are automatically handled in **simple** mode
    instead, even when `--mode safe` is requested — this applies per
    container, not to the whole run.

Before touching anything, each targeted container is checked for
`--precheck-seconds` to see whether it is already crashing. This
pre-upgrade status, plus a post-upgrade check, drives both the rollback
policy above and the final summary report.

## External-restart detection

After stopping a container (either mode), the script waits up to
`--external-restart-wait` seconds to see whether something *other than this
script* — a systemd/Quadlet unit, another supervisor, a human — already
restarted or recreated it. This matters because Quadlet-managed containers
are supervised by their own systemd unit: `podman stop` typically makes the
container exit with a non-zero status from systemd's point of view, which
can trip a `Restart=` directive into recreating the container itself,
racing directly against this script's own rename/remove/run steps.

When a match is detected, neither restart strategy's own rename/remove/run
logic runs at all — the outcome is classified instead, without attempting
any rollback (an external restart means something else is actively managing
that container's lifecycle):

- **`upgraded_externally`** — it came back running the new image.
- **`reverted_externally`** — it came back running the old image.
- **`external_config_discrepancy`** — it came back under the same name with
  a different runtime config than before (fixed-name case only).

If nothing reappears within the wait window, the container is treated
exactly as before this feature existed — the normal `simple`/`safe` restart
proceeds unchanged.

## Systemd-managed restart

A container owned by a systemd unit is restarted differently from the
above: instead of reconstructing its flags or stopping/renaming/running it
directly, the script restarts its owning unit with `systemctl restart
<unit>` and validates the result — polling up to `--external-restart-wait`
seconds (the same setting used by external-restart detection) for the unit
to report active and a same-named container to come back running on the
newly-pulled image.

This applies regardless of `--mode`, and skips the normal restart entirely
when it succeeds — no flag reconstruction is required up front, the
container is never stopped directly, and there's no config diff against
the original (the unit rebuilds the container itself, not from anything
this script generated).

A container is recognized as systemd-managed in either of two ways,
checked in this order:

1. A manual **`systemd.unit`** label, naming the unit yourself — for a
   container started by a hand-written unit (`ExecStart=<engine> run ...`),
   which never gets Podman's automatic label below. Opt in by adding
   `--label systemd.unit=<unit-name>` to how the container is run.
2. Podman's automatic **`PODMAN_SYSTEMD_UNIT`** label, set on every
   container Podman Quadlet starts from a `.container` file. No setup
   needed — this is what made Quadlet containers "just work" before the
   manual label existed.

### Restart scope: `--user` vs. system

Before calling `systemctl`, the script resolves whether the unit is a
`--user` (rootless) unit or a system-wide one, since neither trigger above
is reliably one or the other:

- **Podman** — resolved automatically from `podman info` (rootless vs.
  rootful); an optional **`systemd.scope`** label (`user`/`system`) must
  match that reality or the restart is refused (see below).
- **Docker, rootless mode** — same idea, resolved from `docker info`.
- **Docker, standard (rootful) install** — the daemon is a single shared
  instance, so its own state says nothing about whether a given
  container's unit is user- or system-scoped; that's decided independently
  per container by whoever wrote its unit file. Set the `systemd.scope`
  label explicitly, or leave it unset and the script will look for a
  matching unit file at both scopes (user checked first).

Whatever scope is resolved, the script also confirms a matching unit file
actually exists there before doing anything. If any of this can't be
resolved safely, the container is **left completely untouched** — no
`systemctl` attempt, and (unlike an ordinary `systemctl` failure or
timeout, which still falls through to the normal `simple`/`safe` restart)
**no fallback restart either**, since a failure at this stage means the
script already knows the container is meant to be systemd-owned and
specifically why it can't safely act on it:

| Outcome | Meaning |
| --- | --- |
| `systemd_unit_scope_mismatch` | A `systemd.scope` label was set but doesn't match the engine's actual rootless/rootful state (or isn't `user`/`system`). |
| `systemd_unit_not_found` | No unit file exists at the resolved scope. |
| `systemd_unit_permission_denied` | The resolved scope is `system`, but the script isn't running as root. It never invokes `sudo` itself — run the whole script as root, or grant equivalent privilege, to restart system-scoped units. |

If the `systemctl` restart itself doesn't succeed within the wait window —
the command failed for some other reason, the unit never became active, or
the container came back still on the old image — the container falls
through to the normal `simple`/`safe` restart above, unchanged.

Use `--skip-quadlet-restart` to disable only the automatic
`PODMAN_SYSTEMD_UNIT` trigger, `--skip-manual-unit-restart` to disable only
the manual `systemd.unit` trigger, or `--skip-systemd-restart` to disable
this whole mechanism and manage every container like any other.

## Run summary log

This script typically runs unattended (cron, a scheduler, or by hand every
so often), with no reliable, uniform way across platforms to check when it
last ran or how that run went — cron/a scheduler isn't guaranteed
configured, and OS-level logging isn't a dependable fallback either: macOS's
unified log has no Linux equivalent, and even on Linux a syslog daemon or
`systemd-journald` isn't guaranteed installed (especially on minimal
container-host distros).

To close that gap, every real run (i.e. not `--dry-run`, `--upgrade-check`,
or `--upgrade-only`) appends one line to:

```
${XDG_STATE_HOME:-$HOME/.local/state}/scripts-state/bash_container-upgrader.log
```

Each line is a single JSON object:

```json
{"date":"2026-09-21T09:31:02Z","version":"1.1.8","mode":"safe","containers_not_uptodate":0,"images_updated_successfully":2,"images_update_failed":0,"containers_updated_successfully":3,"containers_update_failed":0}
```

| Field | Meaning |
| --- | --- |
| `date` | Run timestamp, ISO-8601 UTC. |
| `version` | The script version that ran. |
| `mode` | `simple` or `safe`. |
| `containers_not_uptodate` | Containers not confirmed running the latest image afterward — image pull failed, or a restart wasn't even attempted (skipped as already-crashing, or a systemd-unit restart that couldn't safely proceed, including the "requires root" case). |
| `images_updated_successfully` | Unique images successfully pulled with an actual version change. |
| `images_update_failed` | Unique images whose pull failed. |
| `containers_updated_successfully` | Containers confirmed running the new image and healthy. |
| `containers_update_failed` | Containers whose image pulled fine but whose restart/upgrade didn't cleanly succeed — including one that was rolled back and ended up healthy again, since the update itself still failed even though the container wasn't left broken. |

The file is trimmed to its most recent 50 entries after every run — check
the latest one with `tail -n1 <file> | jq .`. Writing this log is
best-effort and never affects the run's own exit code.

## Login status banner

**Ubuntu/Debian only** — this uses `pam_motd`'s dynamic MOTD mechanism
(`/etc/update-motd.d/`), not a generic cross-distro facility.

`--status` prints at most one line, derived from the run summary log above,
and does nothing else — no self-upgrade check, no docker/podman
dependency, safe to run unattended:

- `"N container(s) are awaiting upgrade."` — if the last run left any
  container not confirmed successfully on the latest image
  (`containers_not_uptodate + containers_update_failed > 0`).
- `"Containers were last upgraded N day(s) ago."` — otherwise, if at least
  `--status-stale-days` (default `3`) days have passed since that run.
- Nothing — otherwise, or if there's no log yet.

To show this automatically on every login:

```
sudo ./container-upgrader.sh --register-banner
```

This installs `/etc/update-motd.d/92-container-upgrader`, a small generated
script that runs `--status` as whichever user invoked `--register-banner`
(via `sudo`, or the current user if run directly as root) — that user is
fixed at registration time, not detected per login, so the banner always
shows *that* user's status regardless of who actually logs in. Add `--status-stale-days N` to
`--register-banner` to bake a custom threshold into the installed banner.
Re-running `--register-banner` regenerates it (e.g. after moving the script); only one
user's banner can be registered per host at a time. Remove it with:

```
sudo ./container-upgrader.sh --unregister-banner
```

## Options

| Option | Description |
| --- | --- |
| `--restart-all` | Recreate every targeted container regardless of whether its image actually changed. |
| `--mode simple\|safe` | Restart strategy (default: `safe`). |
| `--timeout N` | Seconds to monitor the new container after starting it (default: `30`). |
| `--precheck-seconds N` | Seconds to observe a container before touching it, to determine whether it is already crashing (default: `5`). This is a live fallback poll; see `--recent-restart-threshold` for the faster check that runs first. |
| `--recent-restart-threshold N` | Before the live `--precheck-seconds` poll, check `RestartCount` and the timestamp of the container's most recent (re)start (not its original creation time). If it has restarted at least once and that restart happened within the last `N` seconds, or it has a healthcheck stuck in "starting" for longer than `N` seconds, it's flagged as crashing immediately — no waiting required. Default: `180` (3 minutes). |
| `--external-restart-wait N` | Seconds to wait after stopping a container to see whether something other than this script (systemd/Quadlet, another supervisor, a human) restarts or recreates it on its own, before falling through to the normal restart. Also the wait used to validate a systemd-managed restart (see below). See [External-restart detection](#external-restart-detection). Default: `15`. |
| `--skip-quadlet-restart` | Do not use the systemd-managed restart path for a container carrying Podman's automatic `PODMAN_SYSTEMD_UNIT` label; manage it like any other container instead. A manual `systemd.unit` label still triggers the path unless one of the two options below is also set. See [Systemd-managed restart](#systemd-managed-restart). Default: off. |
| `--skip-manual-unit-restart` | Do not use the systemd-managed restart path for a container whose only trigger is a manual `systemd.unit` label; a `PODMAN_SYSTEMD_UNIT` label still triggers it. See [Systemd-managed restart](#systemd-managed-restart). Default: off. |
| `--skip-systemd-restart` | Do not use the systemd-managed restart path at all, for either trigger. See [Systemd-managed restart](#systemd-managed-restart). Default: off. |
| `--skip-crashing` | Do not attempt to upgrade containers detected as already crashing before the upgrade. Default is to attempt them anyway (see policy above). |
| `--engine docker\|podman` | Container engine to use. If omitted, auto-detects: docker if present, else podman, else errors out. |
| `--skip-config-check` | In safe mode, skip comparing the recreated container's runtime config against the original. Use if a specific container reliably shows a diff you've already verified is harmless. |
| `--dry-run` | Show what would happen, take no action, and skip the health-outcome summary (nothing was run). |
| `--status` | Print at most one line from the run summary log and exit. See [Login status banner](#login-status-banner). |
| `--status-stale-days N` | Days since the last run before `--status` shows the "last upgraded N day(s) ago" line. Default: `3`. Only valid with `--status` or `--register-banner` (an error otherwise); with `--register-banner` it is carried into the installed login banner. |
| `--register-banner` | Install a `/etc/update-motd.d/` script that runs `--status` on every login. Requires root. Ubuntu/Debian only. See [Login status banner](#login-status-banner). |
| `--unregister-banner` | Remove the script `--register-banner` installed. Requires root. |
| `--upgrade-type replacement\|overwrite\|link\|memory\|none` | Caps which self-upgrade apply mode is attempted (falls back to a weaker mode automatically if the requested one isn't possible on this filesystem); `none` disables self-upgrade entirely. Default: unset (tries `replacement` first, cascading down). Not combinable with `--upgrade-check` or `--no-autoupdate`. |
| `--upgrade-level dev\|alpha\|beta\|rc\|stable` | Minimum release channel eligible for self-upgrade. Default: unset (this script's own level — same-or-higher than what's currently running). |
| `--upgrade-check` | Report what a self-upgrade would do (and which apply mode this filesystem supports) and exit — no download, no change made. Not combinable with `--upgrade-type` or `--upgrade-only`. |
| `--upgrade-only` | Perform the self-upgrade check and, if eligible, the upgrade itself, then exit without doing any container work. Not combinable with `--upgrade-check`. |
| `--no-autoupdate` | Shortcut for `--upgrade-type none`: skip self-upgrade entirely for this run. Not combinable with `--upgrade-type`. |
| `-h`, `--help` | Show usage. |

## Self-upgrade

On every invocation other than `--help` (and unless `--upgrade-type none` /
`--no-autoupdate` is given), the script checks `github.com/jnitecki/scripts`
for a newer release of itself, at or above its own release channel
(`--upgrade-level` to widen or narrow that). If one is found, it's
downloaded and validated (syntax check, plus a best-effort content-hash
check against the value declared in its release tag), then actually run to
do this invocation's real work — only a successful run gets kept:

- **replacement** (used when the script's directory is writable) — a
  sibling temp file, `mv`'d into place after a successful run.
- **overwrite** (directory not writable, but the file itself is) — the
  file's content is rewritten in place after a successful run.
- **link** (neither is writable, but `~/.cache/scripts-upgrade/` is) — a
  copy kept in that cache directory and run from there; the original script
  path is never touched. A cached copy whose hash already matches the
  latest release is reused directly, without downloading again.
- **memory** (nothing is writable) — run once, never persisted; every
  future invocation starts from the currently-loaded version again.

`--upgrade-type` caps which of these is attempted. A failed trial run (the
real work itself failing, not a bad download) is this invocation's own
outcome — nothing is persisted, and it is **not** retried under the old
version. A failure before that point (network, download, parse, hash
mismatch) falls back to continuing normally under the already-loaded
version, reported on the startup line. Checks are skipped for up to 20
minutes after the last one, but only for a plain invocation with no
upgrade-related flags — any of the flags above always checks fresh. Use
`--upgrade-check` to see what would happen without changing anything, or
`--upgrade-only` to perform just the upgrade and exit.

The startup line always says what happened with the check — checked and
found nothing newer, skipped this run because it was still within the
20-minute cooldown, upgrading to a newer version, or the check itself
failing — except when self-upgrade is disabled outright
(`--upgrade-type none` / `--no-autoupdate`), the only case with no note at
all. When an upgrade is actually applied (replacement/overwrite), a
further line after the run reports whether persisting it succeeded —
separately from the run itself succeeding, since the two can differ (e.g.
the run succeeds but writing the upgraded file back fails); either way, it
never changes this invocation's own exit code.

## What gets reconstructed

Name, hostname (if overridden), user, workdir (if overridden), env vars
(only those added/changed vs. the image default), labels (added/changed vs.
image default), published ports, bind/volume/tmpfs mounts, network mode (if
non-default), restart policy, privileged, cap-add/cap-drop, devices, extra
hosts, memory limit, cpu limit, security-opt, dns, tty/stdin flags,
entrypoint override (first element only), and cmd (if overridden).

Workdir/env/labels/entrypoint/cmd are all diffed against the **original**
image the container was actually created from, not the new image it's
being upgraded to. This matters: if a container never explicitly set one of
these (it just inherited the old image's default), that value is left out
of the reconstructed command entirely, so the new container picks up the
new image's own default for it instead of getting stuck on the old value —
e.g. if an image's default entrypoint path changes between versions, an
upgraded container that never overrode it starts on the new entrypoint, not
a stale path that may no longer exist in the new image.

### Known limitations

The safe-mode config check exists specifically to catch these before they
cause silent drift:

- If the original container's entrypoint has more than one element (e.g.
  `["/bin/sh", "-c"]`), only the first element is reproduced via
  `--entrypoint`.
- Only the primary network is captured, not additional networks a container
  was attached to after creation.
- ulimits, sysctls, health checks, ipc/pid/uts/userns mode, shm-size, init,
  group-add, dns-search, and readonly-rootfs are not reproduced when
  rebuilding the run command, but **are** checked by the safe-mode config
  comparison, so drift here is detected and rolled back rather than
  silently applied.

## Output

Errors (failed pulls, failed reconstructions, failed starts, config
mismatches, rollbacks, and any container ending up still broken) are
printed in red/bold when the terminal supports color. If any occurred, the
very last line of output is `ERRORS OCCURRED - REVIEW THE OUTPUT`, also
colored.

Exit code is `1` if any errors occurred during the run, `0` otherwise.
