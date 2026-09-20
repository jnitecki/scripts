# Requirement: Manual systemd-Unit Label Support (`systemd.unit`/`systemd.scope`)

## Scope
[[quadlet-managed-restart]] restarts a container via `systemctl --user
restart <unit>` instead of managing it directly, but only when the
container carries Podman's `PODMAN_SYSTEMD_UNIT` label - set automatically
for containers started by Podman Quadlet, and only for that specific case.

A container started by a **hand-written** systemd unit (`ExecStart=<engine>
run ...` in a plain `.service` file, not a Quadlet `.container` file) never
gets that label - it is Podman-Quadlet-specific - so today such a container
falls through to the normal `simple`/`safe` restart, which fights the
systemd unit that actually owns its lifecycle, exactly the class of problem
[[quadlet-managed-restart]] already solves for real Quadlet.

This requirement extends the same restart mechanism to hand-written units
via an operator-set label, and in doing so also fixes a latent gap in the
existing mechanism: it hardcodes `systemctl --user`, which is only correct
because real-world Quadlet usage is overwhelmingly rootless. A rootful/
system Quadlet setup needs plain `systemctl` (system scope), not `--user`.
Extending to hand-written units makes this impossible to ignore, since a
manually-managed container is just as likely to be system-scoped, and (for
Docker specifically) scope is not even determinable from the engine's own
state - see "Scope resolution" below.

## Requirement

