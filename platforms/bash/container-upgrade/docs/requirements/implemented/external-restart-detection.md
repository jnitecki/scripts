# Requirement: External-Restart Detection During Upgrade

## Scope
`container-upgrade.sh`'s restart strategies (`simple` and `safe`) currently
guard against one specific interference source: the container engine's own
`--restart always` policy bringing the container back up on its old image
while it sits stopped mid-upgrade (see version-history entry 1.1.3, the
relax-to-`unless-stopped`/restore-to-`always` step around `RestartPolicy`).

This requirement covers a second, distinct interference source: some
process *outside the engine's own restart-policy mechanism* — a systemd
unit, a Kubernetes/Swarm-style controller, docker-compose's own supervisor,
a custom watch script, or a human — that notices the container is gone and
recreates or restarts it independently. The script cannot know in advance
whether such a thing is watching any given container, so detection is
always attempted rather than gated on any up-front signal.

## Requirement

### 1. Always-on detection, after every stop
Immediately after each restart strategy stops the targeted container (and
after the existing 1.1.3 relax-to-`unless-stopped` step, which still runs
first and is unchanged), the script waits up to a new `--external-restart-wait N`
seconds (default **15**) for a container to reappear that looks like the
same logical container coming back up on its own.

Once `always` has already been relaxed to `unless-stopped` before the stop,
the engine's own daemon/service restart is ruled out as a cause — so *any*
reappearance during this window can only be explained by something
external (or a human) restarting it. There is no reliable up-front signal
to gate this on, so it runs for every container, every time, in both
`simple` and `safe` mode identically (section 6).

### 2. New option
| Option | Description |
| --- | --- |
| `--external-restart-wait N` | Seconds to wait after stopping a container to see whether an external service/process restarts it on its own, before falling through to the normal manual restart. Default: `15`. |

### 3. Detecting a match

Before the container is stopped, its `normalized_config()` fingerprint
(the same mechanism safe mode already uses for its own post-upgrade config
check) is captured, and — only for the auto-generated-name case below — the
set of currently-existing container IDs is snapshotted. The detection
algorithm then differs by name shape:

#### 3a. Fixed name (original name is not auto-generated — see heuristic below)
Poll for a container to exist and be running again under the **exact
original name**. Since the engine never allows two containers to share a
name at once, reappearance under that name is itself the detection signal
— no further condition is needed to call it "a restart happened."
Once detected:
- Compare its `normalized_config()` fingerprint (excluding the `image`
  field only) against the pre-stop fingerprint.
  - **Mismatch** → classify immediately as **restart-failed /
    config-discrepancy** (a new, distinct outcome — see section 4). This
    check happens *before* the image is even looked at.
  - **Match** → proceed to the image check (section 4).
- If the name never reappears within `N` seconds, nothing was detected;
  fall through to the existing manual restart path, fully unchanged
  (including its rollback machinery).

