# Changelog — container-upgrade.sh

Complete version history for `container-upgrade.sh`, newest entry first —
every version bump gets its own entry here, pre-releases included. The
script's own header keeps a much shorter, **stable-versions-only** window
(3 entries, most recent in full): a pre-release bump never gets its own
header line — every pre-release since the last stable release is folded
into one running "in progress" entry there instead. When a pre-release
cycle is promoted to stable, that consolidated summary graduates into a new
stable-version entry here, *alongside* (not replacing) the individual
pre-release entries already recorded for that cycle below. See
[docs/requirements/generic/script-maintenance-convention.md](../../../docs/requirements/generic/script-maintenance-convention.md)
section 3 for the exact rule.

## 1.1.6-dev3
Implements two clarifications added to
`docs/requirements/generic/script-upgrade-convention.md`:
1. The cooldown cache (section 14) now only gates a fresh *remote* check —
   local apply-mode eligibility (section 6) is always re-evaluated fresh,
   never itself cached. A new `upgrade_prepare_cached_candidate` runs
   whenever an implicit invocation is cooldown-gated: if a candidate is
   already sitting validated in the local `link`-mode cache (section 7)
   and this run's freshly-determined filesystem eligibility has newly
   escalated past `link` (e.g. this run is `sudo`, the one that cached it
   wasn't), that candidate is promoted straight to `replacement`/
   `overwrite` now, going through the same trial-run-then-persist model as
   any other apply — reading bytes straight from the cache file itself
   (`upgrade_write_temp_sibling_from_file`, `upgrade_persist_overwrite_
   from_file`) rather than through a lossy `content=$(cat ...)` round-trip.
   No cooldown timestamp is written on this path, since nothing remote was
   actually checked.
2. `replacement` and `overwrite` now explicitly carry over the original
   file's permissions and ownership instead of whatever the write happened
   to produce: `upgrade_write_temp_sibling`/`_from_file` copy `stat`'d mode
   bits and owner:group from the original onto the temp file before it's
   `mv`'d over the original (`upgrade_copy_mode_owner`, GNU-`stat`-first
   with a BSD/macOS fallback, matching this file's `parse_to_epoch`
   pattern for `date`); `overwrite` already preserved both by construction
   (its rewrite never creates a new inode) and gets an explanatory comment
   only. Ownership (`chown`) is best-effort — it silently no-ops without
   sufficient privilege (typically root), consistent with this
   convention's existing best-effort philosophy; mode bits are always
   applied.

