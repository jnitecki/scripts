# Requirement: Restart Quadlet-Managed Containers via systemctl

## Scope
`container-upgrade.sh` currently treats every targeted container the same
way: capture its run command via `get_run_command`, then hand it to
`restart_simple` or `restart_safe`, both of which stop the container
directly and either recreate it in place (`simple`) or rename/start/verify/
rollback it (`safe`).

A container started by Podman Quadlet is not meant to be managed this way.
Quadlet generates the `podman run` invocation from a `.container` unit file
and hands lifecycle control to systemd; the engine-level container is
really a side effect of that unit being active. Reconstructing and
reapplying its flags (as `get_run_command`/safe mode's config check do) or
stopping it directly races against systemd, which may itself act on the
unit (restart-on-failure, `ExecStopPost` cleanup, etc.) independently of
this script - exactly the class of interference
[[external-restart-detection]] already generalizes for, but here the
correct response isn't to *detect* an external actor after the fact, it's
to *ask systemd to do the restart itself* and validate the result, since
this script already knows in advance which containers are Quadlet-managed.

Podman sets a `PODMAN_SYSTEMD_UNIT` label (to the managing unit's name,
e.g. `container-myapp.service`) on every container it starts under
Quadlet. This requirement adds a restart path, gated on that label, that
asks the owning systemd user unit to restart itself instead of managing
the container's flags or lifecycle directly.

## Requirement

### 1. Detection
For each targeted container, before dispatching to a restart strategy,
read its `PODMAN_SYSTEMD_UNIT` label (`Config.Labels` from `$ENGINE
inspect`, same JSON-dump-then-`jq` pattern used elsewhere in the script,
e.g. `normalized_config`). If present and non-empty, and
`--skip-quadlet-restart` is not set, this container uses the Quadlet
restart path below **instead of** `restart_simple`/`restart_safe` -
regardless of `--mode`. `--mode` still governs the fallback path if the
Quadlet restart does not succeed (section 4).

This check is engine-agnostic (no special-casing on `--engine podman` vs.
`docker`) - a Docker-managed container will simply never carry this label,
so the check is a no-op for it.

### 2. New option
| Option | Description |
| --- | --- |
| `--skip-quadlet-restart` | Do not use the systemctl-based restart path for containers carrying a `PODMAN_SYSTEMD_UNIT` label; manage them the same as any other container instead (existing `simple`/`safe` behavior, unchanged). Default: off (Quadlet-labeled containers use the new path). |

### 3. What the Quadlet path does NOT do
For a container using this path:
- **No flag reconstruction is required up front.** `get_run_command`'s
  result is not needed for this path to run - a reconstruction failure
  (`reconstruct_failed`) does not block attempting it (see section 5 for
  how this interacts with the existing early-skip check, since
  reconstruction is still attempted for every container up front and its
  result is still needed for the *fallback* path).
- **The container is never stopped directly** (`$ENGINE stop`/`rm`/
  `rename` are not called by this script for this attempt) - systemd owns
  the stop/start sequence.
- **The 1.1.3 restart-policy relax/restore step
  (`get_restart_policy`/`set_restart_policy` around `always` ->
  `unless-stopped`) does not apply to this attempt.** That mechanism
  exists specifically to protect a container the script itself is holding
  stopped mid-upgrade from the engine's own daemon-restart race; since
  this script never stops the container here, that window doesn't open.
  (It still applies unchanged on the fallback path, section 4.)
- **No config-fingerprint comparison** (`normalized_config` diff) is
  performed against the pre-restart state. Unlike safe mode's own
  post-recreate check (which validates *this script's* flag
  reconstruction), the new container here is produced entirely by
  Quadlet/systemd from the `.container` file - there is nothing this
  script generated to validate against. Only the image is checked
  (section 4).

### 4. Executing and validating the restart
1. Before restarting, record the container's current image ID (already
   available as `old_id`/`OLD_ID_OF`) and the newly-pulled image ID for
   this container's image (`new_id`/`NEW_ID_OF_IMAGE`) - both already
   computed earlier in the existing per-image pull phase, no new
   collection needed.
2. Run `systemctl --user restart <unit>`, where `<unit>` is the label's
   value verbatim (no transformation, e.g. no assumption about a
   `.service` suffix being present or absent).
   - If this command itself fails (non-zero exit - e.g. no user systemd
     session, unit not found), log the error output and treat as
     "not restarted"; go straight to the fallback path (section 5), no
     polling needed.