#### 3b. Auto-generated name (original name matches the heuristic below)
An external recreate here is not obligated to reuse the same name (most
supervisors don't pass `--name`), so detection instead looks for **any new
container** (an ID absent from the pre-stop snapshot) whose:
- name also matches the auto-generated-name heuristic, **and**
- `normalized_config()` fingerprint matches the pre-stop original's,
  **excluding both the `image` and `name` fields**.

Because fingerprint equality (apart from name/image) *is* the match
condition here, a matching candidate can never turn out to have a config
discrepancy — unlike 3a, there is no separate "config-discrepancy" outcome
for this path, only the two image-based outcomes in section 4. A
same-shaped candidate whose fingerprint does *not* match is simply not a
match — it is ignored and the wait continues (it might be some unrelated
auto-named container already running on the host).
If nothing matches within `N` seconds, fall through to the existing manual
restart path, fully unchanged.

#### Auto-generated-name heuristic
A name is treated as auto-generated if it matches
`^[a-z][a-z0-9]*_[a-z][a-z0-9]*$` — a single underscore joining two
lowercase-alphanumeric segments, the shape Docker's own generator always
produces. Accepted as a heuristic: a deliberately-chosen name of the same
shape (e.g. `blue_db`) would also qualify, and it is not validated against
Docker's actual internal adjective/surname word lists.

### 4. Outcome classification

**Fixed-name matches** (config check already passed per 3a):

| Image | Outcome |
| --- | --- |
| New (upgraded) | **Success** — reported as upgraded via external restart. |
| Old (pre-upgrade) | **Failure** — "reverted to old image". No retry attempted. |

(A config-discrepancy fixed-name match is already classified and reported
in 3a, before this table ever applies.)

**Auto-name-pattern matches** (fingerprint already guaranteed equal apart
from name/image per 3b):

| Image | Outcome |
| --- | --- |
| New (upgraded) | **Success** — reported as upgraded via external restart. The leftover original (now-stopped, still under its old name) container is **removed automatically**, mirroring safe mode's own cleanup of its renamed-aside original. |
| Old (pre-upgrade) | **Failure** — "reverted to old image". No retry attempted. The leftover original stopped container is **left in place** for manual review — only the success path cleans it up. |

**No rollback or recovery action is ever attempted for any
externally-detected-match outcome** — success, reverted-to-old-image, or
fixed-name config-discrepancy. Rollback machinery (safe mode's `rollback`/
`fail_no_rollback`) is exclusively used on the unchanged fallback path
(section 3's "nothing detected within `N` seconds" case), exactly as it
works today.

### 5. Restart-policy restore (interaction with 1.1.3)
If the policy was relaxed to `unless-stopped` before the stop, it is
restored to `always` on whichever container ends up holding the identity
for that name, in **every** outcome — matched-success, matched-failure
(reverted-to-old-image or config-discrepancy), and the unchanged fallback
path — following the same best-effort, non-blocking pattern already used
today, reported via the existing `RESTART_POLICY_ISSUES` category on
failure.

### 6. Applies identically in `simple` and `safe` mode
This detection/classification protocol (sections 3–5) is independent of
restart strategy and runs identically in both modes, immediately after the
stop step and before whatever the mode would otherwise do next (rename +
create in `safe` mode; remove + run in `simple` mode). Those next steps are
skipped entirely whenever any match was found (success, reverted, or
config-discrepancy) — the external service already acted, and no
recovery is attempted regardless of outcome. They run exactly as today
only on the unchanged fallback path.

Safe mode's own *existing*, optional post-recreate verification feature
(the `normalized_config` diff + `--timeout` health monitor, together
gated by `--skip-config-check` for the diff half) is unaffected: it is
part of the manual-restart path only, and is never invoked on any
matched-outcome path introduced by this requirement.

## Rejected alternatives
- **Exact word-list matching for the auto-name heuristic** (embedding
  Docker/Moby's real adjective + surname lists): rejected in favor of the
  shape-based regex — avoids maintaining a second copy of a list that can
  drift across Docker versions, at the accepted cost of rare false
  positives on a coincidentally-shaped manual name.
- **Running safe mode's config-check/monitor/rollback on a matched
  container**: rejected. The fixed-name path already does its own
  equivalent config check (section 3a) before classifying, and no
  externally-detected outcome (matched or reverted) ever attempts recovery
  — retrying or rolling back a container an external process is actively
  managing would fight that process rather than cooperate with it.
- **Retrying the manual-restart path after a "reverted to old image"
  classification**: rejected — same reasoning, avoids a flapping loop
  against whatever keeps restarting the container.

## Rationale
Mirrors the reasoning already established for 1.1.3 (a container sitting
stopped mid-upgrade is exposed to something else bringing it back up
underneath the script), but generalizes it to sources outside the engine's
own restart-policy mechanism, which 1.1.3 cannot detect or prevent by
construction. Reusing `normalized_config()` for the match/discrepancy
checks avoids inventing a second comparison mechanism alongside the one
safe mode already relies on. Never attempting rollback/retry on a
detected-external-restart outcome keeps the script from fighting whatever
process is actually managing the container's lifecycle — it only recovers
containers it fully owns the lifecycle of (the unchanged fallback path).
