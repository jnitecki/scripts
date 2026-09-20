#!/usr/bin/env bash
# Version: 1.1.7-dev3
# Category: containers
# Description: Docker image upgrade automation with rollback support
# Upgrade-Source: github.com/jnitecki/scripts@bash/container-upgrader
#
# HELP:IDENTITY:BEGIN
# Version history (bump per docs/requirements/generic/script-maintenance-
# convention.md section 4 on every change). This window shows STABLE
# versions only, one entry each, newest first, most recent in full - see
# CHANGELOG.md in this same directory for the complete history, including
# every individual pre-release entry. If a pre-release cycle is ever in
# progress, the "most recent" slot instead becomes a single consolidated
# entry for the whole in-progress cycle (every pre-release bump since the
# last stable release, merged into one) until promoted back to stable -
# see script-maintenance-convention.md section 3:
#   1.1.7 (in progress - currently 1.1.7-dev3) - adds manual systemd-unit-
#           managed restart support: a container can now opt into the same
#           systemctl-based restart Podman Quadlet gets automatically, via a
#           manual `systemd.unit` label (checked before PODMAN_SYSTEMD_UNIT).
#           Restart scope (--user vs. system) is now resolved per container
#           via a new `systemd.scope` label plus engine rootless/rootful
#           introspection (`podman`/`docker info`), fixing a latent gap in
#           the existing Quadlet path too - it previously hardcoded --user
#           unconditionally, correct only for the common rootless case.
#           Three new outcomes (systemd_unit_scope_mismatch/_not_found/
#           _permission_denied) leave a container fully untouched - no
#           systemctl attempt, no fallback to simple/safe - whenever the
#           script already knows in advance that it cannot safely restart it
#           via systemd. New `--skip-manual-unit-restart`/
#           `--skip-systemd-restart` options; `--skip-quadlet-restart` is
#           unchanged but now scoped to only the PODMAN_SYSTEMD_UNIT trigger.
#           Fixed: get_run_command diffed workdir/env/labels/entrypoint/cmd
#           against the NEW (already-pulled) image instead of the ORIGINAL
#           one the container was created from, so a value only ever
#           inherited from the old image's own default (never explicitly
#           set) looked like an override and got pinned forward - e.g. a
#           container that never set --entrypoint could get recreated with
#           `--entrypoint <old image's entrypoint path>`, which fails to
#           start if that path doesn't exist in the new image. Now diffed
#           against the original image; the safe-mode config check
#           (normalized_config) was updated the same way so a legitimately
#           inherited new-image default no longer looks like drift and
#           triggers a spurious rollback.
#           Fixed: image-pull failures were logged to a fixed, predictable
#           /tmp/pull_output.log shared across every user and run, which
#           could fail outright with "Permission denied" if a prior run
#           left it owned by another user, and was a symlink-race risk in
#           world-writable /tmp besides. Each pull now logs to its own
#           mktemp-generated file, reported by its actual path in the
#           failure message.
#   1.1.6 - implements the repo-wide maintenance conventions from
#           script-maintenance-convention.md (layered --help, CHANGELOG.md,
#           the numbered-suffix versioning scheme) plus several real bugs
#           found and fixed along the way; see CHANGELOG.md for detail.
#   1.1.5 - --help visually separates this script's own options from the
#           self-upgrade options under two labeled groups.
# HELP:IDENTITY:END
#
# HELP:INTRO:BEGIN
# Iterates running containers, groups them by image, pulls each unique
# image once, and for every container whose image actually changed (or
# every container if --restart-all is given) recreates it with the same
# settings using one of two strategies:
#
#   simple  - stop, remove, run new container under the original name.
#             Fast, but there is a window with no container running, and
#             no automatic rollback if the new image is broken.
#
#   safe    - stop old container, rename it out of the way, start the new
#             container under the original name, compare its runtime
#             config against the original (catches flags the run-command
#             reconstruction missed), then monitor it for --timeout
#             seconds. If everything checks out, remove the old (renamed)
#             container. If something fails AND the container was healthy
#             before the upgrade, roll back: stop/remove the failed new
#             container, rename the old one back, start it. If the
#             container was already crashing before the upgrade, it is
#             NOT rolled back even if it is still failing on the new
#             image (see --skip-crashing to opt out of attempting these
#             at all instead). A container started with --rm (AutoRemove)
#             is destroyed the instant it stops, which this rollback
#             cannot survive - such containers are handled via "simple"
#             instead, automatically, per container.
#
# Before touching anything, each targeted container is checked for
# --precheck-seconds to see whether it is already crashing. This
# pre-upgrade status, plus a post-upgrade check, drives both the
# rollback policy above and the final summary report.
#
# After stopping a container (either strategy), both wait up to
# --external-restart-wait seconds to see whether something else - a
# systemd/Quadlet unit, another supervisor, a human - already restarted
# or recreated it. If so, neither strategy's own rename/remove/run steps
# run at all; the outcome is classified instead (upgraded/reverted/config
# mismatch) - see --help full for details.
#
# A container owned by a systemd unit - either Podman Quadlet (via its
# automatic PODMAN_SYSTEMD_UNIT label) or a hand-written unit (via a manual
# systemd.unit label, checked first) - skips flag reconstruction and direct
# stop/rename/run entirely: instead its owning unit is restarted via
# `systemctl [--user] restart`, then validated the same way (running again,
# on the new image, within --external-restart-wait seconds). Restart scope
# (--user vs. system) is resolved per container from an optional
# systemd.scope label plus engine rootless/rootful introspection; if the
# script determines it cannot safely restart the unit (a declared scope
# that doesn't match reality, a unit that doesn't exist at the resolved
# scope, or a system-scope restart with no permission to attempt it), the
# container is left completely untouched - no fallback restart is
# attempted, unlike an ordinary systemctl failure or timeout, which still
# falls through to the normal simple/safe restart below. See
# --skip-quadlet-restart/--skip-manual-unit-restart/--skip-systemd-restart
# to opt out, and --help full for the exact resolution algorithm.
#
# Requires: docker (or podman, see --engine) and jq. The run command for
# each container is reconstructed locally from `<engine> inspect` JSON
# (no external image or socket-mounted helper needed). curl is used for the
# optional self-update check (see --help upgrade or --help full for
# details); its absence only disables that check, it does not stop the
# script from running.
#
# Reconstruction covers: name, hostname (if overridden), user, workdir
# (if overridden), env vars (only those added/changed vs. the image
# default), labels (added/changed vs. image default), published ports,
# bind/volume/tmpfs mounts, network mode (if non-default), restart
# policy, privileged, cap-add/cap-drop, devices, extra hosts, memory
# limit, cpu limit, security-opt, dns, tty/stdin flags, entrypoint
# override (first element only - see note below), and cmd (if
# overridden). Workdir/env/labels/entrypoint/cmd are diffed against the
# ORIGINAL image the container was created from, not the new image being
# upgraded to - so a value only ever inherited from the old image's
# default (never explicitly set) is left out, and the new container picks
# up the new image's own default for it instead of getting pinned to a
# stale value that may not even be valid on the new image (e.g. an
# entrypoint script path that moved between versions).
#
# Known limitations of the reconstruction (the safe-mode config check
# exists specifically to catch these before they cause silent drift):
#   - If the original container's Entrypoint has more than one element
#     (e.g. ["/bin/sh","-c"]), only the first element is reproduced via
#     --entrypoint.
#   - Only the primary network is captured, not additional networks a
#     container was attached to after creation.
#   - ulimits, sysctls, health checks, ipc/pid/uts/userns mode,
#     shm-size, init, group-add, dns-search, readonly-rootfs are not
#     reproduced by get_run_command (but ARE checked by the config
#     comparison in safe mode, so drift here is detected and rolled
#     back rather than silently applied).
# HELP:INTRO:END
#
# HELP:USAGE:BEGIN
# Usage:
#   ./container-upgrader.sh [options] [container names...]
# HELP:USAGE:END
#
# HELP:CORE-OPTIONS:BEGIN
# Options:
#   --restart-all       Recreate every targeted container regardless of
#                        whether its image actually changed.
#   --mode simple|safe  Restart strategy (default: safe).
#   --timeout N         Seconds to monitor the new container after
#                        starting it (default: 30).
#   --precheck-seconds N  Seconds to observe a container before touching
#                        it, to determine whether it is already crashing
#                        (default: 5). This is a live fallback poll; see
#                        --recent-restart-threshold for the faster check
#                        that runs first.
#   --recent-restart-threshold N  Before the live --precheck-seconds
#                        poll, check RestartCount and the timestamp of
#                        the container's most recent (re)start (not its
#                        original creation time). If it has restarted at
#                        least once and that restart happened within the
#                        last N seconds, or it has a healthcheck stuck in
#                        "starting" for longer than N seconds (readiness
#                        never reached), it's flagged as crashing
#                        immediately - no waiting required. Catches
#                        crash loops slower than --precheck-seconds that
#                        a live-only check could land between and miss.
#                        Default: 180 (3 minutes).
#   --external-restart-wait N  After stopping a container, seconds to wait
#                        to see whether something other than this script
#                        (systemd/Quadlet, another supervisor, a human)
#                        restarts or recreates it on its own, before
#                        falling through to the normal manual restart.
#                        Default: 15.
#   --skip-quadlet-restart  Do not use the systemctl restart path for a
#                        container carrying Podman's automatic
#                        PODMAN_SYSTEMD_UNIT label; manage it like any
#                        other container instead. A manual systemd.unit
#                        label still triggers the systemctl path unless
#                        --skip-manual-unit-restart or
#                        --skip-systemd-restart is also set. Default: off.
#   --skip-manual-unit-restart  Do not use the systemctl restart path for
#                        a container whose only trigger is a manual
#                        systemd.unit label; a PODMAN_SYSTEMD_UNIT label
#                        still triggers it. Default: off.
#   --skip-systemd-restart  Do not use the systemctl restart path at all,
#                        for either trigger. See --help full for the
#                        systemd.unit/systemd.scope labels and the scope-
#                        resolution algorithm. Default: off.
#   --skip-crashing     Do not attempt to upgrade containers detected as
#                        already crashing before the upgrade. Default is
#                        to attempt them anyway (see policy above).
#   --engine docker|podman  Container engine to use. If omitted, auto-detects:
#                        docker if present, else podman, else errors out.
#   --skip-config-check In safe mode, skip comparing the recreated
#                        container's runtime config against the original.
#                        Use if a specific container reliably shows a
#                        diff you've already verified is harmless.
#   --dry-run           Show what would happen, take no action, and skip
#                        the health-outcome summary (nothing was run).
# HELP:CORE-OPTIONS:END
#
# HELP:UPGRADE-OPTIONS:BEGIN
# Self-upgrade options (this script updating its own file - see
# "Self-upgrade" below; unrelated to upgrading container images, which is
# this script's own separate, unrelated purpose):
#   --upgrade-type replacement|overwrite|link|memory|none
#                        Caps which self-upgrade apply mode is attempted
#                        (falls back to a weaker mode automatically if the
#                        requested one isn't possible on this filesystem);
#                        "none" disables self-upgrade entirely. Default:
#                        unset (tries replacement first, cascading down).
#                        Not combinable with --upgrade-check or
#                        --no-autoupdate.
#   --upgrade-level dev|alpha|beta|rc|stable
#                        Minimum release channel eligible for self-upgrade.
#                        Default: unset (this script's own level - i.e.
#                        same-or-higher than what's currently running).
#   --upgrade-check      Report what a self-upgrade would do (and which
#                        apply mode this filesystem supports) and exit -
#                        no download, no change made. Not combinable with
#                        --upgrade-type or --upgrade-only.
#   --upgrade-only       Perform the self-upgrade check and, if eligible,
#                        the upgrade itself, then exit without doing any
#                        container work. Not combinable with
#                        --upgrade-check.
#   --no-autoupdate      Shortcut for --upgrade-type none: skip self-upgrade
#                        entirely for this run. Not combinable with
#                        --upgrade-type.
# HELP:UPGRADE-OPTIONS:END
#
# HELP:TAIL:BEGIN
# If no container names are given, all running containers are targeted.
# HELP:TAIL:END
#
# HELP:UPGRADE-EXPLANATION:BEGIN
# Self-upgrade: on every invocation other than --help (and unless
# --upgrade-type none / --no-autoupdate is given), the script checks
# github.com/jnitecki/scripts for a newer release of itself and, if
# eligible, upgrades - see CHANGELOG.md's 1.1.0-1.1.2 entries for the full
# behavior (apply modes, --upgrade-level, --upgrade-check, --upgrade-only).
# A successful upgrade actually runs this invocation's real container work
# under the new version before persisting anything; that new version's own
# startup line is what you see, noting it self-upgraded. This never aborts
# the run on its own and never changes the exit code beyond what the real
# work itself determines. The startup line always reports the upgrade-check
# outcome - checked and nothing newer, skipped under the cooldown, or a
# failed check - except when self-upgrade is disabled outright, the one
# case with no note at all. After a successful trial run, one further line
# reports whether persisting it (separately from running it) also
# succeeded.
# HELP:UPGRADE-EXPLANATION:END
#
# HELP:OUTPUT:BEGIN
# Output: errors (failed pulls, failed reconstructions, failed starts,
# config mismatches, rollbacks, and any container ending up still broken)
# are printed in red/bold when the terminal supports color. If any
# occurred, the very last line of output is "ERRORS OCCURRED - REVIEW
# THE OUTPUT" in caps, also colored.
# HELP:OUTPUT:END

set -uo pipefail

MODE="safe"
TIMEOUT=30
PRECHECK_SECONDS=5
RECENT_RESTART_THRESHOLD=180
EXTERNAL_RESTART_WAIT=15
SKIP_QUADLET_RESTART=false
SKIP_MANUAL_UNIT_RESTART=false
SKIP_SYSTEMD_RESTART=false
ENGINE=""
ENGINE_EXPLICIT=false
RESTART_ALL=false
SKIP_CONFIG_CHECK=false
SKIP_CRASHING=false
DRY_RUN=false
NO_AUTOUPDATE=false
UPGRADE_TYPE=""
UPGRADE_LEVEL=""
UPGRADE_CHECK=false
UPGRADE_ONLY=false
TARGETS=()

# Version lives only in the header comment above (line 2: "# Version: X.Y.Z"
# or "# Version: X.Y.Z-<level><N>", N a trailing revision number per
# docs/requirements/generic/script-maintenance-convention.md section 4, e.g.
# "1.1.6-dev1"). Read it from here rather than duplicating it in a
# variable, so the two can never drift out of sync. Falls back to "unknown"
# if the header is ever restructured and the pattern no longer matches.
version_line=$(grep -m1 -E '^# Version: [0-9]+\.[0-9]+\.[0-9]+(-[a-z]+[0-9]*)?$' "$0" 2>/dev/null || true)
SCRIPT_VERSION="${version_line##*: }"
[[ -z "$SCRIPT_VERSION" ]] && SCRIPT_VERSION="unknown"
HAD_ERRORS=false

# Identity used by the self-upgrade block below (see
# docs/requirements/generic/script-upgrade-convention.md) - matches this
# script's own "# Upgrade-Source:" header line and its path under platforms/.
SCRIPT_PATH="$0"
SCRIPT_LANG="bash"
SCRIPT_NAME="container-upgrader"
UPGRADE_HOST="github.com"
UPGRADE_OWNER="jnitecki"
UPGRADE_REPO="scripts"
UPGRADE_TIMEOUT=10
UPGRADE_COOLDOWN_SECONDS=1200
UPGRADE_BANNER_NOTE=""