3. On success, poll once per second for up to `$EXTERNAL_RESTART_WAIT`
   seconds (the same setting and default used by
   [[external-restart-detection]] - not a new option) for **both**:
   - `systemctl --user is-active <unit>` reports `active`, **and**
   - a container named `<name>` exists, is running
     (`.State.Running == true`), **and** its image ID equals `new_id`.
   - As soon as both hold in the same poll, classify as **success**
     (new outcome, see section 6) and stop polling.
4. If the wait expires without both conditions holding at once (unit
   never becomes active, container never comes back running, or it comes
   back running but still on the old image), treat as "not restarted" and
   fall through to section 5. No partial/discrepancy classification is
   needed here (unlike [[external-restart-detection]]'s
   `external_config_discrepancy`) - any non-success reason leads to the
   same fallback action, so the reason is only logged, not classified.

### 5. Fallback on failure
If the Quadlet restart did not succeed (systemctl call failed, or the
poll window expired without both success conditions), the container
proceeds through the **existing, fully unchanged** path: `restart_simple`
or `restart_safe` per `--mode` (including that path's own stop, its own
[[external-restart-detection]] wait/classification, restart-policy
relax/restore, and, in safe mode, rollback machinery) - exactly as if the
container had no `PODMAN_SYSTEMD_UNIT` label at all.

This requires a working `run_cmd` from `get_run_command`. Since
reconstruction is still attempted for every container up front (existing
behavior, unchanged) but no longer blocks the Quadlet attempt (section 3),
the existing early-skip-with-`reconstruct_failed` check moves to *after*
the Quadlet attempt: a labeled container with a failed reconstruction
still gets the Quadlet attempt; it is only skipped with
`reconstruct_failed` if that attempt also does not succeed and there is no
`run_cmd` to fall back with. A non-labeled container (or
`--skip-quadlet-restart`) keeps today's behavior exactly - skipped
immediately on reconstruction failure, before any restart attempt.

### 6. Outcome classification
A successful Quadlet restart (section 4.3) is reported as a new, distinct
outcome - e.g. `upgraded_via_quadlet` - separate from
[[external-restart-detection]]'s `upgraded_externally`: that existing
outcome means some *other, unidentified* actor beat the script to it,
whereas this one is an action the script itself deliberately took. It
should be included in the final summary/report (counts + description),
following the same pattern as `upgraded_externally`/`reverted_externally`
today.

A container that falls through to the fallback path (section 5) is
classified exactly as it would be today via that path - no new outcome
value for "Quadlet attempted then fell back"; the fact that it was
attempted is only visible in the log, not in the final RESULT.

## Rejected alternatives
- **Reusing `restart_simple`'s/`restart_safe`'s existing
  `EXTERNAL_RESTART_OUTCOME` plumbing/outcome values as-is** (e.g.
  reporting Quadlet-path success as `upgraded_externally`): rejected -
  conflates "this script deliberately restarted it via systemd" with "some
  unidentified other actor got there first," which matters for anyone
  reading the summary/log to understand what actually happened.
- **Comparing full `normalized_config` fingerprints after a Quadlet
  restart**, mirroring safe mode's post-recreate check: rejected - that
  check validates *this script's own* flag reconstruction against the
  original; a Quadlet restart never goes through this script's
  reconstruction, so there is nothing meaningful to diff against, and a
  literal config difference (e.g. Quadlet regenerating something
  differently across a Podman version bump) isn't this script's problem
  to flag or recover from.
- **A separate `--quadlet-restart-wait` option**: rejected per explicit
  instruction - reuses `--external-restart-wait`/`$EXTERNAL_RESTART_WAIT`
  as-is, since both are "how long to wait for a container to come back
  under a name we recognize" with no reason to tune them independently.

## Open items for implementation
- Version bump / CHANGELOG entry per
  `docs/requirements/generic/script-maintenance-convention.md` (to be done
  at implementation time, not part of this requirement's design).
- Help text (`HELP:CORE-OPTIONS`, `HELP:INTRO`) needs the new option and a
  short mention of this path, following the existing style for
  `--external-restart-wait`/`--skip-config-check`.

## Rationale
Quadlet-managed containers already have a designated owner for their
lifecycle - systemd - and the correct integration is to ask that owner to
act, not to race or duplicate it. This is a natural companion to
[[external-restart-detection]]: that requirement covers containers where
the script has no advance knowledge that something else might act;
this one covers the case where the script *does* know in advance (the
label is right there) and can cooperate proactively instead of just
detecting after the fact. Keeping the two outcome spaces distinct
(`upgraded_via_quadlet` vs. `upgraded_externally`) preserves that
diagnostic distinction in the summary/log rather than blurring "the
script asked systemd to do it" into "something unidentified did it."
