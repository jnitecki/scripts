# Requirement: Run Summary Log

## Scope
There is currently no reliable, platform-independent way to determine when
`container-upgrader.sh` was last run, or what happened on that run, without
reading whatever ad-hoc terminal/redirected output a particular invocation
happened to produce. Neither cron nor a persistent scheduler is guaranteed to
be configured, and OS-level logging facilities are not a uniform fallback:
the macOS unified log has no equivalent on Linux, and even on Linux a
syslog daemon or `systemd-journald` is not guaranteed to be installed or
running (e.g. minimal/Alpine-based container-host distros this script
targets). This requirement adds a small, self-managed, append-only run
summary log that the script itself writes on every real run, independent of
any OS logging facility, cron, or systemd unit.

## Requirement

### 1. Location
```
${XDG_STATE_HOME:-$HOME/.local/state}/scripts-state/${SCRIPT_LANG}_${SCRIPT_NAME}.log
```
i.e. `${XDG_STATE_HOME:-$HOME/.local/state}/scripts-state/bash_container-upgrader.log`
today. This mirrors the existing self-upgrade cooldown cache's path
structure (`${XDG_CACHE_HOME:-$HOME/.cache}/scripts-upgrade/bash_container-upgrader.state`
— see `docs/implementation.md`), but under `XDG_STATE_HOME`, not
`XDG_CACHE_HOME`: this file is a meaningful persistent record, not
disposable cache a user could clear without losing anything. `XDG_STATE_HOME`
is not native to macOS (Apple's own convention is `~/Library/...`), but this
script has already opted into XDG-style paths on every platform for its
self-upgrade cache, so this is consistent with that existing choice rather
than a new one.

### 2. Format
One JSON object per line (JSON Lines), built with `jq` (already a hard
dependency of this script). Fields, in this order:

| Field | Meaning |
| --- | --- |
| `date` | Run timestamp, ISO-8601 UTC (`YYYY-MM-DDTHH:MM:SSZ`) — per this repo's ISO-Z timestamp convention for technical/log timestamps. |
| `version` | `$SCRIPT_VERSION` |
| `mode` | `$MODE` (`simple`/`safe`) |
| `containers_not_uptodate` | Containers that, after this run, are **not** confirmed running the latest image — pull failed, or a restart wasn't even attempted (skipped-crashing, or a systemd-unit restart that couldn't safely proceed, including the "requires sudo" case). |
| `images_updated_successfully` | Unique images successfully pulled with an actual version change. |
| `images_update_failed` | Unique images whose pull failed. |
| `containers_updated_successfully` | Containers confirmed running the new image and healthy. |
| `containers_update_failed` | Containers whose image pulled successfully but whose restart/upgrade did not cleanly succeed (includes a rollback that left the container healthy again — the *update itself* still failed even though the container wasn't left broken). |

Exact mapping to the script's existing `RESULT` outcome statuses (chosen so
every one of the 17 statuses is accounted for exactly once, with no overlap
and no silent gap):

- `containers_updated_successfully`: `upgraded`, `recovered`,
  `upgraded_externally`, `upgraded_via_quadlet`, `upgraded_via_manual_unit`
- `containers_update_failed`: `rolled_back_working`, `now_failing`,
  `still_failing`, `reconstruct_failed`, `reverted_externally`,
  `external_config_discrepancy`
- `containers_not_uptodate`: `pull_failed`, `systemd_unit_scope_mismatch`,
  `systemd_unit_not_found`, `systemd_unit_permission_denied`,
  `skipped_crashing`
- Not counted in any of the three: containers never attempted because they
  were already up to date, and `restarted` (`--restart-all` forced restart
  with no image change) — both are already up to date, nothing to report.

No "other fields" exist yet; the format is line-oriented JSON specifically
so new fields can be added later without breaking existing readers/tools
that parse it (unlike a fixed-width or positional format).

### 3. When it is written
Once per real run, after the existing summary counts (`count_upgraded`,
`count_pull_failed`, etc.) are computed — i.e. the same point the existing
`log "===== Summary ====="` section already has everything it needs. **Not**
written for:
- `--dry-run` (exits before real counts exist; nothing was actually done)
- `--upgrade-check` / `--upgrade-only` (exit before any container work)
- Any failure before reaching the summary (e.g. missing `jq`/engine, bad
  arguments) — there is nothing meaningful to report yet

### 4. Retention
The file is trimmed to its most recent 50 entries after every append (plain
`tail -n 50`, no external log-rotation dependency — consistent with this
requirement's whole point of not depending on OS-level facilities). 50 is a
judgment call, not a hard requirement from any existing convention; easy to
change later if it's too short/long in practice.

### 5. Failure handling
Best-effort, matching this script's existing philosophy for auxiliary state
(the self-upgrade cooldown cache, the `link`-mode cache): if the directory
can't be created, `jq` fails, or the write/trim fails, the run continues
normally and this is not treated as an error (`HAD_ERRORS` unaffected, no
`err()` call) — this log is a convenience, not part of this script's actual
job of upgrading containers.

## Rejected alternatives
- **OS syslog / macOS unified log / `systemd-journald`**: rejected as the
  primary mechanism — not guaranteed present or uniform across the
  platforms this script targets (see Scope). May still be worth adding as a
  *best-effort secondary* `logger` call in a future requirement, but that is
  out of scope here.
- **Single last-run file (overwritten each run, no history)**: rejected —
  a short bounded log costs almost nothing extra over a single-entry file
  (same write path, same best-effort handling) and preserves enough history
  to answer "was this failing before" rather than just "did it run".
- **Unbounded log**: rejected — would grow forever with no external
  rotation guaranteed available (the same problem this requirement exists
  to avoid depending on for reading; writing has the same issue).

## Open items for implementation
- Version bump / CHANGELOG entry per
  `docs/requirements/generic/script-maintenance-convention.md` (at
  implementation time).
- A short mention of this log (path + fields) belongs in `--help`'s
  `HELP:OUTPUT` region and in the README, since it's always-on behavior a
  user should know exists.
- `docs/implementation.md` gets a new section documenting this, matching
  its existing per-topic style.

## Rationale
This script already runs unattended, and the motivating question was "did
something happen that I didn't notice" — a single last-run timestamp
answers "is it still running at all" but not "was the last run actually
successful", which a short bounded history answers just as cheaply. Scoping
the fields to the script's own existing `RESULT` taxonomy (rather than
inventing new categories) keeps this consistent with the summary the script
already prints, and keeps the three counters an exact partition of every
possible outcome, so nothing silently falls outside all three.