# Color support: only enable if stderr (where log()/err() write) is an
# actual terminal that reports at least 8 colors. Falls back to plain
# text automatically when piped, redirected to a file, or run in a
# terminal without color support.
if [[ -t 2 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  COLOR_RED=$(tput setaf 1)
  COLOR_BOLD=$(tput bold)
  COLOR_RESET=$(tput sgr0)
else
  COLOR_RED=""
  COLOR_BOLD=""
  COLOR_RESET=""
fi

# Writes to stderr, not stdout. Several functions (check_pre_status,
# monitor_container) are called via command substitution to capture a
# real return value on stdout (e.g. "healthy"/"crashing"); if log() wrote
# to stdout, its messages would contaminate that captured value.
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }

# Same as log(), but colored red/bold when the terminal supports it, and
# sets a flag that triggers the "ERRORS OCCURRED" banner at the very end
# of the run. Use for anything that represents a real problem: failed
# pulls, failed reconstructions, failed starts, config mismatches,
# rollbacks, and any container ending up in a still-broken state.
err() {
  HAD_ERRORS=true
  echo "${COLOR_RED}${COLOR_BOLD}[$(date '+%Y-%m-%d %H:%M:%S')] $*${COLOR_RESET}" >&2
}

# ---------------------------------------------------------------------------
# Portable key/value map emulation (bash 3.2 has no associative arrays)
# ---------------------------------------------------------------------------
#
# macOS ships bash 3.2 as /bin/bash (see
# docs/requirements/generic/cross-platform-shell-compatibility.md), which
# has no `declare -A`. A "map" here is emulated as a set of ordinary
# scalar variables, one per key, named `__map_<map-name>_<hex-encoded-key>`
# plus a same-named `_ISSET` marker, and a `__mapkeys_<map-name>` variable
# holding a newline-separated list of keys in insertion order. Keys are
# hex-encoded so arbitrary container/image names (colons, slashes, dots)
# are always safe to embed in a variable name. All reads/writes go through
# `printf -v` and indirect expansion (`${!ref}`) - never `eval` - so there
# is no command-injection risk from container/image names or other
# inspected values.

# Hex-encodes $1 so it only contains [0-9a-f], safe to use as part of a
# bash variable name regardless of what characters the original key has.
map_key_encode() {
  local s="$1" out="" i c
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    out+=$(printf '%02x' "'$c")
  done
  printf '%s' "$out"
}

# True (exit 0) if <key> has been set in map <name>.
map_has() {
  local name="$1" key="$2" enc setvar
  enc=$(map_key_encode "$key")
  setvar="__map_${name}_${enc}_ISSET"
  [[ "${!setvar:-}" == "1" ]]
}

# Sets map <name>'s <key> to <value>, recording new keys in that map's
# insertion-order key list the first time they're seen.
map_set() {
  local name="$1" key="$2" val="$3" enc slotvar setvar keysvar existing
  enc=$(map_key_encode "$key")
  slotvar="__map_${name}_${enc}"
  setvar="__map_${name}_${enc}_ISSET"
  if [[ "${!setvar:-}" != "1" ]]; then
    keysvar="__mapkeys_${name}"
    existing="${!keysvar:-}"
    if [[ -z "$existing" ]]; then
      printf -v "$keysvar" '%s' "$key"
    else
      printf -v "$keysvar" '%s\n%s' "$existing" "$key"
    fi
    printf -v "$setvar" '%s' "1"
  fi
  printf -v "$slotvar" '%s' "$val"
}

# Prints map <name>'s value for <key>, or an empty string if unset -
# matches the behavior of reading an unset bash associative-array key.
map_get() {
  local name="$1" key="$2" enc slotvar
  enc=$(map_key_encode "$key")
  slotvar="__map_${name}_${enc}"
  echo "${!slotvar:-}"
}

# Same as map_get, but prints <default> instead of an empty string when
# <key> is unset or its value is itself empty - matches bash's
# `${arr[$key]:-default}` semantics.
map_get_default() {
  local name="$1" key="$2" default="$3" val
  val=$(map_get "$name" "$key")
  if [[ -z "$val" ]]; then
    printf '%s' "$default"
  else
    printf '%s' "$val"
  fi
}

# Prints every value in map <name>, one per line, in insertion order.
map_values() {
  local name="$1" keysvar keys key
  keysvar="__mapkeys_${name}"
  keys="${!keysvar:-}"
  [[ -z "$keys" ]] && return 0
  while IFS= read -r key; do
    map_get "$name" "$key"
  done <<< "$keys"
}

# =============================================================================
# Self-upgrade (docs/requirements/generic/script-upgrade-convention.md)
# begins - every function down to the matching "ends" banner belongs to this
# subsystem; nothing here is container-upgrader domain logic. Failures before
# a candidate is trial-run are swallowed and reported only via
# UPGRADE_BANNER_NOTE (section 9); a trial run's own failure is not
# swallowed - its exit code becomes this invocation's exit code (section 8).
# =============================================================================

# --- section 3: release levels ----------------------------------------------
upgrade_level_rank() {
  case "$1" in
    dev) printf '0' ;;
    alpha) printf '1' ;;
    beta) printf '2' ;;
    rc) printf '3' ;;
    stable) printf '4' ;;
    *) return 1 ;;
  esac
}

# args: $1="X.Y.Z" or "X.Y.Z-<level><N>" (N optional) -> prints the bare
# level word ("dev"/"alpha"/"beta"/"rc"), or "stable" if there is no suffix
# at all. Strips a trailing revision number
# (docs/requirements/generic/script-maintenance-convention.md section 4)
# before returning, so "dev12" and "dev" both report level "dev" - the
# number is a within-level tiebreaker (upgrade_version_number/
# upgrade_version_gt below), never part of the level name itself.
upgrade_version_level() {
  case "$1" in
    *-*)
      local suffix="${1#*-}" word
      word="${suffix%%[0-9]*}"
      printf '%s' "$word"
      ;;
    *) printf 'stable' ;;
  esac
}

# args: $1="X.Y.Z" or "X.Y.Z-<level><N>" -> prints the trailing revision
# number N as a plain integer (e.g. "12" for "...-rc12"), or "0" if the
# suffix has no trailing digits (including no suffix at all, i.e. stable).
upgrade_version_number() {
  case "$1" in
    *-*)
      local suffix="${1#*-}" word n
      word="${suffix%%[0-9]*}"
      n="${suffix#$word}"
      printf '%s' "${n:-0}"
      ;;
    *) printf '0' ;;
  esac
}

# --- numeric major.minor.patch comparison (no `sort -V` - BSD `sort` lacks -
# it, see cross-platform-shell-compatibility.md), with level+number as a ---
# tiebreaker when X.Y.Z is equal (script-maintenance-convention.md section --
# 4): 1.2.3-dev1 < 1.2.3-dev2 < 1.2.3-rc1 < 1.2.3 (stable) < 1.2.4-dev1. ----
# Pure ordering only - does NOT enforce the separate eligibility gate
# (upgrade_highest_at_level's min-level filter) that keeps e.g. a running
# stable 1.2.3 from ever treating 1.2.4-beta1 as a candidate at all; that
# gate runs first, before this function is ever asked to compare anything.
upgrade_version_gt() {
  local a1 a2 a3 b1 b2 b3 rest
  a1=${1%%.*}; rest=${1#*.}; a2=${rest%%.*}; a3=${rest#*.}; a3=${a3%%-*}
  b1=${2%%.*}; rest=${2#*.}; b2=${rest%%.*}; b3=${rest#*.}; b3=${b3%%-*}
  [[ "$a1" -gt "$b1" ]] && return 0
  [[ "$a1" -lt "$b1" ]] && return 1
  [[ "$a2" -gt "$b2" ]] && return 0
  [[ "$a2" -lt "$b2" ]] && return 1
  [[ "$a3" -gt "$b3" ]] && return 0
  [[ "$a3" -lt "$b3" ]] && return 1
  local la lb ra rb
  la=$(upgrade_version_level "$1"); ra=$(upgrade_level_rank "$la") || ra=-1
  lb=$(upgrade_version_level "$2"); rb=$(upgrade_level_rank "$lb") || rb=-1
  [[ "$ra" -gt "$rb" ]] && return 0
  [[ "$ra" -lt "$rb" ]] && return 1
  [[ "$(upgrade_version_number "$1")" -gt "$(upgrade_version_number "$2")" ]]
}

# --- section 3: discover every matching tag, no `git` required -------------
upgrade_fetch_tags_json() {
  local owner="$1" repo="$2" lang="$3" name="$4"
  curl -fsS --max-time "$UPGRADE_TIMEOUT" \
    "https://api.github.com/repos/${owner}/${repo}/git/matching-refs/tags/${lang}/${name}/v"
}

# args: $1=json $2=lang $3=name -> prints "version level" pairs, one per
# discovered tag, one per line. `version` is the tag's full version string,
# suffix (and revision number) included - it is NOT reduced to bare X.Y.Z
# here, unlike an earlier version of this script: doing so silently
# discarded the suffix before it ever reached upgrade_download/
# upgrade_fetch_tag_hash (both need the exact tag string, e.g. "1.0.8-beta",
# to build a correct `v<version>` URL) and made two same-X.Y.Z pre-release
# tags indistinguishable to upgrade_highest_at_level (see upgrade_version_gt's
# level+number tiebreak above, which only works if the full string survives
# this far). `[^"]*` (rather than an optional-group regex like `\?`/
# `\{0,1\}`, a GNU sed extension BSD sed lacks) captures the version plus
# its optional -suffix in one go.
upgrade_parse_versions() {
  local json="$1" lang="$2" name="$3" refs r
  refs=$(printf '%s\n' "$json" \
    | sed -n 's/.*"ref": *"refs\/tags\/'"${lang}"'\/'"${name}"'\/v\([^"]*\)".*/\1/p')
  for r in $refs; do
    printf '%s %s\n' "$r" "$(upgrade_version_level "$r")"
  done
}

# args: $1=owner $2=repo $3=lang $4=name -> prints "version level" pairs for
# every discovered tag (one fetch); nothing + return 1 on failure. Callers
# needing more than one filtered view (--upgrade-check's three lines) call
# this once and reuse the result with upgrade_highest_at_level, rather than
# re-fetching.
upgrade_discover() {
  local owner="$1" repo="$2" lang="$3" name="$4" json
  json=$(upgrade_fetch_tags_json "$owner" "$repo" "$lang" "$name") || return 1
  upgrade_parse_versions "$json" "$lang" "$name"
}

# args: $1=multiline "version level" pairs (as from upgrade_discover)
#       $2=minimum level name
# -> prints the highest version (full string, suffix included - see
# upgrade_version_gt) at or above that level, or nothing if none qualify.
upgrade_highest_at_level() {
  local versions="$1" min_level="$2" min_rank
  min_rank=$(upgrade_level_rank "$min_level") || return 1
  local best="" v level rank
  while IFS=' ' read -r v level; do
    [[ -z "$v" ]] && continue
    rank=$(upgrade_level_rank "$level") || continue
    [[ "$rank" -ge "$min_rank" ]] || continue
    if [[ -z "$best" ]] || upgrade_version_gt "$v" "$best"; then
      best="$v"
    fi
  done <<<"$versions"
  [[ -n "$best" ]] && printf '%s' "$best"
}

# --- section 6: apply-mode capability probe ---------------------------------
upgrade_mode_rank() {
  case "$1" in
    replacement) printf '0' ;;
    overwrite) printf '1' ;;
    link) printf '2' ;;
    memory) printf '3' ;;
    *) return 1 ;;
  esac
}

# args: $1=mode $2=script_path $3=cache_dir -> 0 if that mode's filesystem
# precondition holds right now.
upgrade_mode_possible() {
  local mode="$1" script_path="$2" cache_dir="$3"
  case "$mode" in
    replacement) [[ -w "$(dirname "$script_path")" ]] ;;
    overwrite) [[ -w "$script_path" ]] ;;
    link) mkdir -p "$cache_dir" 2>/dev/null; [[ -w "$cache_dir" ]] ;;
    memory) return 0 ;;
    *) return 1 ;;
  esac
}

# args: $1=ceiling (""=uncapped, i.e. start at replacement) $2=script_path
#       $3=cache_dir
# -> prints the strongest mode reachable at or below the ceiling. Always
# resolves to at least "memory" (its precondition is unconditional).
upgrade_select_mode() {
  local ceiling="$1" script_path="$2" cache_dir="$3" start_rank m rank
  if [[ -n "$ceiling" ]]; then
    start_rank=$(upgrade_mode_rank "$ceiling") || start_rank=0
  else
    start_rank=0
  fi
  for m in replacement overwrite link memory; do
    rank=$(upgrade_mode_rank "$m")
    [[ "$rank" -ge "$start_rank" ]] || continue
    if upgrade_mode_possible "$m" "$script_path" "$cache_dir"; then
      printf '%s' "$m"
      return 0
    fi
  done
  printf 'memory'
}

# --- section 7: persistent cache (link mode) --------------------------------
upgrade_cache_dir() {
  printf '%s' "${XDG_CACHE_HOME:-$HOME/.cache}/scripts-upgrade/$1/$2"
}

upgrade_cache_file() {
  printf '%s/%s.sh' "$(upgrade_cache_dir "$1" "$2")" "$2"
}

# args: $1=file path -> prints the version declared in that file's own
# "# Version: X.Y.Z[-<level><N>]" header line (same pattern used to parse
# $SCRIPT_VERSION near the top of this file), or nothing + return 1 if the
# file doesn't exist or its header doesn't match. Used to read an
# already-cached candidate's version (section 7) locally, with no network
# round-trip - see upgrade_prepare_cached_candidate below.
upgrade_file_version() {
  local file="$1" line
  line=$(grep -m1 -E '^# Version: [0-9]+\.[0-9]+\.[0-9]+(-[a-z]+[0-9]*)?$' "$file" 2>/dev/null) || return 1
  printf '%s' "${line##*: }"
}

# --- section 5: download the candidate + syntax-only validation ------------
# Prints a trailing sentinel byte (0x01, never legitimately part of a bash
# script's source) after the downloaded content so a caller capturing this
# via `content=$(upgrade_download ...)` - which otherwise silently strips
# every trailing newline, command substitution's documented behavior - can
# recover the byte-exact original by stripping just that sentinel back off
# (`"${content%$'\x01'}"`). This matters because the release-tag hook
# computes its declared hash straight off `git show`'s output (trailing
# newline intact - see release-tag-hook.md); hashing a variable that lost
# that newline via `$(...)` produces a different value and permanently
# "fails" the check below even though nothing about the download is
# actually wrong - the exact "hook/tag desync" failure mode the convention
# doc's "Accepted risk" section anticipated, just self-inflicted by this
# side rather than the hook's. Exit status is curl's own, not `printf`'s.
upgrade_download() {
  local owner="$1" repo="$2" lang="$3" name="$4" version="$5" rc
  curl -fsS --max-time "$UPGRADE_TIMEOUT" \
    "https://raw.githubusercontent.com/${owner}/${repo}/${lang}/${name}/v${version}/platforms/${lang}/${name}/${name}.sh"
  rc=$?
  printf '\x01'
  return "$rc"
}

# Syntax-only validation - not an integrity/authenticity check (see
# "Accepted risk" in the convention doc), just enough to satisfy the "fails
# parsing -> fall back" requirement.
upgrade_validate_parse() {
  bash -n <(printf '%s' "$1") 2>/dev/null
}

# --- section 5 (best-effort): content-hash match against the release tag ---

# args: $1=owner $2=repo $3=lang $4=name $5=version -> prints the tag's
# declared 12-hex-char hash prefix (see release-tag-hook.md), or nothing on
# any failure (unreachable, no [<hash>] prefix on the tag) - not fatal, the
# caller treats "nothing" as "skip the check".
upgrade_fetch_tag_hash() {
  local owner="$1" repo="$2" lang="$3" name="$4" version="$5"
  local ref_json tag_sha tag_json
  ref_json=$(curl -fsS --max-time "$UPGRADE_TIMEOUT" \
    "https://api.github.com/repos/${owner}/${repo}/git/refs/tags/${lang}/${name}/v${version}") || return 0
  tag_sha=$(printf '%s' "$ref_json" | sed -n 's/.*"sha": *"\([0-9a-f]*\)".*/\1/p' | head -n1)
  [[ -n "$tag_sha" ]] || return 0
  tag_json=$(curl -fsS --max-time "$UPGRADE_TIMEOUT" \
    "https://api.github.com/repos/${owner}/${repo}/git/tags/${tag_sha}") || return 0
  printf '%s' "$tag_json" | grep -oE '"message": *"\[[0-9a-f]{12}\]' | grep -oE '[0-9a-f]{12}' | head -n1
}

# args: $1=content -> prints the first 12 hex chars of its plain SHA-1, or
# nothing if neither sha1sum nor shasum is available locally.
upgrade_hash_prefix() {
  local content="$1" full
  if command -v sha1sum >/dev/null 2>&1; then
    full=$(printf '%s' "$content" | sha1sum | cut -d' ' -f1)
  elif command -v shasum >/dev/null 2>&1; then
    full=$(printf '%s' "$content" | shasum -a 1 | cut -d' ' -f1)
  else
    return 0
  fi
  printf '%s' "${full:0:12}"
}

# args: $1=file path -> prints the first 12 hex chars of its plain SHA-1,
# or nothing if neither sha1sum nor shasum is available, or the file can't
# be read. Hashes the file directly (no bash-variable round-trip), so -
# unlike upgrade_hash_prefix on a captured variable - there is no risk of
# command substitution silently stripping trailing newlines and skewing
# the result. Used to re-verify actual on-disk bytes right before they're
# committed as the live script (section 6's "Persist-time verification").
upgrade_hash_prefix_file() {
  local path="$1" full
  if command -v sha1sum >/dev/null 2>&1; then
    full=$(sha1sum "$path" 2>/dev/null | cut -d' ' -f1)
  elif command -v shasum >/dev/null 2>&1; then
    full=$(shasum -a 1 "$path" 2>/dev/null | cut -d' ' -f1)
  else
    return 0
  fi
  printf '%s' "${full:0:12}"
}

