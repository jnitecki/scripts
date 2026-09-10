# container-upgrade

Iterates running Docker/Podman containers, pulls the latest image for each
(once per unique image), and recreates every container whose image actually
changed — or every targeted container if `--restart-all` is given — using
the same runtime settings as before.

## Requirements

- `docker` (or `podman`, see `--engine`)
- `jq`
- `curl` — only for the optional self-upgrade check; its absence just
  disables that check, the script still runs

The run command for each container is reconstructed locally from
`<engine> inspect` JSON — no external image or socket-mounted helper needed.

## Usage

```
./container-upgrade.sh [options] [container names...]
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

Before touching anything, each targeted container is checked for
`--precheck-seconds` to see whether it is already crashing. This
pre-upgrade status, plus a post-upgrade check, drives both the rollback
policy above and the final summary report.

## Options

| Option | Description |
| --- | --- |
| `--restart-all` | Recreate every targeted container regardless of whether its image actually changed. |
| `--mode simple\|safe` | Restart strategy (default: `safe`). |
| `--timeout N` | Seconds to monitor the new container after starting it (default: `30`). |
| `--precheck-seconds N` | Seconds to observe a container before touching it, to determine whether it is already crashing (default: `5`). This is a live fallback poll; see `--recent-restart-threshold` for the faster check that runs first. |
| `--recent-restart-threshold N` | Before the live `--precheck-seconds` poll, check `RestartCount` and the timestamp of the container's most recent (re)start (not its original creation time). If it has restarted at least once and that restart happened within the last `N` seconds, or it has a healthcheck stuck in "starting" for longer than `N` seconds, it's flagged as crashing immediately — no waiting required. Default: `180` (3 minutes). |
| `--skip-crashing` | Do not attempt to upgrade containers detected as already crashing before the upgrade. Default is to attempt them anyway (see policy above). |
| `--engine docker\|podman` | Container engine to use. If omitted, auto-detects: docker if present, else podman, else errors out. |
| `--skip-config-check` | In safe mode, skip comparing the recreated container's runtime config against the original. Use if a specific container reliably shows a diff you've already verified is harmless. |
| `--dry-run` | Show what would happen, take no action, and skip the health-outcome summary (nothing was run). |
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

## What gets reconstructed

Name, hostname (if overridden), user, workdir (if overridden), env vars
(only those added/changed vs. the image default), labels (added/changed vs.
image default), published ports, bind/volume/tmpfs mounts, network mode (if
non-default), restart policy, privileged, cap-add/cap-drop, devices, extra
hosts, memory limit, cpu limit, security-opt, dns, tty/stdin flags,
entrypoint override (first element only), and cmd.

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
