# Requirement: Image Prune

## Scope
Each upgrade run pulls newer images, and the images they replace stay on
disk (untagged or unused) indefinitely. This requirement adds an optional
prune step that removes unneeded images as part of a normal run, so a
host doesn't have to be cleaned up by hand or by a separate job.

Images only: containers, networks, volumes and build cache are never
touched (no `system prune`).

## Requirement

### 1. `--prune none|dangling|all`
| Value | Command |
| --- | --- |
| `none` | No pruning — behavior from before this feature. |
| `dangling` (default) | `<engine> image prune -f` — untagged images not referenced by any container. |
| `all` | `<engine> image prune -a -f` — every image not used by any container, running or stopped. |

Can also be set as `prune` in the settings file ([[settings-file]]).
An invalid value is rejected immediately with a clear error, same as
`--mode`.

### 2. `--prune-until <duration>|none`
Limits pruning to images whose **creation time** is older than the given
duration, passed to the engine as `--filter until=<duration>`.

- Accepted format: `<N>m`, `<N>h` or `<N>d` (`N` a positive integer).
  Docker and Podman both take Go duration strings for `until`, which
  have no day unit, so `<N>d` is converted to `<N*24>h` before calling
  the engine. Anything else is rejected immediately with a clear error.
- `none` (default) means no age filter.
- It applies to both `dangling` and `all`. When the effective `prune` is
  `none`, it has no effect (not an error, since the two settings can
  legitimately come from different sources).
- Can also be set as `prune-until` in the settings file.
- **Caveat (documented in README and `--help`):** `until` compares
  against the image's *creation* (build) time, not when it was pulled to
  this host. An image built three weeks ago and pulled yesterday counts as
  three weeks old. So `--prune-until 7d` doesn't mean "keep what I
  pulled in the last week" — it mostly protects locally built or very
  recently published images.
- Engine support: both `docker image prune` and `podman image prune`
  accept `--filter until=...`. An engine version that rejects the filter
  makes the prune fail, which is handled per section 4.

### 3. When it runs
- Once per run, after the self-upgrade step and after the target
  containers have been resolved (Phase 1), immediately **before** the
  image pulls (Phase 2). Nothing pulled during this run can be pruned by
  this run, and images still used by a running container — including the
  one a safe-mode rollback would go back to — are never removed. The
  images an upgrade leaves behind are pruned on the **next** run.
- Pruning is host-wide even when specific container names are given on
  the command line; it still runs, and the log line says it's host-wide.
- If the run ends before Phase 2 (e.g. no valid containers to process),
  no prune happens.
- Not run for `--upgrade-check`, `--upgrade-only`, `--status`,
  `--register-banner` or `--unregister-banner` (none of them reach Phase 2).
- In a self-upgrade trial run, the candidate does the prune (it does the
  run's real work).

### 4. Output and failure handling
- A log line before pruning, e.g.
  `== Pruning dangling images (host-wide, older than 168h) ==`, followed
  by the engine's own output (including its reclaimed-space summary).
- A failed prune is a **warning** only: it is logged without error
  styling, doesn't set the error state, doesn't change the exit code, and
  the run continues with the pulls.

### 5. `--dry-run`
No prune is performed. Instead:
- `Dry run: would prune <dangling|all> images (host-wide[, older than X])`.
- For `dangling` without `--prune-until`, the candidates are listed
  (`<engine> image ls -f dangling=true`). With `--prune-until`, or for
  `all`, no list is printed (the engines can't preview that selection
  reliably), and the line says so.

### 6. Run summary log
[[run-summary-log]] entries get one new field, `prune`, with the effective
value (`none`/`dangling`/`all`), placed right after `mode`. No
reclaimed-space figure, since Docker and Podman format it differently.
`--status` is unaffected.

## Open items for implementation
- Tests first: option/value validation, the `d`→`h` conversion,
  command built for each engine/mode/filter, ordering relative to the
  pulls, warning-only failure, dry-run output, and the new log field.
- Version bump and CHANGELOG entry per
  [[script-maintenance-convention]].
- `--help` (core options), README (options table, a short "Image prune"
  section with the `until` caveat, the run-summary-log field table),
  `docs/implementation.md`.
- Not verified live: `podman image prune --filter until=...` behavior
  (no running Podman machine was available while writing this). Verify
  with both engines during implementation.