# args: $1=file path $2=expected 12-hex-char hash (may be empty - nothing
# to compare against, same "not fail-closed" treatment as the in-memory
# check) -> 0 if the file's on-disk hash matches (or there's nothing to
# verify), 1 on an actual computed mismatch.
upgrade_verify_disk_hash() {
  local path="$1" expected="$2" actual
  [[ -n "$expected" ]] || return 0
  actual=$(upgrade_hash_prefix_file "$path")
  [[ -z "$actual" || "$actual" == "$expected" ]]
}

# --- section 14: cooldown cache (implicit invocations only) ----------------
upgrade_cooldown_elapsed() {
  local cache_file="$1"
  [[ -f "$cache_file" ]] || return 0
  local last_checked now
  last_checked=$(sed -n '1p' "$cache_file" 2>/dev/null)
  [[ -z "$last_checked" || ! "$last_checked" =~ ^[0-9]+$ ]] && return 0
  now=$(date +%s)
  [[ $((now - last_checked)) -ge "$UPGRADE_COOLDOWN_SECONDS" ]]
}

# --- section 6: permission & ownership preservation -------------------------
# `chmod --reference`/`chown --reference` are GNU-only and fail silently
# under macOS's BSD chmod/chown (bash-3.2 target), so mode/owner/group are
# read via `stat` (GNU form tried first, BSD form as fallback - same
# GNU-then-BSD pattern as parse_to_epoch above for `date`) and re-applied
# explicitly instead.

# args: $1=path -> prints octal permission bits (e.g. "755", no file-type
# bits, no leading zero), or nothing on failure.
upgrade_stat_mode() {
  local path="$1"
  stat -c '%a' "$path" 2>/dev/null && return 0
  stat -f '%OLp' "$path" 2>/dev/null
}

# args: $1=path -> prints "owner:group" (names), or nothing on failure.
upgrade_stat_owner_group() {
  local path="$1"
  stat -c '%U:%G' "$path" 2>/dev/null && return 0
  stat -f '%Su:%Sg' "$path" 2>/dev/null
}

# args: $1=source_path (whose mode/ownership to copy) $2=target_path ->
# best-effort chmod+chown of target to match source (section 6's
# "Permission & ownership preservation"). Mode bits are always applied - an
# unprivileged owner can always set them on a file it owns; ownership is
# best-effort, since chown requires sufficient privilege (typically root)
# and fails silently otherwise - not treated as an upgrade failure, the same
# best-effort philosophy as sections 5/14.
upgrade_copy_mode_owner() {
  local source="$1" target="$2" mode owner_group
  mode=$(upgrade_stat_mode "$source")
  [[ -n "$mode" ]] && chmod "$mode" "$target" 2>/dev/null
  owner_group=$(upgrade_stat_owner_group "$source")
  [[ -n "$owner_group" ]] && chown "$owner_group" "$target" 2>/dev/null
  return 0
}

# --- section 6/8: persistence primitives (pure filesystem, no execution) ---

# args: $1=content $2=script_path -> writes a fresh temp file alongside
# script_path, carrying over its permissions and ownership (best-effort for
# ownership - see upgrade_copy_mode_owner); prints its path, or nothing +
# return 1 on failure.
upgrade_write_temp_sibling() {
  local content="$1" script_path="$2" tmp
  tmp=$(mktemp "${script_path}.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s' "$content" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  upgrade_copy_mode_owner "$script_path" "$tmp"
  printf '%s' "$tmp"
}

# args: $1=source_file $2=script_path -> byte-exact copy of source_file
# into a fresh temp file alongside script_path (same scheme as
# upgrade_write_temp_sibling), then carries over script_path's permissions
# and ownership. Used to promote an already-cached, already-validated
# candidate (section 7) straight to `replacement` without a lossy
# `content=$(cat ...)` round-trip through a bash variable - see
# upgrade_download's comment for why capturing file content into a variable
# is unsafe here (it would strip trailing newlines the same way a naive
# download capture does; going file-to-file via `cp` avoids that entirely).
# Prints the temp file's path, or nothing + return 1 on failure.
upgrade_write_temp_sibling_from_file() {
  local source_file="$1" script_path="$2" tmp
  tmp=$(mktemp "${script_path}.XXXXXX" 2>/dev/null) || return 1
  if ! cp "$source_file" "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  upgrade_copy_mode_owner "$script_path" "$tmp"
  printf '%s' "$tmp"
}

# args: $1=content -> writes content to a fresh file in a generic writable
# temp location (unlike upgrade_write_temp_sibling, not required to be
# next to script_path - "overwrite" mode's whole precondition is that
# script_path's own directory is *not* writable, so a sibling temp file
# isn't an option there). Used only to get real on-disk bytes to re-verify
# (upgrade_verify_disk_hash) before the actual overwrite commits. Prints
# the temp file's path, or nothing + return 1 on failure.
upgrade_write_temp_scratch() {
  local content="$1" tmp
  tmp=$(mktemp 2>/dev/null) || return 1
  if ! printf '%s' "$content" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  printf '%s' "$tmp"
}

# args: $1=temp_file $2=script_path -> the "replacement" persist step.
upgrade_persist_replacement() {
  mv -f "$1" "$2" 2>/dev/null
}

# args: $1=content $2=script_path -> the "overwrite" persist step (rewrites
# the existing, file-writable-but-not-directory-writable script in place).
# Unlike "replacement", this never creates a new inode - the shell
# redirection truncates and rewrites script_path's own existing file - so
# it already satisfies section 6's "Permission & ownership preservation"
# by construction, with no explicit chmod/chown needed. That guarantee only
# holds as long as the persist step writes directly to script_path this
# way; staging through some other intermediate file and swapping it in
# would need an explicit copy of script_path's original mode/ownership
# onto that replacement first.
upgrade_persist_overwrite() {
  printf '%s' "$1" > "$2" 2>/dev/null
}

# args: $1=source_file $2=script_path -> byte-exact "overwrite" persist
# from an already-on-disk file (no `content=$(cat ...)` round-trip through
# a variable - same rationale as upgrade_write_temp_sibling_from_file).
# Used to promote an already-cached candidate to `overwrite` mode. Same
# in-place, no-new-inode guarantee as upgrade_persist_overwrite above.
upgrade_persist_overwrite_from_file() {
  cat "$1" > "$2" 2>/dev/null
}

# args: $1=content $2=cache_file -> the "link" persist step: writes into the
# cache location (creating its directory), executable. This happens
# *before* the trial run (the candidate's own location is the cache file);
# upgrade_main removes it again if the trial then fails, so a broken
# version is never left cached.
upgrade_persist_link() {
  local content="$1" cache_file="$2" dir
  dir=$(dirname "$cache_file")
  mkdir -p "$dir" 2>/dev/null || return 1
  printf '%s' "$content" > "$cache_file" 2>/dev/null || return 1
  chmod +x "$cache_file" 2>/dev/null
}

# --- section 10: startup banner note text -----------------------------------
upgrade_banner_note() {
  case "$1" in
    not_checked)   printf ' (upgrade not checked: cooldown active)' ;;
    no_upgrade)    printf ' (no upgrade available)' ;;
    check_failed)  printf ' (upgrade check failed: %s)' "$2" ;;
    parse_failed)  printf ' (fetched v%s failed to parse - running v%s)' "$2" "$3" ;;
    hash_mismatch) printf ' (fetched v%s, content hash mismatch - running v%s)' "$2" "$3" ;;
    applying)
      case "$3" in
        replacement) printf ' (self-upgrading from v%s via replacement)' "$2" ;;
        overwrite)   printf ' (self-upgrading from v%s via overwrite)' "$2" ;;
        link)        printf ' (self-upgrading from v%s via link, running from cache)' "$2" ;;
        memory)      printf ' (self-upgrading from v%s via memory, this run only)' "$2" ;;
      esac
      ;;
  esac
}

# --- shared discovery+download+validate, used by both the ordinary flow ----
# and --upgrade-only. Sets (in the caller's scope, since bash 3.2 has no
# namerefs) UPGRADE_LATEST, UPGRADE_SELECTED_MODE, UPGRADE_CANDIDATE_CONTENT
# (empty on a link-mode cache hit - section 7), and UPGRADE_TAG_HASH (the
# winning tag's declared hash, possibly empty - reused by the caller for
# the persist-time on-disk re-verification, section 6, instead of
# re-fetching it) - returns 0 on a usable candidate. On any failure it sets
# UPGRADE_BANNER_NOTE and returns 1 - the caller must not trial-run or
# persist anything in that case.
upgrade_prepare_candidate() {
  UPGRADE_LATEST=""
  UPGRADE_SELECTED_MODE=""
  UPGRADE_CANDIDATE_CONTENT=""
  UPGRADE_TAG_HASH=""

  local versions
  if ! versions=$(upgrade_discover "$UPGRADE_OWNER" "$UPGRADE_REPO" "$SCRIPT_LANG" "$SCRIPT_NAME"); then
    UPGRADE_BANNER_NOTE=$(upgrade_banner_note check_failed "could not reach ${UPGRADE_HOST}")
    return 1
  fi

  local effective_level="${UPGRADE_LEVEL:-$(upgrade_version_level "$SCRIPT_VERSION")}"
  local latest
  latest=$(upgrade_highest_at_level "$versions" "$effective_level")
  if [[ -z "$latest" ]] || ! upgrade_version_gt "$latest" "$SCRIPT_VERSION"; then
    UPGRADE_BANNER_NOTE=$(upgrade_banner_note no_upgrade)
    return 1
  fi

  local cache_dir cache_file mode
  cache_dir=$(upgrade_cache_dir "$SCRIPT_LANG" "$SCRIPT_NAME")
  cache_file=$(upgrade_cache_file "$SCRIPT_LANG" "$SCRIPT_NAME")
  mode=$(upgrade_select_mode "$UPGRADE_TYPE" "$SCRIPT_PATH" "$cache_dir")

  local content="" skip_download=0
  if [[ "$mode" == "link" && -f "$cache_file" ]]; then
    local tag_hash cached_hash
    tag_hash=$(upgrade_fetch_tag_hash "$UPGRADE_OWNER" "$UPGRADE_REPO" "$SCRIPT_LANG" "$SCRIPT_NAME" "$latest")
    if [[ -n "$tag_hash" ]]; then
      # Hash the cache file directly (upgrade_hash_prefix_file), not via
      # `upgrade_hash_prefix "$(cat cache_file)"` - that used to round-trip
      # the content through a `$(...)` capture, which silently strips
      # trailing newlines and would skew this comparison the same way it
      # skewed the fresh-download check below (see upgrade_download).
      cached_hash=$(upgrade_hash_prefix_file "$cache_file")
      [[ "$cached_hash" == "$tag_hash" ]] && skip_download=1
      UPGRADE_TAG_HASH="$tag_hash"
    fi
  fi

  if [[ "$skip_download" != "1" ]]; then
    # upgrade_download appends a sentinel byte specifically so this capture
    # can recover the exact downloaded bytes, trailing newline included -
    # see that function's comment for why this matters.
    if ! content=$(upgrade_download "$UPGRADE_OWNER" "$UPGRADE_REPO" "$SCRIPT_LANG" "$SCRIPT_NAME" "$latest"); then
      UPGRADE_BANNER_NOTE=$(upgrade_banner_note check_failed "download failed")
      return 1
    fi
    content="${content%$'\x01'}"
    if ! upgrade_validate_parse "$content"; then
      UPGRADE_BANNER_NOTE=$(upgrade_banner_note parse_failed "$latest" "$SCRIPT_VERSION")
      return 1
    fi
    local tag_hash content_hash
    tag_hash=$(upgrade_fetch_tag_hash "$UPGRADE_OWNER" "$UPGRADE_REPO" "$SCRIPT_LANG" "$SCRIPT_NAME" "$latest")
    UPGRADE_TAG_HASH="$tag_hash"
    if [[ -n "$tag_hash" ]]; then
      content_hash=$(upgrade_hash_prefix "$content")
      if [[ -n "$content_hash" && "$content_hash" != "$tag_hash" ]]; then
        UPGRADE_BANNER_NOTE=$(upgrade_banner_note hash_mismatch "$latest" "$SCRIPT_VERSION")
        return 1
      fi
    fi
  fi

  UPGRADE_LATEST="$latest"
  UPGRADE_SELECTED_MODE="$mode"
  UPGRADE_CANDIDATE_CONTENT="$content"
  return 0
}

# --- section 2's cooldown clarification: local-only counterpart to ---------
# upgrade_prepare_candidate, used only when the cooldown (section 14) has
# suppressed a fresh remote check. No network calls at all - looks only at
# whatever already sits in the link-mode cache (section 7) from an earlier
# run, and at this run's own freshly-determined filesystem eligibility
# (section 6, always re-evaluated, never itself cached). Sets UPGRADE_LATEST
# and UPGRADE_SELECTED_MODE on success, mirroring upgrade_prepare_candidate's
# contract, but leaves UPGRADE_CANDIDATE_CONTENT and UPGRADE_TAG_HASH empty -
# the caller reads bytes straight from the cache file itself
# (upgrade_cache_file) via upgrade_write_temp_sibling_from_file /
# upgrade_persist_overwrite_from_file, never through a variable (same
# capture pitfall upgrade_download's comment describes for downloads), and
# there is no new download to re-verify a hash against (the cached bytes
# were already hash-validated when originally cached - section 7's own
# trust model). Returns 1 with UPGRADE_BANNER_NOTE left unset - this is not
# itself a failure, the caller's existing cooldown "not_checked" banner
# still applies - when there is nothing to promote: no cache file, its
# declared version isn't actually newer than $SCRIPT_VERSION, it's below
# the effective level, or this run's mode hasn't actually escalated past
# `link` (still `link` or `memory` - nothing gained by "promoting" to the
# same or a weaker mode).
upgrade_prepare_cached_candidate() {
  UPGRADE_LATEST=""
  UPGRADE_SELECTED_MODE=""
  UPGRADE_CANDIDATE_CONTENT=""
  UPGRADE_TAG_HASH=""

  local cache_dir cache_file cached_version
  cache_dir=$(upgrade_cache_dir "$SCRIPT_LANG" "$SCRIPT_NAME")
  cache_file=$(upgrade_cache_file "$SCRIPT_LANG" "$SCRIPT_NAME")
  [[ -f "$cache_file" ]] || return 1

  cached_version=$(upgrade_file_version "$cache_file") || return 1
  upgrade_version_gt "$cached_version" "$SCRIPT_VERSION" || return 1

  local effective_level effective_rank cached_rank
  effective_level="${UPGRADE_LEVEL:-$(upgrade_version_level "$SCRIPT_VERSION")}"
  effective_rank=$(upgrade_level_rank "$effective_level") || return 1
  cached_rank=$(upgrade_level_rank "$(upgrade_version_level "$cached_version")") || return 1
  [[ "$cached_rank" -ge "$effective_rank" ]] || return 1

  local mode
  mode=$(upgrade_select_mode "$UPGRADE_TYPE" "$SCRIPT_PATH" "$cache_dir")
  case "$mode" in
    replacement|overwrite) ;;
    *) return 1 ;;
  esac

  UPGRADE_LATEST="$cached_version"
  UPGRADE_SELECTED_MODE="$mode"
  return 0
}

# --- section 11: --upgrade-check --------------------------------------------
# Discovery only - never downloads/applies/runs real work. Prints its report
# and exits; see the convention doc for the exact format.
upgrade_check_main() {
  local cache_dir mode versions
  cache_dir=$(upgrade_cache_dir "$SCRIPT_LANG" "$SCRIPT_NAME")
  mode=$(upgrade_select_mode "" "$SCRIPT_PATH" "$cache_dir")

  printf '%s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"

  if ! versions=$(upgrade_discover "$UPGRADE_OWNER" "$UPGRADE_REPO" "$SCRIPT_LANG" "$SCRIPT_NAME"); then
    printf 'upgrade check failed: could not reach %s\n' "$UPGRADE_HOST"
    printf 'Supported upgrade mode: %s\n' "$mode"
    exit 1
  fi

  local effective_level="${UPGRADE_LEVEL:-$(upgrade_version_level "$SCRIPT_VERSION")}"
  local would stable_v overall_v
  would=$(upgrade_highest_at_level "$versions" "$effective_level")
  stable_v=$(upgrade_highest_at_level "$versions" stable)
  overall_v=$(upgrade_highest_at_level "$versions" dev)

  if [[ -n "$would" ]] && upgrade_version_gt "$would" "$SCRIPT_VERSION"; then
    printf 'Would upgrade to: v%s (level: %s)\n' "$would" "$effective_level"
  else
    printf 'No upgrade present\n'
    would=""
  fi
  [[ -n "$stable_v" && "$stable_v" != "$would" ]] && printf 'Newest stable release: v%s\n' "$stable_v"
  if [[ -n "$overall_v" && "$overall_v" != "$would" && "$overall_v" != "$stable_v" ]]; then
    printf 'Newest version overall: v%s\n' "$overall_v"
  fi
  printf 'Supported upgrade mode: %s\n' "$mode"
  exit 0
}