## 1.1.6-dev2
Implements the header/`--help` side of the changelog-consolidation rule
above (`script-maintenance-convention.md` section 3's new "Stable-only
header entries; consolidated in-progress entry" subsection): the header's
changelog window now shows stable versions only, one entry each; every
pre-release bump since the last stable release — including this one and
`1.1.6-dev1` before it — is merged into a single "in progress" entry there
instead of each getting its own header line. `CHANGELOG.md` itself is
unaffected by this - every bump, pre-release included, still gets its own
entry here, as this one does.

## 1.1.6-dev1
Implements the repo-wide maintenance conventions from
`docs/requirements/generic/script-maintenance-convention.md`:
1. `--help` is now layered — bare `--help` shows this script's own options
   only, `--help upgrade` shows only the self-upgrade options, `--help full`
   shows both (self-upgrade options always last).
2. The full version history moved to this file, newest entry first — the
   script's header now keeps only the 3 most recent entries, most recent in
   full.
3. The version-bump scheme changed: a suffixed version increments its
   trailing revision number (e.g. `-dev1` → `-dev2`); a bare version bumps
   the patch and starts a fresh `-dev1` cycle instead of landing on another
   bare version directly. This is the first version bumped under the new
   scheme.
4. The self-upgrade version comparison (`upgrade_version_level`/
   `upgrade_version_gt`) now strips a trailing revision number before
   computing level, and uses that number as a final tiebreaker when `X.Y.Z`
   and level are both equal — so consecutive same-patch pre-release tags
   (e.g. `1.2.3-dev1` → `1.2.3-dev2`) are actually recognized as upgrades;
   previously they were not ordered at all (both reduced to the same bare
   `X.Y.Z` for comparison purposes). Fixed alongside this:
   `upgrade_parse_versions` no longer discards a discovered tag's suffix
   down to bare `X.Y.Z`, which had been silently breaking the
   download/hash-fetch URLs for any pre-release tag (they need the exact
   suffixed tag name, e.g. `v1.0.8-beta`, not just `v1.0.8`).

## 1.1.5
`--help` visually separates this script's own options from the self-upgrade
options (which upgrade the script file itself, not any container image)
under two labeled groups instead of one flat list.

## 1.1.4
Fixed a self-upgrade hang in "overwrite"/"memory" apply modes: the candidate
was run as `bash -c "$content" -- "$@"`, which makes the literal string `--`
the candidate's `$0`; the candidate's own version-detection `grep ... "$0"`
then saw a trailing `--` with no filename after it, which GNU grep treats as
"end of options" and falls back to reading stdin — blocking forever with no
output at all, before anything is ever printed. Fixed by passing `/dev/null`
as `$0` instead.

## 1.1.3
Added a restart-policy safety step around both restart strategies: a
container whose restart policy is "always" is relaxed to "unless-stopped"
right before it's stopped, and restored to "always" once the container
ending up under the original name starts back up (or, in safe mode's
fail-no-rollback path, restored on the stopped container left aside for
manual recovery, since it never restarts). Without this, a container sitting
stopped mid-upgrade (safe mode can leave one renamed-aside for the whole
`--timeout` window) stays exposed to the engine's daemon/service restarting
and bringing it back up on its old image out from under the upgrade — an
explicit stop alone does not disable "always" the way it does
"unless-stopped". Best-effort: a failure to relax or restore (e.g. an
engine/version — some Podman releases — without `update --restart` support)
never blocks or rolls back the actual upgrade, but is reported as its own
error category in the summary with the specific detail of what failed.

## 1.1.2
Fixed a real bug in 1.1.0's content-hash check that made every self-upgrade
fail with a false "content hash mismatch": the download was captured via
plain `content=$(curl ...)`, and command substitution silently strips
trailing newlines, so the hash was computed over one byte fewer than what
the release-tag hook (which hashes `git show`'s output directly) actually
declared — deterministic, on every check, regardless of how healthy the
release was. Fixed by having the download carry a trailing sentinel byte
through the capture, stripped back off before hashing. Also added
persist-time re-verification: for replacement/overwrite/link (not memory),
the actual on-disk bytes are hashed again, directly off the file, immediately
before they're committed as the live script — a defense-in-depth check
independent of the download-time one, catching a write-time corruption the
way the original check could not by construction. A mismatch there is
reported the same way a failed persist already was (post-trial, for
replacement/overwrite) or as a pre-trial `hash_mismatch` banner note (link,
which persists before its trial run).

## 1.1.1
The startup banner now also notes when the check was skipped under the
cooldown cache ("upgrade not checked: cooldown active") and when a check ran
but found nothing newer ("no upgrade available") — previously both printed a
bare banner indistinguishable from self-upgrade being disabled outright,
which now remains the only bare-banner case. Separately, since a trial run
succeeding doesn't guarantee the persist step after it succeeds too (e.g.
the replacement `mv`, or the overwrite rewrite, can still fail on its own),
that outcome is now reported in its own line after the trial run's output
("upgrade to vX.Y.Z applied (mode)" / "... failed to persist (mode):
`<reason>` - will retry next run") — it never changes this invocation's
exit code, which still reflects only the trial run's own result.

## 1.1.0
Self-update rebuilt as self-upgrade per the repo-wide script-upgrade
convention (renamed from script-autoupdate-convention): the header's
`Update-Source:` line is now `Upgrade-Source:`. Upgrading is now on by
default every run (unless `--upgrade-type none` / `--no-autoupdate`), with
four apply modes tried strongest-to-weakest based on what the filesystem
actually allows — replacement (temp file + `mv`), overwrite (rewrite the
file in place when its directory isn't writable), link (a copy under
`${XDG_CACHE_HOME:-$HOME/.cache}/scripts-upgrade/` when neither is writable,
reused directly on a cache-hash match without re-downloading), and memory
(never persisted) — each capped by `--upgrade-type` if given. Release-channel
selection is now level-aware (dev/alpha/beta/rc/stable) via
`--upgrade-level`, defaulting to the running version's own level. Applying an
upgrade now trial-runs the candidate for real (this invocation's actual
container work) before persisting it — only a successful run gets kept; a
failed trial is this invocation's own failure, not retried under the old
version. New `--upgrade-check` (report what would happen and exit, no
download) and `--upgrade-only` (perform the upgrade and exit, skipping
container work) entry points. The 24h cooldown cache is now 20 minutes and
only gates a fully implicit invocation — any explicit upgrade-related flag
always checks fresh, so `--force-update-check` is removed as redundant.

## 1.0.9
Downloaded update is now also checked, best-effort, against the content-hash
prefix declared in its release tag's message (see the repo-wide
release-tag-hook and script-autoupdate conventions): a mismatch falls back to
the already-loaded version the same way a parse failure does. An unreachable
check, a tag with no hash prefix (e.g. one made before this existed), or no
local sha1sum/shasum is not treated as a failure — the update proceeds as if
the check had passed.

## 1.0.8
Added self-update support per the repo-wide script-autoupdate convention: on
every non-help invocation (unless `--no-autoupdate`), checks
github.com/jnitecki/scripts for a newer `bash/container-upgrade/vX.Y.Z` tag,
and if found, downloads and (after a syntax-only validation) applies it — in
place with a re-exec when the script's own file is writable, otherwise
running the fetched version from memory for this invocation only. Any
failure at any stage falls back to continuing with the already-loaded
version and is reported in the startup banner; it never aborts the run or
affects the exit code. Checks are cached for 24h per
`${XDG_CACHE_HOME:-$HOME/.cache}/scripts-autoupdate/`, bypassable with
`--force-update-check`.

## 1.0.7
Made bash-3.2-safe per the repo-wide cross-platform-shell-compatibility
requirement (macOS's stock `/bin/bash` is 3.2): replaced all `declare -A`
associative arrays with a portable `map_*` emulation, replaced both
`mapfile` calls with plain while-read loops, and replaced `${arr[@]}`
expansions of arrays that can legitimately be empty (`VALID_CONTAINERS`,
`ATTEMPTED_ORDER`) with the `${arr[@]+"${arr[@]}"}` form, since bash 3.2's
`set -u` treats expanding an empty array as an unbound-variable error.

## 1.0.6
Header updated to conform to the repo-wide script-header convention
(separate Version/Category/Description lines in place of the old inline
"container-upgrade.sh - vX.Y.Z" line); version is now parsed from the
`# Version:` line.

## 1.0.5
Unrecognized options (e.g. a typo'd flag) are now rejected immediately with
a clear error instead of silently being treated as a container name; a
container name that doesn't actually exist is now also reported clearly
instead of crashing later with a bash "bad array subscript" error.

## 1.0.4
Separated "upgraded" (image actually changed) from "restarted" (no image
change, only recreated because of `--restart-all`) in both the summary and
the status list, instead of reporting both as "upgraded successfully".

## 1.0.3
Added `--recent-restart-threshold`: a fast, no-wait pre-check using
RestartCount and the container's most recent (re)start time (not original
creation time) to catch crash loops slower than `--precheck-seconds`, plus
detection of a healthcheck stuck in "starting" past the same threshold.

## 1.0.2
Renamed from `docker-update-containers.sh`; version is now read from this
header comment at runtime instead of being duplicated in a separate
variable, so the two can't drift.

## 1.0.1
Exit code reflects whether any errors occurred (1 if so, 0 if the run was
clean).

## 1.0.0
Crash detection, pre/post classification, shared-image handling, summary
report, colored error visibility, versioning.