### 1. Detection precedence
For each targeted container, before dispatching to a restart strategy, check
a `systemd.unit` container label first; if absent, check `PODMAN_SYSTEMD_UNIT`
(today's only source), unless disabled per the flags below. Either source
feeds the same restart mechanism ([[quadlet-managed-restart]] section 4),
distinguished only by which outcome gets reported on success (section 5).

### 2. New options
| Option | Description |
| --- | --- |
| `--skip-manual-unit-restart` | Do not use the systemctl-based restart path for a container whose only trigger is the manual `systemd.unit` label; a `PODMAN_SYSTEMD_UNIT` label still triggers it. Default: off. |
| `--skip-systemd-restart` | Do not use the systemctl-based restart path at all, for either trigger (equivalent to setting both this and `--skip-quadlet-restart`... but implemented as one independent flag, not as sugar for the other two, so it is unaffected if those are later changed). Default: off. |

`--skip-quadlet-restart` (existing) is unchanged in behavior, but its scope
is now explicitly only the `PODMAN_SYSTEMD_UNIT` trigger - a container
carrying only a manual `systemd.unit` label still uses the systemd-restart
path when `--skip-quadlet-restart` is set (use `--skip-manual-unit-restart`
or `--skip-systemd-restart` to affect that one instead).

### 3. Scope resolution (`systemd.scope` label: `user` | `system`)
Once a unit has been found for a container (section 1), its restart scope
(`--user` vs system) is resolved **before any `systemctl` call is made**,
using a new `systemd.scope` container label plus engine introspection. No
CLI flag controls scope - it is resolved per container, because standard
(rootful) Docker can genuinely mix scopes across containers within a single
invocation (see "Rationale" below).

```
scope_label = container's "systemd.scope" label, if any   # "user" | "system" | unset

if engine == podman:
    rootless = podman_is_rootless()          # `podman info --format '{{.Host.Security.Rootless}}'`, cached once per run
    expected = rootless ? "user" : "system"
    if scope_label set and scope_label != expected:
        -> systemd_unit_scope_mismatch, STOP (no systemctl attempt, no fallback)
    scope = scope_label or expected

elif engine == docker:
    docker_rootless = docker_is_rootless()   # `docker info`'s SecurityOptions contains "rootless", cached once per run
    if docker_rootless:
        if scope_label set and scope_label != "user":
            -> systemd_unit_scope_mismatch, STOP
        scope = "user"
    else:                                     # docker rootful: daemon state proves nothing about unit scope
        if scope_label set:
            scope = scope_label               # trust it, still existence-checked below
        else:
            scope = whichever of user/system has the unit file (probe both, user first)
            neither -> systemd_unit_not_found, STOP

# universal existence pre-check, in ALL cases regardless of how scope was resolved,
# including the plain auto-detected/no-label case:
if unit file does not exist at `scope`:
    -> systemd_unit_not_found, STOP

if scope == "system" and EUID != 0:
    -> systemd_unit_permission_denied, STOP

# only now: systemctl [--user] restart <unit>, same poll/validate loop as
# quadlet-managed-restart.md section 4, using the resolved scope throughout
# (the restart call itself and the is-active poll)
```

"Unit file exists at scope" is checked via `systemctl [--user] list-unit-
files "$unit" --no-legend` producing non-empty output - read-only, no
privilege needed just to list.

The permission pre-check is a deterministic `EUID -eq 0` test, not an
attempt to probe polkit-granted non-root authorization for managing a
specific system unit: this script never invokes `sudo` itself (a
deliberate choice - escalating privilege from inside an automation script
is the kind of thing that should be arranged explicitly by the operator,
e.g. by running the whole script as root, not inferred or triggered by it),
so a system-scope restart can only work if the script is already running
privileged enough, and that is exactly what this check verifies.

### 4. Why three new error outcomes skip the fallback
[[quadlet-managed-restart]] section 5's fallback rule - any failure to
restart via systemd falls through to the normal `simple`/`safe` restart,
unchanged - still applies to `systemctl` itself failing or the post-restart
poll timing out (section 3's `restart_via_systemd_unit` call, unchanged
from today). It does **not** apply to any of the three conditions in
section 3 above (`systemd_unit_scope_mismatch`, `systemd_unit_not_found`,
`systemd_unit_permission_denied`): those mean the script already knows,
before attempting anything, that this container is meant to be systemd-
owned and specifically why it cannot safely act on it. Falling back to
direct stop/rename/run in that situation would fight the real owner rather
than cooperate with it or safely decline - the same class of problem this
whole mechanism exists to avoid. A container hitting any of these three is
left completely untouched; the container-engine-level restart strategies
are never invoked for it.

### 5. Outcome classification
One new success outcome, `upgraded_via_manual_unit`, reported exactly like
`upgraded_via_quadlet` ([[quadlet-managed-restart]] section 6) but for a
`systemd.unit`-triggered restart instead of a `PODMAN_SYSTEMD_UNIT`-
triggered one - kept distinct because a manually-labeled container is not
necessarily genuine Quadlet, and the summary/log should not imply it is.

Three new error outcomes, one per condition in section 3:
`systemd_unit_scope_mismatch`, `systemd_unit_not_found`,
`systemd_unit_permission_denied`. All three count as errors in the final
summary (alongside e.g. `reconstruct_failed`), and none of them attempt
rollback or recovery - there is nothing to roll back, since (per section 4)
the container was never touched.

### 6. Label copying
No change needed. `get_run_command()`'s existing label reconstruction
(diffing a container's `Config.Labels` against its image's own defaults)
already carries any custom label - including `systemd.unit`/`systemd.scope`
- onto a recreated container whenever the `simple`/`safe` fallback path
runs, since neither label is ever part of an image's baked-in defaults.

## Rejected alternatives
- **A global `--systemd-scope user|system` flag** instead of a per-
  container label: rejected - a single flag cannot express a host where
  standard (rootful) Docker wraps some containers in user-scoped units and
  others in system-scoped ones, which is a legitimate, common-enough
  configuration (anyone with docker-group access can author either kind of
  unit against the one shared daemon). Podman and rootless Docker don't
  need this per-container granularity (see Rationale), but the mechanism is
  shared, so the label covers all engine/mode combinations uniformly.
- **The script invoking `sudo` itself for system-scope restarts**: rejected
  - privilege escalation should be an explicit operator decision (run the
    whole script as root, or grant a polkit rule), not something this
    script decides to trigger on a container's behalf.
  - Consequence: `systemd_unit_permission_denied` is a real, expected
    outcome for a non-root invocation targeting a system-scoped unit, not
    an edge case to be engineered away.
- **Treating scope-mismatch/not-found/permission-denied as ordinary
  systemctl-attempt failures** (i.e. letting them fall through to
  `simple`/`safe` like today's only failure mode): rejected per section 4 -
  these are cases where the script already knows better than to touch the
  container directly.
- **Probing actual `systemctl`/polkit authorization** instead of the cheap
  `EUID -eq 0` check: rejected as unnecessary complexity for a bash script;
  the "never invoke sudo" rule already means only a running-as-root
  invocation is the realistic supported case.

## Rationale
A single `podman`/`docker` invocation only ever talks to one API endpoint
(one rootless user socket, or the one system-wide rootful instance), so
every container this script sees in one run via Podman, or via rootless
Docker, is already homogeneously rootless or rootful - `podman info`'s (or
Docker's) own rootless signal is a reliable, single source of truth for the
whole invocation, and mismatches against a declared `systemd.scope` label
are therefore genuine configuration errors worth surfacing loudly rather
than silently working around.

Standard (rootful) Docker breaks that assumption: the daemon is a single
shared resource, and the choice of whether a given container's supervising
unit is user- or system-scoped is made independently, per unit, by whoever
authored it - not by the daemon's own state. This is why scope resolution
needs a per-container label and a unit-file-existence probe as a fallback,
specifically (and only) for that combination, while Podman and Docker
rootless can rely on engine introspection alone.

Extending [[quadlet-managed-restart]]'s restart/poll mechanism rather than
inventing a parallel one keeps the two trigger sources (automatic Quadlet
label vs. manual operator label) behaving identically once a unit is known,
while still letting the summary/log distinguish which one actually applied
- consistent with that requirement's own reasoning for keeping
`upgraded_via_quadlet` separate from `upgraded_externally`.