# --- section 12: --upgrade-only ---------------------------------------------
# Performs the check and, if eligible, the actual upgrade, then exits -
# never runs real container-upgrader work, so there is no trial run: a
# validated candidate is persisted directly.
upgrade_only_main() {
  if ! upgrade_prepare_candidate; then
    # upgrade_prepare_candidate always sets UPGRADE_BANNER_NOTE on failure
    # (no_upgrade/check_failed/parse_failed/hash_mismatch - section 10) -
    # strip its leading space and surrounding parens for a standalone line.
    printf '%s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
    printf '%s\n' "${UPGRADE_BANNER_NOTE# (}" | sed 's/)$//'
    exit 0
  fi

  local latest="$UPGRADE_LATEST" mode="$UPGRADE_SELECTED_MODE" content="$UPGRADE_CANDIDATE_CONTENT" tag_hash="$UPGRADE_TAG_HASH"
  case "$mode" in
    replacement)
      local tmp
      if tmp=$(upgrade_write_temp_sibling "$content" "$SCRIPT_PATH"); then
        # Persist-time verification (section 6): re-hash the actual bytes
        # on disk before this temp file replaces the real one - see
        # upgrade_main's replacement branch for why this differs from the
        # download-time check in upgrade_prepare_candidate.
        if ! upgrade_verify_disk_hash "$tmp" "$tag_hash"; then
          rm -f "$tmp"
          printf 'Upgrade to v%s failed: on-disk content hash mismatch after writing %s, not applied\n' "$latest" "$SCRIPT_PATH"
          exit 1
        fi
        if upgrade_persist_replacement "$tmp" "$SCRIPT_PATH"; then
          printf 'Upgraded v%s -> v%s (replacement)\n' "$SCRIPT_VERSION" "$latest"
          exit 0
        fi
      fi
      rm -f "$tmp" 2>/dev/null
      printf 'Upgrade to v%s failed: could not write %s\n' "$latest" "$SCRIPT_PATH"
      exit 1
      ;;
    overwrite)
      # Persist-time verification (section 6): no trial run happens here
      # to have already produced a file to re-hash, so a scratch copy is
      # written purely to verify against - see upgrade_main's overwrite
      # branch for why a sibling temp file isn't an option for this mode.
      local scratch
      if scratch=$(upgrade_write_temp_scratch "$content"); then
        if ! upgrade_verify_disk_hash "$scratch" "$tag_hash"; then
          rm -f "$scratch"
          printf 'Upgrade to v%s failed: on-disk content hash mismatch, not applied\n' "$latest"
          exit 1
        fi
        rm -f "$scratch"
      fi
      if upgrade_persist_overwrite "$content" "$SCRIPT_PATH"; then
        printf 'Upgraded v%s -> v%s (overwrite)\n' "$SCRIPT_VERSION" "$latest"
        exit 0
      fi
      printf 'Upgrade to v%s failed: could not rewrite %s\n' "$latest" "$SCRIPT_PATH"
      exit 1
      ;;
    link)
      local cache_file
      cache_file=$(upgrade_cache_file "$SCRIPT_LANG" "$SCRIPT_NAME")
      if [[ -z "$content" ]]; then
        printf 'v%s already cached at %s (link)\n' "$latest" "$cache_file"
        exit 0
      fi
      if upgrade_persist_link "$content" "$cache_file"; then
        # Persist-time verification (section 6).
        if ! upgrade_verify_disk_hash "$cache_file" "$tag_hash"; then
          rm -f "$cache_file"
          printf 'Upgrade to v%s failed: on-disk content hash mismatch after writing cache %s, not applied\n' "$latest" "$cache_file"
          exit 1
        fi
        printf 'Upgraded v%s -> v%s, cached at %s (link)\n' "$SCRIPT_VERSION" "$latest" "$cache_file"
        exit 0
      fi
      printf 'Upgrade to v%s failed: could not write cache %s\n' "$latest" "$cache_file"
      exit 1
      ;;
    memory)
      printf 'v%s validated but nothing could be persisted (memory is the only supported mode here) - it will be re-fetched next run\n' "$latest"
      exit 0
      ;;
  esac
}

# --- section 8: ordinary flow (trial-run-then-persist) ---------------------
# Called once, after argument parsing, before any container-engine work.
# On a successful trial run, this hands off entirely to the candidate (as a
# child process) and exits with its exit code - it never returns in that
# case. It returns normally only when nothing was applied, so the caller
# continues to do the script's own real work under the already-loaded
# version.
upgrade_main() {
  # Re-entry guard: this process IS the candidate a parent just handed off
  # to - report the outcome and skip checking again (the parent already did).
  if [[ -n "${CONTAINER_UPGRADE_APPLIED_FROM:-}" ]]; then
    UPGRADE_BANNER_NOTE=$(upgrade_banner_note applying "$CONTAINER_UPGRADE_APPLIED_FROM" "$CONTAINER_UPGRADE_APPLIED_MODE")
    unset CONTAINER_UPGRADE_APPLIED_FROM CONTAINER_UPGRADE_APPLIED_MODE
    return 0
  fi

  [[ "$UPGRADE_TYPE" == "none" ]] && return 0
  [[ "$NO_AUTOUPDATE" == "true" ]] && return 0

  local explicit=0
  [[ -n "$UPGRADE_TYPE" ]] && explicit=1
  [[ -n "$UPGRADE_LEVEL" ]] && explicit=1
  local cache_file="${XDG_CACHE_HOME:-$HOME/.cache}/scripts-upgrade/${SCRIPT_LANG}_${SCRIPT_NAME}.state"
  local cache_source=""
  if [[ "$explicit" == "0" ]] && ! upgrade_cooldown_elapsed "$cache_file"; then
    # Section 2's cooldown clarification: the cooldown only gates the
    # *remote* discovery/download below - local apply-mode eligibility is
    # always re-evaluated fresh regardless (upgrade_select_mode, called
    # from upgrade_prepare_cached_candidate), so an already-cached,
    # already-validated candidate (section 7) can still be promoted
    # straight to a stronger mode right now if that eligibility has newly
    # escalated past `link` since it was cached (e.g. this run is `sudo`,
    # the one that cached it wasn't). No cooldown timestamp is written in
    # this branch below - nothing remote was actually checked, so the
    # original schedule is left untouched for the next implicit run.
    if ! upgrade_prepare_cached_candidate; then
      UPGRADE_BANNER_NOTE=$(upgrade_banner_note not_checked)
      return 0
    fi
    cache_source=$(upgrade_cache_file "$SCRIPT_LANG" "$SCRIPT_NAME")
  else
    upgrade_prepare_candidate || return 0

    # Best-effort cache write (section 14) - a failure to write it is not
    # itself a failure, the check just runs again next time. Only reached
    # here, since only this branch actually performed a remote check.
    mkdir -p "$(dirname "$cache_file")" 2>/dev/null
    date +%s > "$cache_file" 2>/dev/null || true
  fi

  local latest="$UPGRADE_LATEST" mode="$UPGRADE_SELECTED_MODE" content="$UPGRADE_CANDIDATE_CONTENT" tag_hash="$UPGRADE_TAG_HASH"
  export CONTAINER_UPGRADE_APPLIED_FROM="$SCRIPT_VERSION"
  export CONTAINER_UPGRADE_APPLIED_MODE="$mode"

  case "$mode" in
    replacement)
      local tmp code
      # $content is empty when this candidate was promoted from the local
      # cache (cache_source set above) rather than freshly downloaded -
      # read bytes straight from that file instead, byte-exact, no
      # variable round-trip (see upgrade_write_temp_sibling_from_file).
      if [[ -n "$cache_source" ]]; then
        tmp=$(upgrade_write_temp_sibling_from_file "$cache_source" "$SCRIPT_PATH")
      else
        tmp=$(upgrade_write_temp_sibling "$content" "$SCRIPT_PATH")
      fi
      if [[ -z "$tmp" ]]; then
        unset CONTAINER_UPGRADE_APPLIED_FROM CONTAINER_UPGRADE_APPLIED_MODE
        UPGRADE_BANNER_NOTE=$(upgrade_banner_note check_failed "could not write temp file")
        return 0
      fi
      "$tmp" "$@"; code=$?
      if [[ "$code" -eq 0 ]]; then
        # Persist-time verification (section 6): re-hash the actual bytes
        # on disk - not the in-memory $content again, which wouldn't catch
        # anything new - right before they become the live script, as a
        # final gate independent of the download-time check in
        # upgrade_prepare_candidate. Never changes $code either way.
        if ! upgrade_verify_disk_hash "$tmp" "$tag_hash"; then
          rm -f "$tmp"
          err "Upgrade to v${latest} failed to persist (replacement): on-disk content hash mismatch after trial run - not applied, will retry next run"
        elif upgrade_persist_replacement "$tmp" "$SCRIPT_PATH"; then
          log "Upgrade to v${latest} applied (replacement)"
        else
          rm -f "$tmp"
          err "Upgrade to v${latest} failed to persist (replacement): could not rename temp file - will retry next run"
        fi
      else
        rm -f "$tmp"
      fi
      # The candidate's real work already ran either way - its exit code
      # is this invocation's outcome, no retry (section 9).
      exit "$code"
      ;;
    overwrite)
      local code scratch=""
      if [[ -n "$cache_source" ]]; then
        # A real, already-executable file on disk (the link-mode cache
        # file) - run it directly, since its own $0 is already a real path.
        "$cache_source" "$@"; code=$?
      else
        # Write the content to a real scratch file and run bash against
        # that path (rather than `bash -c "$content" <placeholder> "$@"`)
        # so the candidate's own $0 is a genuine file - both a real
        # filename (its version-detection `grep ... "$0"` at the top of
        # the file doesn't hang reading stdin, the way a literal "--" made
        # it do) and real content (that grep actually finds the `#
        # Version:` line, instead of reporting itself as "unknown" the way
        # an empty /dev/null placeholder made it do). See
        # docs/requirements/generic/script-upgrade-convention.md section 8
        # implementation note for both bugs. This same scratch file is
        # reused below for persist-time hash re-verification (section 6)
        # instead of being written twice.
        if ! scratch=$(upgrade_write_temp_scratch "$content"); then
          unset CONTAINER_UPGRADE_APPLIED_FROM CONTAINER_UPGRADE_APPLIED_MODE
          UPGRADE_BANNER_NOTE=$(upgrade_banner_note check_failed "could not write temp file")
          return 0
        fi
        bash "$scratch" "$@"; code=$?
      fi
      if [[ "$code" -eq 0 ]]; then
        if [[ -n "$cache_source" ]]; then
          # Already-on-disk, already-hash-validated bytes (section 7) -
          # copy them straight in, byte-exact, no variable round-trip and
          # nothing new to re-verify a hash against (nothing was
          # downloaded this run).
          if upgrade_persist_overwrite_from_file "$cache_source" "$SCRIPT_PATH"; then
            log "Upgrade to v${latest} applied (overwrite)"
          else
            err "Upgrade to v${latest} failed to persist (overwrite): could not rewrite ${SCRIPT_PATH} - will retry next run"
          fi
        else
          # Persist-time verification (section 6), reusing the scratch
          # file the trial run above already wrote - a failure to have
          # gotten that scratch copy just skips the check (best-effort,
          # same as the rest of this convention), not a mismatch.
          local mismatch=0
          if [[ -n "$scratch" ]]; then
            upgrade_verify_disk_hash "$scratch" "$tag_hash" || mismatch=1
          fi
          if [[ "$mismatch" == "1" ]]; then
            err "Upgrade to v${latest} failed to persist (overwrite): on-disk content hash mismatch after trial run - not applied, will retry next run"
          elif upgrade_persist_overwrite "$content" "$SCRIPT_PATH"; then
            log "Upgrade to v${latest} applied (overwrite)"
          else
            err "Upgrade to v${latest} failed to persist (overwrite): could not rewrite ${SCRIPT_PATH} - will retry next run"
          fi
        fi
      fi
      [[ -n "$scratch" ]] && rm -f "$scratch"
      exit "$code"
      ;;
    link)
      local cache_file2 code
      cache_file2=$(upgrade_cache_file "$SCRIPT_LANG" "$SCRIPT_NAME")
      if [[ -n "$content" ]]; then
        if ! upgrade_persist_link "$content" "$cache_file2"; then
          unset CONTAINER_UPGRADE_APPLIED_FROM CONTAINER_UPGRADE_APPLIED_MODE
          UPGRADE_BANNER_NOTE=$(upgrade_banner_note check_failed "could not write cache")
          return 0
        fi
        # Persist-time verification (section 6): unlike replacement/
        # overwrite, "link" persists *before* its trial run (section 7),
        # so this check runs here instead - before the cache file is ever
        # trusted enough to execute, not after. A mismatch is therefore
        # still a pre-trial failure (section 9), same as check_failed
        # above: fall back to the original process's own work, not `exit`.
        if ! upgrade_verify_disk_hash "$cache_file2" "$tag_hash"; then
          rm -f "$cache_file2"
          unset CONTAINER_UPGRADE_APPLIED_FROM CONTAINER_UPGRADE_APPLIED_MODE
          UPGRADE_BANNER_NOTE=$(upgrade_banner_note hash_mismatch "$latest" "$SCRIPT_VERSION")
          return 0
        fi
      fi
      "$cache_file2" "$@"; code=$?
      # Don't leave a broken version cached for next time.
      [[ "$code" -ne 0 ]] && rm -f "$cache_file2"
      exit "$code"
      ;;
    memory)
      # See the "overwrite" case above for why the candidate is run from a
      # real scratch file instead of `bash -c "$content" <placeholder>
      # "$@"`. Unlike "overwrite", there is no persist step to reuse this
      # file for afterward - it exists purely to give the trial run a real
      # $0, and is discarded immediately once that run exits.
      local scratch code
      if ! scratch=$(upgrade_write_temp_scratch "$content"); then
        unset CONTAINER_UPGRADE_APPLIED_FROM CONTAINER_UPGRADE_APPLIED_MODE
        UPGRADE_BANNER_NOTE=$(upgrade_banner_note check_failed "could not write temp file")
        return 0
      fi
      bash "$scratch" "$@"; code=$?
      rm -f "$scratch"
      exit "$code"   # never persisted, regardless of outcome
      ;;
  esac
}

# =============================================================================
# Self-upgrade (docs/requirements/generic/script-upgrade-convention.md) ends
# =============================================================================

# args: $1=region name (e.g. "CORE-OPTIONS") -> prints the lines between
# that region's "# HELP:<name>:BEGIN"/"# HELP:<name>:END" marker comments
# (both markers excluded), sliced out of this script's own header by
# content, not by line number. Line-number slicing (this script's own
# approach before docs/requirements/generic/script-maintenance-convention.md
# section 2) breaks silently every time the header grows or shrinks by even
# one line - exactly the kind of edit this file makes constantly (version
# history, option docs). Marker-based extraction never needs updating when
# unrelated header content changes.
usage_region() {
  sed -n "/^# HELP:$1:BEGIN\$/,/^# HELP:$1:END\$/p" "$0" | sed '1d;$d'
}

# Prints the Version:/Category:/Description:/Upgrade-Source: lines. Unlike
# every other usage_region() above, this one IS a fixed line-number slice
# (lines 2-5) rather than marker-based - safe here specifically because
# docs/requirements/generic/script-header-convention.md pins these four
# lines as the literal first lines of the file right after the shebang,
# before any other header content (including a HELP:IDENTITY:BEGIN marker,
# which is why that region starts only after them, not before).
usage_header_fields() {
  sed -n '2,5p' "$0"
}

# args: $1=variant ("core" [default] | "upgrade" | "full") - see
# docs/requirements/generic/script-maintenance-convention.md section 2.
# "core" (bare --help) shows this script's own options only; "upgrade"
# (--help upgrade) shows only the self-upgrade options; "full" (--help
# full) shows both, self-upgrade options always last.
usage() {
  case "${1:-core}" in
    full)
      usage_header_fields
      printf '#\n'
      usage_region IDENTITY
      printf '#\n'
      usage_region INTRO
      printf '#\n'
      usage_region USAGE
      printf '#\n'
      usage_region CORE-OPTIONS
      printf '#\n'
      usage_region UPGRADE-OPTIONS
      printf '#\n'
      usage_region TAIL
      printf '#\n'
      usage_region UPGRADE-EXPLANATION
      printf '#\n'
      usage_region OUTPUT
      ;;
    upgrade)
      usage_header_fields
      printf '#\n'
      usage_region IDENTITY
      printf '#\n# Self-upgrade options only - see --help for this script'"'"'s own\n# options, or --help full for everything together.\n#\n'
      usage_region UPGRADE-OPTIONS
      printf '#\n'
      usage_region UPGRADE-EXPLANATION
      ;;
    core|*)
      usage_header_fields
      printf '#\n'
      usage_region IDENTITY
      printf '#\n'
      usage_region INTRO
      printf '#\n'
      usage_region USAGE
      printf '#\n'
      usage_region CORE-OPTIONS
      printf '#\n# Self-upgrade options (this script updating its own file) are not shown\n# here - see --help upgrade, or --help full for everything together.\n#\n'
      usage_region TAIL
      printf '#\n'
      usage_region OUTPUT
      ;;
  esac
  exit 1
}

# Captured before the parsing loop below consumes "$@", so upgrade_main can
# forward the original arguments unchanged to a trial-run child process.
ORIGINAL_ARGS=("$@")

while [[ $# -gt 0 ]]; do
  case "$1" in
    --restart-all) RESTART_ALL=true; shift ;;
    --skip-config-check) SKIP_CONFIG_CHECK=true; shift ;;
    --skip-crashing) SKIP_CRASHING=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    # --- self-upgrade: flags (script-upgrade-convention.md section 13) ----
    --no-autoupdate) NO_AUTOUPDATE=true; shift ;;
    --upgrade-type)
      UPGRADE_TYPE="${2:-}"
      case "$UPGRADE_TYPE" in
        replacement|overwrite|link|memory|none) ;;
        *) err "Invalid --upgrade-type: $UPGRADE_TYPE (expected replacement|overwrite|link|memory|none)"; exit 1 ;;
      esac
      shift 2 ;;
    --upgrade-level)
      UPGRADE_LEVEL="${2:-}"
      case "$UPGRADE_LEVEL" in
        dev|alpha|beta|rc|stable) ;;
        *) err "Invalid --upgrade-level: $UPGRADE_LEVEL (expected dev|alpha|beta|rc|stable)"; exit 1 ;;
      esac
      shift 2 ;;
    --upgrade-check) UPGRADE_CHECK=true; shift ;;
    --upgrade-only) UPGRADE_ONLY=true; shift ;;
    # ------------------------------------------------------------------------
    --mode)
      MODE="${2:-}"
      if [[ "$MODE" != "simple" && "$MODE" != "safe" ]]; then
        err "Invalid --mode: $MODE (expected simple|safe)"; exit 1
      fi
      shift 2 ;;
    --timeout)
      TIMEOUT="${2:-}"
      shift 2 ;;
    --precheck-seconds)
      PRECHECK_SECONDS="${2:-}"
      shift 2 ;;
    --recent-restart-threshold)
      RECENT_RESTART_THRESHOLD="${2:-}"
      shift 2 ;;
    --external-restart-wait)
      EXTERNAL_RESTART_WAIT="${2:-}"
      shift 2 ;;
    --skip-quadlet-restart) SKIP_QUADLET_RESTART=true; shift ;;
    --skip-manual-unit-restart) SKIP_MANUAL_UNIT_RESTART=true; shift ;;
    --skip-systemd-restart) SKIP_SYSTEMD_RESTART=true; shift ;;
    --engine)
      ENGINE="${2:-}"
      ENGINE_EXPLICIT=true
      if [[ "$ENGINE" != "docker" && "$ENGINE" != "podman" ]]; then
        err "Invalid --engine: $ENGINE (expected docker|podman)"; exit 1
      fi
      shift 2 ;;
    -h|--help)
      case "${2:-}" in
        full) usage full ;;
        upgrade) usage upgrade ;;
        *) usage core ;;
      esac
      ;;
    -*)
      err "Unknown option: $1"
      err "Run with --help to see valid options."
      exit 1 ;;
    *) TARGETS+=("$1"); shift ;;
  esac
done

# --- self-upgrade: flag-combination validation (section 13) ----------------
if [[ -n "$UPGRADE_TYPE" && "$NO_AUTOUPDATE" == "true" ]]; then
  err "--upgrade-type cannot be combined with --no-autoupdate"; exit 1
fi
if [[ "$UPGRADE_CHECK" == "true" && "$UPGRADE_ONLY" == "true" ]]; then
  err "--upgrade-check cannot be combined with --upgrade-only"; exit 1
fi
if [[ "$UPGRADE_CHECK" == "true" && -n "$UPGRADE_TYPE" ]]; then
  err "--upgrade-check cannot be combined with --upgrade-type"; exit 1
fi

# --- self-upgrade: --upgrade-check / --upgrade-only exit before any --------
# container-engine work; see sections 11-12. Neither ever reaches the
# script's normal container-upgrader logic below.
[[ "$UPGRADE_CHECK" == "true" ]] && upgrade_check_main
[[ "$UPGRADE_ONLY" == "true" ]] && upgrade_only_main

# --- self-upgrade: ordinary flow (section 8) --------------------------------
# Runs before any container-engine work. On a successful trial run this
# hands off to the candidate and exits - the rest of the script below then
# executes only when nothing was applied (disabled, nothing eligible, check
# failed, or the trial run itself failed).
upgrade_main "${ORIGINAL_ARGS[@]+"${ORIGINAL_ARGS[@]}"}"

# Auto-detect engine if not explicitly given: prefer docker, fall back to
# podman, error if neither is on PATH.
if ! $ENGINE_EXPLICIT; then
  if command -v docker >/dev/null 2>&1; then
    ENGINE="docker"
  elif command -v podman >/dev/null 2>&1; then
    ENGINE="podman"
  else
    err "Error: neither docker nor podman found on PATH. Install one, or set --engine explicitly."
    exit 1
  fi
fi

if ! command -v jq >/dev/null 2>&1; then
  err "Error: jq is required but not found on PATH. Install jq (e.g. apt/dnf/brew install jq)."
  exit 1
fi

# ---------------------------------------------------------------------------
# Run-command reconstruction
# ---------------------------------------------------------------------------

# Computes, as JSON, the subset of container inspect JSON $1's Config that
# was actually explicit at creation time (a flag passed to `run`) rather
# than inherited from image Config JSON $2's own baked-in defaults. $2 MUST
# be the image the container was actually created from - not any newer
# image - otherwise a value that's only equal to the OLD image's default
# (never explicitly set) looks like an override once diffed against a NEW
# image whose own default differs, and gets wrongly pinned forward.
# WorkingDir/Entrypoint/Cmd are replace-only (image default or explicit
# value, never both), so only the explicit case yields non-null; Env/Labels
# are image-default-plus-explicit-additions, so the image's own entries are
# subtracted out. Shared by get_run_command (to build override flags) and
# normalized_config (so the safe-mode config check compares genuine
# overrides only, not values that legitimately track a new image's own
# defaults).
explicit_config() {
  local cjson="$1" ijson="$2"
  jq -n --argjson c "$cjson" --argjson ic "$ijson" '
    def arr(x): if x == null then [] else x end;
    {
      WorkingDir: (if (($c.Config.WorkingDir // "") != "") and ($c.Config.WorkingDir != ($ic.WorkingDir // ""))
                     then $c.Config.WorkingDir else null end),
      Entrypoint: (if ($c.Config.Entrypoint != null) and ($c.Config.Entrypoint != ($ic.Entrypoint // null))
                     then $c.Config.Entrypoint else null end),
      Cmd: (if ($c.Config.Cmd != null) and ($c.Config.Cmd != ($ic.Cmd // null))
              then $c.Config.Cmd else null end),
      Env: ((arr($c.Config.Env) - arr($ic.Env)) | sort),
      Labels: ( ( (($c.Config.Labels // {}) | to_entries) - (($ic.Labels // {}) | to_entries) )
                | sort_by(.key) )
    }
  '
}

# Builds an `<engine> run ...` command line reproducing container $1's
# settings. $2 must be the image the container was actually created from
# (its "before" image on an upgrade, NOT the newly-pulled one it's about to
# move to) - see explicit_config for why. Settings that merely track that
# original image's own defaults are left out, so only real overrides are
# emitted; the new container then picks up the new image's own defaults for
# anything the caller never explicitly set.
get_run_command() {
  local name="$1" orig_image="$2"
  local cjson ijson ejson args quoted

  cjson=$($ENGINE inspect --format '{{json .}}' "$name" 2>/dev/null) || return 1
  ijson=$($ENGINE image inspect --format '{{json .Config}}' "$orig_image" 2>/dev/null) || ijson='{}'
  ejson=$(explicit_config "$cjson" "$ijson")

  args=$(jq -n --argjson c "$cjson" --argjson ic "$ijson" --argjson e "$ejson" '
    def arr(x): if x == null then [] else x end;
    ( ($c.Id // "")[0:12] ) as $shortid |

    ["-d"] +

    (if ($c.Name // "") != "" then ["--name", ($c.Name | ltrimstr("/"))] else [] end) +

    (if (($c.Config.Hostname // "") != "") and ($c.Config.Hostname != $shortid)
       then ["--hostname", $c.Config.Hostname] else [] end) +

    (if (($c.Config.User // "") != "") then ["--user", $c.Config.User] else [] end) +

    (if ($e.WorkingDir != null) then ["--workdir", $e.WorkingDir] else [] end) +

    ( [ $e.Env[] | ("--env", .) ] | flatten ) +

    ( $e.Labels | map(["--label", (.key + "=" + .value)]) | flatten ) +

    ( [ ($c.HostConfig.PortBindings // {}) | to_entries[] as $pb |
        $pb.value[]? |
        (if (.HostPort // "") == "" then
           $pb.key
         else
           (if ((.HostIp // "") != "" and (.HostIp) != "0.0.0.0") then (.HostIp + ":") else "" end)
           + .HostPort + ":" + $pb.key
         end) as $mapping |
        ("--publish", $mapping)
      ] | flatten ) +

    ( [ (arr($c.Mounts))[] |
        if .Type == "bind" then
          ["--volume", (.Source + ":" + .Destination + (if .RW then "" else ":ro" end))]
        elif .Type == "volume" then
          ["--volume", ((.Name // .Source) + ":" + .Destination + (if .RW then "" else ":ro" end))]
        elif .Type == "tmpfs" then
          ["--tmpfs", .Destination]
        else [] end
      ] | flatten ) +

    (if (($c.HostConfig.NetworkMode // "") != "")
        and ($c.HostConfig.NetworkMode != "default")
        and ($c.HostConfig.NetworkMode != "bridge")
       then ["--network", $c.HostConfig.NetworkMode] else [] end) +

    (if (($c.HostConfig.RestartPolicy.Name // "") != "") and ($c.HostConfig.RestartPolicy.Name != "no")
       then ["--restart", ( $c.HostConfig.RestartPolicy.Name
              + (if $c.HostConfig.RestartPolicy.Name == "on-failure" and ($c.HostConfig.RestartPolicy.MaximumRetryCount // 0) > 0
                   then (":" + ($c.HostConfig.RestartPolicy.MaximumRetryCount | tostring)) else "" end) )]
       else [] end) +

    (if ($c.HostConfig.Privileged // false) then ["--privileged"] else [] end) +

    ( [ (arr($c.HostConfig.CapAdd))[] | ("--cap-add", .) ] | flatten ) +
    ( [ (arr($c.HostConfig.CapDrop))[] | ("--cap-drop", .) ] | flatten ) +

    ( [ (arr($c.HostConfig.Devices))[] |
        ("--device", (.PathOnHost + ":" + .PathInContainer
          + (if (.CgroupPermissions // "") != "" then (":" + .CgroupPermissions) else "" end)))
      ] | flatten ) +

    ( [ (arr($c.HostConfig.ExtraHosts))[] | ("--add-host", .) ] | flatten ) +

    (if (($c.HostConfig.Memory // 0) > 0) then ["--memory", ($c.HostConfig.Memory | tostring)] else [] end) +

    (if (($c.HostConfig.NanoCpus // 0) > 0) then ["--cpus", (($c.HostConfig.NanoCpus / 1000000000) | tostring)] else [] end) +

    ( [ (arr($c.HostConfig.SecurityOpt))[] | ("--security-opt", .) ] | flatten ) +

    ( [ (arr($c.HostConfig.Dns))[] | ("--dns", .) ] | flatten ) +

    (if ($c.Config.Tty // false) then ["-t"] else [] end) +
    (if ($c.Config.OpenStdin // false) then ["-i"] else [] end) +

    (if ($e.Entrypoint != null) then ["--entrypoint", ($e.Entrypoint[0] // "")] else [] end) +

    [$c.Config.Image] +

    (if ($e.Cmd != null) then $e.Cmd else [] end)
  ' 2>/dev/null)

  if [[ -z "$args" || "$args" == "null" ]]; then
    return 1
  fi

  quoted=$(printf '%s' "$args" | jq -r '.[] | @sh' | tr '\n' ' ')
  echo "$ENGINE run ${quoted}"
}

# ---------------------------------------------------------------------------
# Config comparison (safe mode)
# ---------------------------------------------------------------------------

# Produces a normalized, sorted JSON fingerprint of a container's runtime
# settings, for comparing old vs. recreated containers. This is broader
# than get_run_command's coverage on purpose - it's an independent check
# meant to catch settings the reconstruction doesn't know about (ulimits,
# sysctls, ipc/pid/uts/userns mode, shm-size, etc), not just verify what
# we intentionally set.
#
# Deliberately excluded (expected to differ / not meaningful to compare):
#   - Id, Created, Image digest, State, network IPs/MAC, log/resolv paths
#   - anonymous volume names (random per container) - only Destination,
#     Type and RW are compared for non-bind mounts
#   - a host port that was left for Docker to assign randomly (original
#     HostPort == "") - normalized to the literal string "random" on
#     both sides so two different assigned ports don't show as a diff
#
# WorkingDir/Entrypoint/Cmd are fingerprinted via explicit_config (the same
# helper get_run_command uses), not their raw resolved values: each
# container is diffed against its OWN creation image (self-referential via
# its own .Image field), so a value legitimately inherited from a new
# image's defaults - never explicitly set on either container - doesn't
# show up as a mismatch, while a genuine reconstruction gap (the script
# failed to reproduce an actual override) still does.
normalized_config() {
  local name="$1" cjson image_id ijson ejson
  cjson=$($ENGINE inspect --format '{{json .}}' "$name" 2>/dev/null) || return 1
  image_id=$(jq -r '.Image // empty' <<<"$cjson")
  ijson=$($ENGINE image inspect --format '{{json .Config}}' "$image_id" 2>/dev/null) || ijson='{}'
  ejson=$(explicit_config "$cjson" "$ijson")

  jq -n --argjson c "$cjson" --argjson e "$ejson" -S '
    {
      Config: {
        User: $c.Config.User,
        WorkingDir: $e.WorkingDir,
        Tty: $c.Config.Tty,
        OpenStdin: $c.Config.OpenStdin,
        Entrypoint: $e.Entrypoint,
        Cmd: $e.Cmd,
        ExposedPorts: (($c.Config.ExposedPorts // {}) | keys | sort)
      },
      HostConfig: ($c.HostConfig | {
        NetworkMode,
        RestartPolicy,
        Privileged,
        CapAdd: ((.CapAdd // []) | sort),
        CapDrop: ((.CapDrop // []) | sort),
        Devices: ((.Devices // []) | map({PathOnHost, PathInContainer, CgroupPermissions}) | sort),
        ExtraHosts: ((.ExtraHosts // []) | sort),
        Memory,
        NanoCpus,
        SecurityOpt: ((.SecurityOpt // []) | sort),
        Dns: ((.Dns // []) | sort),
        DnsSearch: ((.DnsSearch // []) | sort),
        GroupAdd: ((.GroupAdd // []) | sort),
        IpcMode,
        PidMode,
        UTSMode,
        UsernsMode,
        ShmSize,
        ReadonlyRootfs,
        Ulimits: ((.Ulimits // []) | sort),
        Sysctls: (.Sysctls // {}),
        Init,
        PortBindings: (
          (.PortBindings // {}) | to_entries | map({
            key: .key,
            hostPorts: ((.value // []) | map(if (.HostPort // "") == "" then "random" else .HostPort end) | sort)
          }) | sort_by(.key)
        )
      }),
      Mounts: (($c.Mounts // []) | map(
          if .Type == "bind" then {Type, Destination, Source, RW}
          else {Type, Destination, RW}
          end
        ) | sort_by(.Destination))
    }
  ' 2>/dev/null
}

# ---------------------------------------------------------------------------
# Health checks
# ---------------------------------------------------------------------------

# Point-in-time check: is the container currently running, not mid-restart,
# and (if it has a healthcheck) not reporting unhealthy? Used for pre-upgrade
# classification and for final post-upgrade classification.
is_running_and_healthy() {
  local name="$1" j
  j=$($ENGINE inspect --format '{{json .}}' "$name" 2>/dev/null) || return 1
  jq -e '
    (.State.Running == true) and
    (.State.Restarting != true) and
    ((.State.Health.Status // "none") != "unhealthy")
  ' <<<"$j" >/dev/null 2>&1
}

# Same checks, plus: has RestartCount increased past a baseline captured at
# the start of a monitoring window? Used while actively watching a container
# we just (re)started, to catch a crash-loop the point-in-time check alone
# might land between restarts and miss.
is_healthy_vs_baseline() {
  local name="$1" baseline_restarts="$2" j
  j=$($ENGINE inspect --format '{{json .}}' "$name" 2>/dev/null) || return 1
  jq -e --argjson baseline "$baseline_restarts" '
    (.State.Running == true) and
    (.State.Restarting != true) and
    ((.State.Health.Status // "none") != "unhealthy") and
    ((.RestartCount // 0) <= $baseline)
  ' <<<"$j" >/dev/null 2>&1
}

# Polls every 2s for $2 seconds, failing fast on the first bad check.
monitor_container() {
  local name="$1" duration="$2" label="${3:-monitor}"
  local baseline
  baseline=$($ENGINE inspect --format '{{.RestartCount}}' "$name" 2>/dev/null) || baseline=0
  local elapsed=0
  local interval=2
  while [[ "$elapsed" -lt "$duration" ]]; do
    sleep "$interval"
    elapsed=$((elapsed + interval))
    if ! is_healthy_vs_baseline "$name" "$baseline"; then
      log "    [$label] Health check failed at ${elapsed}s"
      return 1
    fi
    log "    [$label] Health check OK at ${elapsed}s"
  done
  return 0
}

# Polls up to $EXTERNAL_RESTART_WAIT seconds after a stop for evidence that
# something other than this script (systemd/Quadlet, another supervisor, a
# human) already recreated/restarted the container - see
# docs/requirements/implemented/external-restart-detection.md.
#
# Echoes one of: "" (nothing detected - fall through to the normal manual
# restart), "upgraded_externally", "reverted_externally",
# "external_config_discrepancy". For an auto-generated-name success match,
# also removes the leftover original container (mirrors safe mode's own
# old-container cleanup).
detect_external_restart() {
  local name="$1" pre_fingerprint="$2" old_id="$3" new_id="$4"
  local auto_name_re='^[a-z][a-z0-9]*_[a-z][a-z0-9]*$'
  local is_auto_name=false
  [[ "$name" =~ $auto_name_re ]] && is_auto_name=true

  local pre_ids=$'\n'
  if $is_auto_name; then
    while IFS= read -r id || [[ -n "$id" ]]; do
      [[ -n "$id" ]] && pre_ids+="$id"$'\n'
    done < <($ENGINE ps -a --format '{{.ID}}')
  fi

  local waited=0
  while [[ "$waited" -lt "$EXTERNAL_RESTART_WAIT" ]]; do
    sleep 1
    waited=$((waited + 1))

    if ! $is_auto_name; then
      # Fixed name: reappearance under the exact original name is itself
      # the signal - the engine never lets two containers share a name.
      if [[ "$($ENGINE inspect --format '{{.State.Running}}' "$name" 2>/dev/null)" == "true" ]]; then
        local cur_fp cur_id
        cur_fp=$(normalized_config "$name")
        if [[ "$cur_fp" != "$pre_fingerprint" ]]; then
          echo "external_config_discrepancy"
          return 0
        fi
        cur_id=$($ENGINE inspect --format '{{.Image}}' "$name" 2>/dev/null)
        if [[ "$cur_id" == "$new_id" ]]; then
          echo "upgraded_externally"
        else
          echo "reverted_externally"
        fi
        return 0
      fi
    else
      # Auto-generated original name: an external recreate isn't obliged
      # to reuse it, so look for any brand-new container of the same
      # name shape whose fingerprint matches the pre-stop original.
      local id
      while IFS= read -r id || [[ -n "$id" ]]; do
        [[ -z "$id" ]] && continue
        [[ "$pre_ids" == *$'\n'"$id"$'\n'* ]] && continue
        local cname
        cname=$($ENGINE inspect --format '{{.Name}}' "$id" 2>/dev/null | sed 's#^/##')
        [[ "$cname" =~ $auto_name_re ]] || continue
        [[ "$(normalized_config "$id")" == "$pre_fingerprint" ]] || continue
        local cid
        cid=$($ENGINE inspect --format '{{.Image}}' "$id" 2>/dev/null)
        if [[ "$cid" == "$new_id" ]]; then
          $ENGINE rm -f "$name" >/dev/null 2>&1 || true
          echo "upgraded_externally"
        else
          echo "reverted_externally"
        fi
        return 0
      done < <($ENGINE ps -a --format '{{.ID}}')
    fi
  done
  echo ""
}

# Parses an RFC3339 timestamp (as reported by Docker/Podman, e.g.
# "2026-09-05T04:20:59.123456789Z") into a Unix epoch. Tries GNU date
# first, then falls back to BSD/macOS date syntax for portability.
parse_to_epoch() {
  local ts="$1" epoch
  epoch=$(date -u -d "$ts" +%s 2>/dev/null) && { echo "$epoch"; return 0; }
  epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "${ts%%.*}" +%s 2>/dev/null) && { echo "$epoch"; return 0; }
  return 1
}

# Fast, no-wait check using data Docker/Podman already track - no polling
# required. Returns 0 (crashing) if either:
#   - the container has restarted at least once (RestartCount > 0) AND
#     that most recent restart happened within the last
#     --recent-restart-threshold seconds (State.StartedAt is updated on
#     every restart, not just the original start, so this is exactly
#     "time since the last restart", not time since creation); or
#   - it has a healthcheck configured and its status is still "starting"
#     well past that same threshold - i.e. it never reached a first
#     successful readiness check.
# Returns 1 (not detected as crashing by this fast check) otherwise,
# including when the container's state can't be determined - callers
# should fall back to the live monitor_container check in that case.
check_recent_restart_or_stuck() {
  local name="$1" j restart_count started_at health_status start_epoch now_epoch elapsed
  j=$($ENGINE inspect --format '{{json .}}' "$name" 2>/dev/null) || return 1
  restart_count=$(jq -r '.RestartCount // 0' <<<"$j")
  started_at=$(jq -r '.State.StartedAt // empty' <<<"$j")
  health_status=$(jq -r '.State.Health.Status // "none"' <<<"$j")

  if [[ -z "$started_at" || "$started_at" == "0001-01-01T00:00:00Z" ]]; then
    return 1
  fi

  start_epoch=$(parse_to_epoch "$started_at") || return 1
  now_epoch=$(date +%s)
  elapsed=$(( now_epoch - start_epoch ))

  if [[ "$restart_count" -gt 0 && "$elapsed" -lt "$RECENT_RESTART_THRESHOLD" ]]; then
    log "    [precheck] restart_count=$restart_count, last (re)start was only ${elapsed}s ago (threshold ${RECENT_RESTART_THRESHOLD}s) - treating as crashing."
    return 0
  fi

  if [[ "$health_status" == "starting" && "$elapsed" -ge "$RECENT_RESTART_THRESHOLD" ]]; then
    log "    [precheck] Health status still 'starting' after ${elapsed}s (threshold ${RECENT_RESTART_THRESHOLD}s) - readiness never reached, treating as crashing."
    return 0
  fi

  return 1
}

# Observes a container BEFORE we touch it, to see whether it is already
# crashing. Echoes "healthy" or "crashing". Checks the fast, no-wait
# restart/readiness signal first (catches crash loops slower than
# --precheck-seconds, which a live-only check would miss if it happened
# to land between restarts); falls back to the live poll otherwise.
check_pre_status() {
  local name="$1"
  if check_recent_restart_or_stuck "$name"; then
    echo "crashing"
    return
  fi
  if monitor_container "$name" "$PRECHECK_SECONDS" "precheck"; then
    echo "healthy"
  else
    echo "crashing"
  fi
}

# ---------------------------------------------------------------------------
# Restart-policy safety
# ---------------------------------------------------------------------------
#
# A restart policy of "always" does not, by itself, bring a container back
# after an explicit `$ENGINE stop` (which is exactly what both strategies
# below do) while the engine's own daemon/service keeps running - only a
# daemon/service restart (or an explicit manual start) does. But a
# container that ends up sitting stopped for a while mid-upgrade (safe
# mode renames it aside and can leave it there for the full --timeout
# window, or longer still if rollback isn't attempted) is exposed to that
# daemon-restart race: if the engine's daemon/service restarts while our
# container sits there intentionally stopped, "always" brings it back up
# on its old image right underneath us, while "unless-stopped" would not.
#
# To close that window, in both modes the targeted container's policy is
# checked before it is stopped and, if "always", relaxed to
# "unless-stopped" first; once the container that ends up running under
# the original name starts back up, its policy is restored to "always"
# (a container left stopped-aside for manual recovery - safe mode's
# fail_no_rollback path - has its policy restored there too, even though
# it never restarts, so it isn't left permanently downgraded from what it
# was configured with before this script touched it).
#
# This is a best-effort safety step, not part of the upgrade itself: a
# failure to relax or restore (e.g. an engine/version - some Podman
# releases - that doesn't support `update --restart`) never blocks or
# rolls back the actual container work, but is reported as its own error
# category in the summary (see RESTART_POLICY_ISSUES) with the specific
# detail of what failed and why, since a container silently left on the
# wrong policy is a real (if secondary) problem worth surfacing.

get_restart_policy() {
  local name="$1"
  $ENGINE inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$name" 2>/dev/null
}

# Reports whether $1 was started with --rm (AutoRemove). Such a container
# is destroyed by the engine the moment it stops, which safe mode's
# rename-based rollback cannot survive - see restart_safe's caller.
get_auto_remove() {
  local name="$1"
  $ENGINE inspect --format '{{.HostConfig.AutoRemove}}' "$name" 2>/dev/null
}

# Sets $1's restart policy to $2. On failure, returns 1 and leaves the
# engine's error text in RESTART_POLICY_ERROR (bash 3.2 has no other way
# to hand back more than an exit code - see the map_* functions' header
# comment for the same constraint elsewhere in this script).
set_restart_policy() {
  local name="$1" policy="$2" out
  RESTART_POLICY_ERROR=""
  if out=$($ENGINE update --restart="$policy" "$name" 2>&1 1>/dev/null); then
    return 0
  fi
  RESTART_POLICY_ERROR="$out"
  return 1
}

# Records a failed relax/restore as its own reported category (distinct
# from the container's health-based RESULT) - see RESTART_POLICY_ISSUES.
record_restart_policy_issue() {
  local name="$1" detail="$2"
  err "  Restart-policy safety step failed for $name: $detail"
  RESTART_POLICY_ISSUES+=("$name: $detail")
}

# ---------------------------------------------------------------------------
# Systemd-unit-managed restart (Quadlet label, or manual systemd.unit label)
# ---------------------------------------------------------------------------
#
# A container may be owned by a systemd unit in one of two ways: Podman
# Quadlet sets a PODMAN_SYSTEMD_UNIT label automatically on any container it
# starts from a .container file, or an operator can manually add a
# systemd.unit label to a container started by a hand-written unit
# (ExecStart=<engine> run ...) to opt into the same treatment. Either way,
# the container itself is really a side effect of that unit being active -
# reconstructing/reapplying its flags or stopping it directly (as the
# strategies below do) would race systemd rather than cooperate with it, so
# such a container is instead restarted by asking its own unit to restart -
# see docs/requirements/implemented/quadlet-managed-restart.md and
# docs/requirements/pending/manual-systemd-unit-label.md.
#
# The restart itself needs to know whether that unit is a --user (rootless)
# or system-wide unit - see resolve_systemd_scope() below - since neither
# Podman Quadlet nor a hand-written unit is reliably one or the other.

# Echoes $1's PODMAN_SYSTEMD_UNIT label value, or empty if unset/absent.
# Uses the same JSON-dump-then-jq pattern as normalized_config rather than a
# Go-template lookup, since `{{index .Config.Labels "..."}}` errors out on a
# missing key instead of returning empty.
get_quadlet_unit() {
  local name="$1"
  $ENGINE inspect --format '{{json .Config.Labels}}' "$name" 2>/dev/null | jq -r '.PODMAN_SYSTEMD_UNIT // empty'
}

# Echoes $1's manually-set systemd.unit label value, or empty if unset/absent.
get_manual_systemd_unit() {
  local name="$1"
  $ENGINE inspect --format '{{json .Config.Labels}}' "$name" 2>/dev/null | jq -r '.["systemd.unit"] // empty'
}

# Echoes $1's systemd.scope label value ("user"/"system"), or empty if
# unset/absent.
get_systemd_scope_label() {
  local name="$1"
  $ENGINE inspect --format '{{json .Config.Labels}}' "$name" 2>/dev/null | jq -r '.["systemd.scope"] // empty'
}

# Echoes "true"/"false" for whether the current `podman` invocation is
# rootless. Cached after the first call (PODMAN_ROOTLESS_CACHE) since it is
# a property of the whole invocation, not of any one container.
PODMAN_ROOTLESS_CACHE=""
podman_is_rootless() {
  if [[ -z "$PODMAN_ROOTLESS_CACHE" ]]; then
    PODMAN_ROOTLESS_CACHE="$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)"
    [[ "$PODMAN_ROOTLESS_CACHE" == "true" || "$PODMAN_ROOTLESS_CACHE" == "false" ]] || PODMAN_ROOTLESS_CACHE="false"
  fi
  echo "$PODMAN_ROOTLESS_CACHE"
}

# Echoes "true"/"false" for whether the current `docker` invocation is
# rootless mode. Cached after the first call, same reasoning as
# podman_is_rootless(). Unlike Podman, a rootful (standard) Docker daemon's
# state says nothing about any individual container's owning unit scope -
# see resolve_systemd_scope()'s docker-rootful branch.
DOCKER_ROOTLESS_CACHE=""
docker_is_rootless() {
  if [[ -z "$DOCKER_ROOTLESS_CACHE" ]]; then
    if docker info --format '{{json .SecurityOptions}}' 2>/dev/null | grep -q '"name=rootless"'; then
      DOCKER_ROOTLESS_CACHE="true"
    else
      DOCKER_ROOTLESS_CACHE="false"
    fi
  fi
  echo "$DOCKER_ROOTLESS_CACHE"
}

# Echoes "true"/"false" for whether unit $1 has a loadable unit file at
# scope $2 ("user"/"system"). Read-only (list-unit-files), no privilege
# needed just to check.
systemd_unit_exists() {
  local unit="$1" scope="$2"
  if [[ "$scope" == "user" ]]; then
    systemctl --user list-unit-files "$unit" --no-legend 2>/dev/null | grep -q .
  else
    systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q .
  fi
}

# Resolves the restart scope ("user"/"system") for container $1 (engine $2,
# unit $3), per docs/requirements/pending/manual-systemd-unit-label.md
# section 3. Echoes the resolved scope on success, or one of three error
# tokens (systemd_unit_scope_mismatch, systemd_unit_not_found,
# systemd_unit_permission_denied) - the caller must not attempt a systemctl
# restart, nor fall back to the normal simple/safe restart, on any of these
# (see that requirement's section 4 for why).
resolve_systemd_scope() {
  local name="$1" engine="$2" unit="$3"
  local scope_label scope rootless expected

  scope_label="$($engine inspect --format '{{json .Config.Labels}}' "$name" 2>/dev/null | jq -r '.["systemd.scope"] // empty')"

  if [[ -n "$scope_label" && "$scope_label" != "user" && "$scope_label" != "system" ]]; then
    echo "systemd_unit_scope_mismatch"; return 0
  fi

  if [[ "$engine" == "podman" ]]; then
    rootless="$(podman_is_rootless)"
    expected="user"; [[ "$rootless" == "false" ]] && expected="system"
    if [[ -n "$scope_label" && "$scope_label" != "$expected" ]]; then
      echo "systemd_unit_scope_mismatch"; return 0
    fi
    scope="${scope_label:-$expected}"
  else
    if [[ "$(docker_is_rootless)" == "true" ]]; then
      if [[ -n "$scope_label" && "$scope_label" != "user" ]]; then
        echo "systemd_unit_scope_mismatch"; return 0
      fi
      scope="user"
    else
      if [[ -n "$scope_label" ]]; then
        scope="$scope_label"
      elif systemd_unit_exists "$unit" "user"; then
        scope="user"
      elif systemd_unit_exists "$unit" "system"; then
        scope="system"
      else
        echo "systemd_unit_not_found"; return 0
      fi
    fi
  fi

  if ! systemd_unit_exists "$unit" "$scope"; then
    echo "systemd_unit_not_found"; return 0
  fi

  if [[ "$scope" == "system" && "$EUID" -ne 0 ]]; then
    echo "systemd_unit_permission_denied"; return 0
  fi

  echo "$scope"
}

# Restarts a systemd-unit-managed container ($1, owning unit $2, restart
# scope $4 "user"/"system", detected via $5 "quadlet"/"manual") via
# `systemctl [--user] restart` instead of managing it directly. Unlike
# detect_external_restart, this script is deliberately initiating the
# restart, not passively detecting one initiated elsewhere: no direct stop
# happens here (so the 1.1.3 restart-policy relax/restore doesn't apply to
# this attempt), and there is no normalized_config diff (the new container
# is produced entirely by systemd from the unit file - nothing this script
# generated to diff against).
#
# Echoes "upgraded_via_quadlet" or "upgraded_via_manual_unit" on success
# (per $5). Echoes "" if it did not succeed (the systemctl call itself
# failed, the unit never became active, the container never came back
# running, or it came back still on the old image) - the caller falls
# through to the normal restart_simple/restart_safe path unchanged in that
# case; the specific reason is only logged, not classified, since every
# such reason leads to the same fallback action. This is the only failure
# mode that falls back - resolve_systemd_scope()'s three error tokens are
# handled entirely by the caller, before this function is ever invoked.
restart_via_systemd_unit() {
  local name="$1" unit="$2" new_id="$3" scope="$4" source="$5"
  local out waited cur_id user_flag label success_outcome tag cmd_display

  user_flag=(); cmd_display="systemctl"
  if [[ "$scope" == "user" ]]; then
    user_flag=(--user)
    cmd_display="systemctl --user"
  fi
  if [[ "$source" == "manual" ]]; then
    tag="systemd-unit"
    label="$name carries a manual 'systemd.unit' label naming '$unit' (scope: $scope)"
    success_outcome="upgraded_via_manual_unit"
  else
    tag="quadlet"
    label="$name is managed by systemd unit '$unit' (scope: $scope)"
    success_outcome="upgraded_via_quadlet"
  fi

  log "  [$tag] $label - restarting via '$cmd_display restart' instead of managing it directly..."
  if ! out=$(systemctl "${user_flag[@]}" restart "$unit" 2>&1); then
    log "  [$tag] '$cmd_display restart $unit' failed: $out"
    echo ""
    return 0
  fi

  waited=0
  while [[ "$waited" -lt "$EXTERNAL_RESTART_WAIT" ]]; do
    sleep 1
    waited=$((waited + 1))
    if [[ "$(systemctl "${user_flag[@]}" is-active "$unit" 2>/dev/null)" == "active" ]] \
       && [[ "$($ENGINE inspect --format '{{.State.Running}}' "$name" 2>/dev/null)" == "true" ]]; then
      cur_id=$($ENGINE inspect --format '{{.Image}}' "$name" 2>/dev/null)
      if [[ "$cur_id" == "$new_id" ]]; then
        log "  [$tag] $name is running again on the new image after ${waited}s."
        echo "$success_outcome"
        return 0
      fi
    fi
  done

  log "  [$tag] $name did not come back running on the new image within ${EXTERNAL_RESTART_WAIT}s - falling back to the normal restart path."
  echo ""
}

# ---------------------------------------------------------------------------
# Restart strategies
# ---------------------------------------------------------------------------

restart_simple() {
  local name="$1" run_cmd="$2" auto_remove="${3:-false}" old_id="$4" new_id="$5"
  local orig_policy pre_fingerprint outcome
  orig_policy=$(get_restart_policy "$name")
  pre_fingerprint=$(normalized_config "$name")

  if [[ "$orig_policy" == "always" ]]; then
    log "  [simple] Restart policy is 'always' - relaxing to 'unless-stopped' before stopping..."
    set_restart_policy "$name" "unless-stopped" \
      || record_restart_policy_issue "$name" "could not relax policy to 'unless-stopped' before stop: $RESTART_POLICY_ERROR"
  fi

  log "  [simple] Stopping $name..."
  $ENGINE stop "$name" >/dev/null

  outcome=$(detect_external_restart "$name" "$pre_fingerprint" "$old_id" "$new_id")
  if [[ -n "$outcome" ]]; then
    err "  [simple] $name was restarted/recreated externally during the upgrade" \
        "(not by this script) - classified as: $outcome. No further action taken."
    if [[ "$orig_policy" == "always" ]]; then
      set_restart_policy "$name" "always" \
        || record_restart_policy_issue "$name" "could not restore policy to 'always' after external-restart detection: $RESTART_POLICY_ERROR"
    fi
    EXTERNAL_RESTART_OUTCOME="$outcome"
    return 0
  fi

  if [[ "$auto_remove" == "true" ]]; then
    log "  [simple] AutoRemove is set; $name was already removed by stop."
  else
    log "  [simple] Removing $name..."
    $ENGINE rm "$name" >/dev/null
  fi

  log "  [simple] Starting new container..."
  eval "$run_cmd"

  if [[ "$orig_policy" == "always" ]]; then
    set_restart_policy "$name" "always" \
      || record_restart_policy_issue "$name" "could not restore policy to 'always' after start: $RESTART_POLICY_ERROR"
  fi

  log "  [simple] Done."
}

# Return codes:
#   0 = new container accepted, no rollback needed
#   2 = a failure was detected and rollback was performed (regardless of
#       whether the rollback itself proves healthy - caller checks that)
#   3 = a failure was detected but allow_rollback was false, so the new
#       (still-failing) container was left in place; the old, stopped
#       container is left renamed aside rather than deleted, in case
#       manual recovery is wanted
restart_safe() {
  local name="$1" run_cmd="$2" allow_rollback="$3" old_id="$4" new_id="$5"
  local old_name="${name}_old_$(date +%s)"
  local old_fingerprint new_fingerprint diff_output outcome
  local orig_policy

  rollback() {
    local reason="$1"
    local rollback_ok=true
    err "  [safe] $reason Rolling back."
    $ENGINE stop "$name" >/dev/null 2>&1 || true
    $ENGINE rm -f "$name" >/dev/null 2>&1 || true
    if ! $ENGINE rename "$old_name" "$name"; then
      rollback_ok=false
    elif ! $ENGINE start "$name" >/dev/null; then
      rollback_ok=false
    fi
    if [[ "$orig_policy" == "always" ]]; then
      set_restart_policy "$name" "always" \
        || record_restart_policy_issue "$name" "could not restore policy to 'always' after rollback start: $RESTART_POLICY_ERROR"
    fi
    if $rollback_ok; then
      log "  [safe] Rolled back, $name restored and started."
    else
      err "  [safe] ROLLBACK FAILED - could not restore $name from $old_name." \
          "Manual intervention required; check for containers named" \
          "'$old_name' and '$name'."
    fi
  }

  fail_no_rollback() {
    local reason="$1"
    if [[ "$orig_policy" == "always" ]]; then
      set_restart_policy "$old_name" "always" \
        || record_restart_policy_issue "$old_name" "could not restore policy to 'always' on the stopped, left-aside container: $RESTART_POLICY_ERROR"
    fi
    err "  [safe] $reason This container was already failing before the" \
        "upgrade, so per policy it is left on the new image rather than" \
        "rolled back. The stopped previous container remains as" \
        "'$old_name' for manual recovery if needed."
  }

  log "  [safe] Capturing current config fingerprint..."
  old_fingerprint=$(normalized_config "$name")

  orig_policy=$(get_restart_policy "$name")
  if [[ "$orig_policy" == "always" ]]; then
    log "  [safe] Restart policy is 'always' - relaxing to 'unless-stopped' before stopping..."
    set_restart_policy "$name" "unless-stopped" \
      || record_restart_policy_issue "$name" "could not relax policy to 'unless-stopped' before stop: $RESTART_POLICY_ERROR"
  fi

  log "  [safe] Stopping $name..."
  $ENGINE stop "$name" >/dev/null

  outcome=$(detect_external_restart "$name" "$old_fingerprint" "$old_id" "$new_id")
  if [[ -n "$outcome" ]]; then
    err "  [safe] $name was restarted/recreated externally during the upgrade" \
        "(not by this script) - classified as: $outcome. No further action taken."
    if [[ "$orig_policy" == "always" ]]; then
      set_restart_policy "$name" "always" \
        || record_restart_policy_issue "$name" "could not restore policy to 'always' after external-restart detection: $RESTART_POLICY_ERROR"
    fi
    EXTERNAL_RESTART_OUTCOME="$outcome"
    return 0
  fi

  log "  [safe] Renaming $name -> $old_name..."
  $ENGINE rename "$name" "$old_name"

  log "  [safe] Starting new container as $name..."
  if ! eval "$run_cmd"; then
    if [[ "$allow_rollback" == "true" ]]; then
      rollback "New container failed to start."
      return 2
    else
      fail_no_rollback "New container failed to start."
      return 3
    fi
  fi

  if [[ "$orig_policy" == "always" ]]; then
    set_restart_policy "$name" "always" \
      || record_restart_policy_issue "$name" "could not restore policy to 'always' after start: $RESTART_POLICY_ERROR"
  fi

  if ! $SKIP_CONFIG_CHECK; then
    log "  [safe] Comparing recreated container's config against the original..."
    new_fingerprint=$(normalized_config "$name")
    diff_output=$(diff <(echo "$old_fingerprint") <(echo "$new_fingerprint") || true)
    if [[ -n "$diff_output" ]]; then
      err "  [safe] Config mismatch detected - likely a flag the run-command reconstruction missed:"
      echo "$diff_output" | sed 's/^/    /' >&2
      if [[ "$allow_rollback" == "true" ]]; then
        rollback "Config mismatch."
        return 2
      else
        fail_no_rollback "Config mismatch."
        return 3
      fi
    fi
    log "  [safe] Config matches original."
  fi

  log "  [safe] Monitoring $name for ${TIMEOUT}s..."
  if monitor_container "$name" "$TIMEOUT" "post-upgrade"; then
    log "  [safe] $name healthy. Removing old container $old_name..."
    $ENGINE rm -f "$old_name" >/dev/null
    log "  [safe] Done."
    return 0
  else
    if [[ "$allow_rollback" == "true" ]]; then
      rollback "$name unhealthy."
      return 2
    else
      fail_no_rollback "$name still unhealthy."
      return 3
    fi
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  # Portable equivalent of `mapfile -t CONTAINERS < <(...)` - mapfile
  # requires bash 4+ (see cross-platform-shell-compatibility requirement).
  # The `|| [[ -n "$line" ]]` clause still captures a final line even if
  # the command's output has no trailing newline.
  CONTAINERS=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    CONTAINERS+=("$line")
  done < <($ENGINE ps --format '{{.Names}}')
else
  CONTAINERS=("${TARGETS[@]}")
fi

if [[ ${#CONTAINERS[@]} -eq 0 ]]; then
  log "No running containers found."
  exit 0
fi

log "container-upgrader.sh v${SCRIPT_VERSION}${UPGRADE_BANNER_NOTE}"
log "Engine: $ENGINE | Mode: $MODE | Timeout: ${TIMEOUT}s | Precheck: ${PRECHECK_SECONDS}s | Recent-restart-threshold: ${RECENT_RESTART_THRESHOLD}s | Restart-all: $RESTART_ALL | Skip-crashing: $SKIP_CRASHING"

# IMAGE_OF, OLD_ID_OF, NEW_ID_OF_IMAGE, PULL_FAILED_IMAGE, IMAGE_CHANGED,
# PRE_STATUS, CONTAINER_CHANGED and RESULT are all maps emulated with the
# map_* functions above (see that section for why) - no declaration
# needed, they come into existence on first map_set.
ATTEMPTED_ORDER=()
IMAGES_UPGRADED=()
RESTART_POLICY_ISSUES=()

# --- Phase 1: snapshot each container's image and current image id -------
for name in "${CONTAINERS[@]}"; do
  map_set IMAGE_OF "$name" "$($ENGINE inspect --format '{{.Config.Image}}' "$name" 2>/dev/null)"
  if [[ -z "$(map_get IMAGE_OF "$name")" ]]; then
    err "Container '$name' not found (or '$ENGINE inspect' failed for it). Check the name and try again."
    continue
  fi
  map_set OLD_ID_OF "$name" "$($ENGINE inspect --format '{{.Image}}' "$name" 2>/dev/null)"
done

# Drop any names Phase 1 couldn't resolve, so later phases never see them.
VALID_CONTAINERS=()
for name in "${CONTAINERS[@]}"; do
  [[ -n "$(map_get IMAGE_OF "$name")" ]] && VALID_CONTAINERS+=("$name")
done
# The `[@]+"${...}"` form (instead of plain "${VALID_CONTAINERS[@]}") is
# required because bash 3.2's `set -u` treats expanding an empty array as
# an unbound-variable error, unlike bash 4+ - VALID_CONTAINERS legitimately
# ends up empty if every given container name was invalid.
CONTAINERS=("${VALID_CONTAINERS[@]+"${VALID_CONTAINERS[@]}"}")

if [[ ${#CONTAINERS[@]} -eq 0 ]]; then
  err "No valid containers to process."
  if $HAD_ERRORS; then
    echo ""
    echo "${COLOR_RED}${COLOR_BOLD}ERRORS OCCURRED - REVIEW THE OUTPUT${COLOR_RESET}" >&2
  fi
  exit 1
fi

# --- Phase 2: pull each unique image once ---------------------------------
# Portable equivalent of `mapfile -t UNIQUE_IMAGES < <(...)` (see the
# CONTAINERS read above for why mapfile isn't used).
UNIQUE_IMAGES=()
while IFS= read -r line || [[ -n "$line" ]]; do
  UNIQUE_IMAGES+=("$line")
done < <(map_values IMAGE_OF | sort -u)

for image in "${UNIQUE_IMAGES[@]}"; do
  [[ -z "$image" ]] && continue
  n_using=0
  for name in "${CONTAINERS[@]}"; do
    [[ "$(map_get IMAGE_OF "$name")" == "$image" ]] && n_using=$((n_using + 1))
  done
  log "== Image: $image (used by $n_using container(s)) =="
  log "Pulling..."
  # Unique per-pull temp file rather than a fixed /tmp path: a shared,
  # predictable name can be left behind by another user/run with
  # permissions that block us from writing it (Permission denied) and is
  # a symlink-race risk in a world-writable directory like /tmp.
  pull_log=$(mktemp 2>/dev/null) || pull_log="/tmp/pull_output.log.$$"
  if ! $ENGINE pull "$image" >"$pull_log" 2>&1; then
    err "  Pull failed for $image. Containers using it will be marked pull_failed. See $pull_log"
    map_set PULL_FAILED_IMAGE "$image" true
    continue
  fi
  rm -f "$pull_log"
  new_id=$($ENGINE image inspect --format '{{.Id}}' "$image" 2>/dev/null)
  map_set NEW_ID_OF_IMAGE "$image" "$new_id"

  # Representative "before" id: the first container's recorded old id.
  rep_old=""
  for name in "${CONTAINERS[@]}"; do
    if [[ "$(map_get IMAGE_OF "$name")" == "$image" ]]; then
      rep_old="$(map_get OLD_ID_OF "$name")"
      break
    fi
  done

  if [[ "$rep_old" != "$new_id" ]]; then
    map_set IMAGE_CHANGED "$image" true
    IMAGES_UPGRADED+=("$image  (${rep_old} -> ${new_id})")
    log "  Update available: $rep_old -> $new_id"
  else
    map_set IMAGE_CHANGED "$image" false
    log "  Up to date."
  fi
done

# --- Phase 3: process each container --------------------------------------
for name in "${CONTAINERS[@]}"; do
  image="$(map_get IMAGE_OF "$name")"
  log "== Checking $name ($image) =="

  if [[ "$(map_get_default PULL_FAILED_IMAGE "$image" false)" == "true" ]]; then
    log "  Skipping: image pull failed earlier."
    map_set RESULT "$name" pull_failed
    ATTEMPTED_ORDER+=("$name")
    continue
  fi

  changed="$(map_get_default IMAGE_CHANGED "$image" false)"
  map_set CONTAINER_CHANGED "$name" "$changed"
  if [[ "$changed" != "true" ]] && ! $RESTART_ALL; then
    log "  Up to date, no action."
    continue
  fi

  if [[ "$changed" == "true" ]]; then
    log "  Update available for this container's image."
  else
    log "  No image update, but --restart-all set: recreating anyway."
  fi

  log "  Checking pre-upgrade status (observing for ${PRECHECK_SECONDS}s)..."
  pre_status=$(check_pre_status "$name")
  map_set PRE_STATUS "$name" "$pre_status"
  log "  Pre-upgrade status: $pre_status"

  if [[ "$pre_status" == "crashing" ]] && $SKIP_CRASHING; then
    log "  Skipping: container was already crashing and --skip-crashing is set."
    map_set RESULT "$name" skipped_crashing
    ATTEMPTED_ORDER+=("$name")
    continue
  fi

  log "  Capturing current run command..."
  run_cmd=$(get_run_command "$name" "$(map_get OLD_ID_OF "$name")")

  systemd_unit=""
  systemd_unit_source=""
  if ! $SKIP_SYSTEMD_RESTART; then
    if ! $SKIP_MANUAL_UNIT_RESTART; then
      systemd_unit="$(get_manual_systemd_unit "$name")"
      [[ -n "$systemd_unit" ]] && systemd_unit_source="manual"
    fi
    if [[ -z "$systemd_unit" ]] && ! $SKIP_QUADLET_RESTART; then
      systemd_unit="$(get_quadlet_unit "$name")"
      [[ -n "$systemd_unit" ]] && systemd_unit_source="quadlet"
    fi
  fi

  systemd_unit_scope=""
  systemd_unit_error=""
  if [[ -n "$systemd_unit" ]]; then
    systemd_unit_scope="$(resolve_systemd_scope "$name" "$ENGINE" "$systemd_unit")"
    case "$systemd_unit_scope" in
      systemd_unit_scope_mismatch|systemd_unit_not_found|systemd_unit_permission_denied)
        systemd_unit_error="$systemd_unit_scope"
        systemd_unit_scope=""
        ;;
    esac
  fi

  if [[ -n "$systemd_unit_error" ]]; then
    err "  $name: systemd-unit restart cannot proceed ($systemd_unit_error) -" \
        "leaving the container untouched, no fallback restart attempted."
    map_set RESULT "$name" "$systemd_unit_error"
    ATTEMPTED_ORDER+=("$name")
    continue
  fi

  if [[ -z "$run_cmd" && -z "$systemd_unit" ]]; then
    err "  Failed to capture run command for $name, skipping to avoid data loss."
    map_set RESULT "$name" reconstruct_failed
    ATTEMPTED_ORDER+=("$name")
    continue
  fi

  mode="$MODE"
  auto_remove="$(get_auto_remove "$name")"
  if [[ "$mode" == "safe" && "$auto_remove" == "true" ]]; then
    log "  Container has AutoRemove (--rm) enabled; safe mode's rollback requires" \
        "the old container to survive stopping, which --rm prevents. Using" \
        "simple mode for $name instead."
    mode="simple"
  fi

  if $DRY_RUN; then
    if [[ -n "$systemd_unit" ]]; then
      log "  [dry-run] Would restart $name via systemd unit '$systemd_unit'" \
          "(source: $systemd_unit_source, scope: $systemd_unit_scope)," \
          "falling back to $mode mode if that doesn't succeed."
      [[ -n "$run_cmd" ]] && log "    $run_cmd"
    else
      log "  [dry-run] Would restart $name in $mode mode (pre-status: $pre_status) with:"
      log "    $run_cmd"
    fi
    map_set RESULT "$name" dry_run
    ATTEMPTED_ORDER+=("$name")
    continue
  fi

  ATTEMPTED_ORDER+=("$name")
  allow_rollback="true"
  [[ "$pre_status" == "crashing" ]] && allow_rollback="false"

  old_id="$(map_get OLD_ID_OF "$name")"
  new_id="$(map_get NEW_ID_OF_IMAGE "$image")"
  EXTERNAL_RESTART_OUTCOME=""

  systemd_unit_succeeded=false
  if [[ -n "$systemd_unit" ]]; then
    outcome=$(restart_via_systemd_unit "$name" "$systemd_unit" "$new_id" "$systemd_unit_scope" "$systemd_unit_source")
    if [[ "$outcome" == upgraded_via_* ]]; then
      EXTERNAL_RESTART_OUTCOME="$outcome"
      systemd_unit_succeeded=true
    fi
  fi

  if ! $systemd_unit_succeeded; then
    if [[ -z "$run_cmd" ]]; then
      err "  Failed to capture run command for $name, and the systemd-unit restart" \
          "did not succeed either - skipping to avoid data loss."
      map_set RESULT "$name" reconstruct_failed
      continue
    fi
    if [[ "$mode" == "simple" ]]; then
      restart_simple "$name" "$run_cmd" "$auto_remove" "$old_id" "$new_id"
    else
      rc=0
      restart_safe "$name" "$run_cmd" "$allow_rollback" "$old_id" "$new_id" || rc=$?
    fi
  fi

  if [[ -n "$EXTERNAL_RESTART_OUTCOME" ]]; then
    map_set RESULT "$name" "$EXTERNAL_RESTART_OUTCOME"
  else
    if is_running_and_healthy "$name"; then
      final_status="healthy"
    else
      final_status="failing"
    fi

    if [[ "$pre_status" == "healthy" ]]; then
      if [[ "$final_status" == "healthy" ]]; then
        if [[ "$mode" == "safe" && "${rc:-0}" -eq 2 ]]; then
          map_set RESULT "$name" rolled_back_working
        elif [[ "$(map_get_default CONTAINER_CHANGED "$name" false)" == "true" ]]; then
          map_set RESULT "$name" upgraded
        else
          map_set RESULT "$name" restarted
        fi
      else
        map_set RESULT "$name" now_failing
      fi
    else
      if [[ "$final_status" == "healthy" ]]; then
        map_set RESULT "$name" recovered
      else
        map_set RESULT "$name" still_failing
      fi
    fi
  fi

  result="$(map_get RESULT "$name")"
  case "$result" in
    now_failing|still_failing|reverted_externally|external_config_discrepancy| \
    systemd_unit_scope_mismatch|systemd_unit_not_found|systemd_unit_permission_denied)
      err "  Final classification for $name: $result" ;;
    *)
      log "  Final classification for $name: $result" ;;
  esac
  unset rc
done

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

echo ""
log "===== Summary ====="

if $DRY_RUN; then
  log "Dry run - no changes were made."
  echo ""
  log "Images that would be upgraded (${#IMAGES_UPGRADED[@]}):"
  if [[ ${#IMAGES_UPGRADED[@]} -eq 0 ]]; then
    log "  (none)"
  else
    for img in "${IMAGES_UPGRADED[@]}"; do
      log "  - $img"
    done
  fi
  echo ""
  log "Containers that would be attempted (${#ATTEMPTED_ORDER[@]}):"
  # See the VALID_CONTAINERS comment above for why "[@]+...[@]" is needed:
  # ATTEMPTED_ORDER is legitimately empty when every container is already
  # up to date.
  for name in "${ATTEMPTED_ORDER[@]+"${ATTEMPTED_ORDER[@]}"}"; do
    log "  - $name (image: $(map_get IMAGE_OF "$name"), pre-status: $(map_get_default PRE_STATUS "$name" n/a))"
  done
  if $HAD_ERRORS; then
    echo ""
    echo "${COLOR_RED}${COLOR_BOLD}ERRORS OCCURRED - REVIEW THE OUTPUT${COLOR_RESET}" >&2
    exit 1
  fi
  exit 0
fi

count_upgraded=0
count_restarted=0
count_rolled_back_working=0
count_now_failing=0
count_recovered=0
count_still_failing=0
count_pull_failed=0
count_reconstruct_failed=0
count_skipped_crashing=0
count_upgraded_externally=0
count_reverted_externally=0
count_external_config_discrepancy=0
count_upgraded_via_quadlet=0
count_upgraded_via_manual_unit=0
count_systemd_unit_scope_mismatch=0
count_systemd_unit_not_found=0
count_systemd_unit_permission_denied=0

# See the VALID_CONTAINERS comment above for why "[@]+...[@]" is needed:
# ATTEMPTED_ORDER is legitimately empty when every container is already
# up to date.
for name in "${ATTEMPTED_ORDER[@]+"${ATTEMPTED_ORDER[@]}"}"; do
  case "$(map_get RESULT "$name")" in
    upgraded) count_upgraded=$((count_upgraded + 1)) ;;
    restarted) count_restarted=$((count_restarted + 1)) ;;
    rolled_back_working) count_rolled_back_working=$((count_rolled_back_working + 1)) ;;
    now_failing) count_now_failing=$((count_now_failing + 1)) ;;
    recovered) count_recovered=$((count_recovered + 1)) ;;
    still_failing) count_still_failing=$((count_still_failing + 1)) ;;
    pull_failed) count_pull_failed=$((count_pull_failed + 1)) ;;
    reconstruct_failed) count_reconstruct_failed=$((count_reconstruct_failed + 1)) ;;
    skipped_crashing) count_skipped_crashing=$((count_skipped_crashing + 1)) ;;
    upgraded_externally) count_upgraded_externally=$((count_upgraded_externally + 1)) ;;
    reverted_externally) count_reverted_externally=$((count_reverted_externally + 1)) ;;
    external_config_discrepancy) count_external_config_discrepancy=$((count_external_config_discrepancy + 1)) ;;
    upgraded_via_quadlet) count_upgraded_via_quadlet=$((count_upgraded_via_quadlet + 1)) ;;
    upgraded_via_manual_unit) count_upgraded_via_manual_unit=$((count_upgraded_via_manual_unit + 1)) ;;
    systemd_unit_scope_mismatch) count_systemd_unit_scope_mismatch=$((count_systemd_unit_scope_mismatch + 1)) ;;
    systemd_unit_not_found) count_systemd_unit_not_found=$((count_systemd_unit_not_found + 1)) ;;
    systemd_unit_permission_denied) count_systemd_unit_permission_denied=$((count_systemd_unit_permission_denied + 1)) ;;
  esac
done

log "Images upgraded: ${#IMAGES_UPGRADED[@]}"
log "Containers upgraded successfully (image changed): $count_upgraded"
if [[ $count_restarted -gt 0 ]]; then
  log "Containers restarted with no image change (--restart-all, still working): $count_restarted"
fi
log "Containers where upgrade failed and was rolled back (now working): $count_rolled_back_working"
if [[ $count_now_failing -gt 0 ]]; then
  err "Containers that were working before and are now failing (rollback did not resolve it): $count_now_failing"
else
  log "Containers that were working before and are now failing (rollback did not resolve it): $count_now_failing"
fi
log "Containers that were failing before the upgrade and are now working: $count_recovered"
if [[ $count_still_failing -gt 0 ]]; then
  err "Containers that were failing before the upgrade and are still failing: $count_still_failing"
else
  log "Containers that were failing before the upgrade and are still failing: $count_still_failing"
fi
if [[ $count_pull_failed -gt 0 || $count_reconstruct_failed -gt 0 ]]; then
  err "(also: $count_pull_failed image-pull-failed, $count_reconstruct_failed reconstruct-failed, $count_skipped_crashing skipped-crashing - not counted above)"
elif [[ $count_skipped_crashing -gt 0 ]]; then
  log "(also: $count_pull_failed image-pull-failed, $count_reconstruct_failed reconstruct-failed, $count_skipped_crashing skipped-crashing - not counted above)"
fi
if [[ $((count_upgraded_externally + count_reverted_externally + count_external_config_discrepancy)) -gt 0 ]]; then
  log "Containers upgraded externally (by systemd/Quadlet or another supervisor, not this script): $count_upgraded_externally"
  if [[ $((count_reverted_externally + count_external_config_discrepancy)) -gt 0 ]]; then
    err "Containers where an external restart reverted to the old image or showed a config mismatch: $((count_reverted_externally + count_external_config_discrepancy))"
  fi
fi
if [[ $count_upgraded_via_quadlet -gt 0 ]]; then
  log "Containers upgraded via Quadlet (systemctl restart, initiated by this script): $count_upgraded_via_quadlet"
fi
if [[ $count_upgraded_via_manual_unit -gt 0 ]]; then
  log "Containers upgraded via a manual systemd.unit label (systemctl restart, initiated by this script): $count_upgraded_via_manual_unit"
fi
if [[ $((count_systemd_unit_scope_mismatch + count_systemd_unit_not_found + count_systemd_unit_permission_denied)) -gt 0 ]]; then
  err "Containers left untouched - systemd-unit restart could not proceed safely: $((count_systemd_unit_scope_mismatch + count_systemd_unit_not_found + count_systemd_unit_permission_denied))" \
      "($count_systemd_unit_scope_mismatch scope-mismatch, $count_systemd_unit_not_found unit-not-found, $count_systemd_unit_permission_denied permission-denied)"
fi

echo ""
log "Images upgraded:"
if [[ ${#IMAGES_UPGRADED[@]} -eq 0 ]]; then
  log "  (none)"
else
  for img in "${IMAGES_UPGRADED[@]}"; do
    log "  - $img"
  done
fi

echo ""
log "Containers upgraded or attempted, sorted by status:"
# Human-readable label for a RESULT status. A plain case statement in
# place of bash 4+'s `declare -A` lookup table (see the map_* functions'
# header comment for why bash 4+ features are avoided throughout).
status_label() {
  case "$1" in
    upgraded) echo "Upgraded successfully (image changed)" ;;
    restarted) echo "Restarted, no image change (--restart-all)" ;;
    rolled_back_working) echo "Upgrade failed, rolled back, now working" ;;
    recovered) echo "Was failing before, now working" ;;
    now_failing) echo "Was working before, now failing (unresolved)" ;;
    still_failing) echo "Was failing before, still failing" ;;
    pull_failed) echo "Image pull failed (not attempted)" ;;
    reconstruct_failed) echo "Could not reconstruct run command (not attempted)" ;;
    skipped_crashing) echo "Skipped (was crashing, --skip-crashing set)" ;;
    upgraded_externally) echo "Upgraded externally (systemd/Quadlet or another supervisor restarted it)" ;;
    reverted_externally) echo "Restarted externally but reverted to the old image" ;;
    external_config_discrepancy) echo "Restarted externally with a mismatched config" ;;
    upgraded_via_quadlet) echo "Upgraded via Quadlet (systemctl restart, initiated by this script)" ;;
    upgraded_via_manual_unit) echo "Upgraded via a manual systemd.unit label (systemctl restart, initiated by this script)" ;;
    systemd_unit_scope_mismatch) echo "Systemd-unit restart not attempted: systemd.scope label mismatch" ;;
    systemd_unit_not_found) echo "Systemd-unit restart not attempted: unit file not found at resolved scope" ;;
    systemd_unit_permission_denied) echo "Systemd-unit restart not attempted: system scope requires running as root" ;;
  esac
}
STATUS_ORDER=(upgraded restarted rolled_back_working recovered now_failing still_failing pull_failed reconstruct_failed skipped_crashing upgraded_externally reverted_externally external_config_discrepancy upgraded_via_quadlet upgraded_via_manual_unit systemd_unit_scope_mismatch systemd_unit_not_found systemd_unit_permission_denied)
ERROR_STATUSES=(now_failing still_failing pull_failed reconstruct_failed reverted_externally external_config_discrepancy systemd_unit_scope_mismatch systemd_unit_not_found systemd_unit_permission_denied)

is_error_status() {
  local s="$1"
  for e in "${ERROR_STATUSES[@]}"; do
    [[ "$s" == "$e" ]] && return 0
  done
  return 1
}

for status in "${STATUS_ORDER[@]}"; do
  any=false
  # See the VALID_CONTAINERS comment above for why "[@]+...[@]" is needed.
  for name in "${ATTEMPTED_ORDER[@]+"${ATTEMPTED_ORDER[@]}"}"; do
    if [[ "$(map_get RESULT "$name")" == "$status" ]]; then
      if ! $any; then
        if is_error_status "$status"; then
          err "  $(status_label "$status"):"
        else
          log "  $(status_label "$status"):"
        fi
        any=true
      fi
      if is_error_status "$status"; then
        err "    - $name (image: $(map_get IMAGE_OF "$name"))"
      else
        log "    - $name (image: $(map_get IMAGE_OF "$name"))"
      fi
    fi
  done
done

if [[ ${#RESTART_POLICY_ISSUES[@]} -gt 0 ]]; then
  echo ""
  err "Containers where the restart-policy safety step failed (${#RESTART_POLICY_ISSUES[@]}) - policy may not match its pre-upgrade state:"
  for issue in "${RESTART_POLICY_ISSUES[@]}"; do
    err "  - $issue"
  done
fi

log "All containers checked."

if $HAD_ERRORS; then
  echo ""
  echo "${COLOR_RED}${COLOR_BOLD}ERRORS OCCURRED - REVIEW THE OUTPUT${COLOR_RESET}" >&2
  exit 1
fi

exit 0
