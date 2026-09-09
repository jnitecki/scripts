#!/usr/bin/env bash
# Version: 1.0.7
# Category: containers
# Description: Docker image upgrade automation with rollback support
#
# Version history (bump the patch number - C in A.B.C - on every change):
#   1.0.0 - crash detection, pre/post classification, shared-image
#           handling, summary report, colored error visibility, versioning
#   1.0.1 - exit code reflects whether any errors occurred (1 if so, 0
#           if the run was clean)
#   1.0.2 - renamed from docker-update-containers.sh; version is now read
#           from this header comment at runtime instead of being
#           duplicated in a separate variable, so the two can't drift
#   1.0.3 - added --recent-restart-threshold: a fast, no-wait pre-check
#           using RestartCount and the container's most recent (re)start
#           time (not original creation time) to catch crash loops
#           slower than --precheck-seconds, plus detection of a
#           healthcheck stuck in "starting" past the same threshold
#   1.0.4 - separated "upgraded" (image actually changed) from
#           "restarted" (no image change, only recreated because of
#           --restart-all) in both the summary and the status list,
#           instead of reporting both as "upgraded successfully"
#   1.0.5 - unrecognized options (e.g. a typo'd flag) are now rejected
#           immediately with a clear error instead of silently being
#           treated as a container name; a container name that doesn't
#           actually exist is now also reported clearly instead of
#           crashing later with a bash "bad array subscript" error
#   1.0.6 - header updated to conform to the repo-wide script-header
#           convention (separate Version/Category/Description lines in
#           place of the old inline "container-upgrade.sh - vX.Y.Z" line);
#           version is now parsed from the "# Version:" line
#   1.0.7 - made bash-3.2-safe per the repo-wide cross-platform-shell-
#           compatibility requirement (macOS's stock /bin/bash is 3.2):
#           replaced all `declare -A` associative arrays with a portable
#           map_* emulation (see that section's comment), replaced both
#           `mapfile` calls with plain while-read loops, and replaced
#           `${arr[@]}` expansions of arrays that can legitimately be
#           empty (VALID_CONTAINERS, ATTEMPTED_ORDER) with the
#           `${arr[@]+"${arr[@]}"}` form, since bash 3.2's `set -u` treats
#           expanding an empty array as an unbound-variable error
#
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
#             at all instead).
#
# Before touching anything, each targeted container is checked for
# --precheck-seconds to see whether it is already crashing. This
# pre-upgrade status, plus a post-upgrade check, drives both the
# rollback policy above and the final summary report.
#
# Requires: docker (or podman, see --engine) and jq. The run command for
# each container is reconstructed locally from `<engine> inspect` JSON
# (no external image or socket-mounted helper needed).
#
# Reconstruction covers: name, hostname (if overridden), user, workdir
# (if overridden), env vars (only those added/changed vs. the image
# default), labels (added/changed vs. image default), published ports,
# bind/volume/tmpfs mounts, network mode (if non-default), restart
# policy, privileged, cap-add/cap-drop, devices, extra hosts, memory
# limit, cpu limit, security-opt, dns, tty/stdin flags, entrypoint
# override (first element only - see note below), and cmd.
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
#
# Usage:
#   ./container-upgrade.sh [options] [container names...]
#
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
#
# If no container names are given, all running containers are targeted.
#
# Output: errors (failed pulls, failed reconstructions, failed starts,
# config mismatches, rollbacks, and any container ending up still broken)
# are printed in red/bold when the terminal supports color. If any
# occurred, the very last line of output is "ERRORS OCCURRED - REVIEW
# THE OUTPUT" in caps, also colored.

set -uo pipefail

MODE="safe"
TIMEOUT=30
PRECHECK_SECONDS=5
RECENT_RESTART_THRESHOLD=180
ENGINE=""
ENGINE_EXPLICIT=false
RESTART_ALL=false
SKIP_CONFIG_CHECK=false
SKIP_CRASHING=false
DRY_RUN=false
TARGETS=()

# Version lives only in the header comment above (line 2: "# Version: X.Y.Z").
# Read it from here rather than duplicating it in a variable, so the two
# can never drift out of sync. Falls back to "unknown" if the header is
# ever restructured and the pattern no longer matches.
version_line=$(grep -m1 -E '^# Version: [0-9]+\.[0-9]+\.[0-9]+$' "$0" 2>/dev/null || true)
SCRIPT_VERSION="${version_line##*: }"
[[ -z "$SCRIPT_VERSION" ]] && SCRIPT_VERSION="unknown"
HAD_ERRORS=false

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

usage() {
  sed -n '2,138p' "$0"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --restart-all) RESTART_ALL=true; shift ;;
    --skip-config-check) SKIP_CONFIG_CHECK=true; shift ;;
    --skip-crashing) SKIP_CRASHING=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
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
    --engine)
      ENGINE="${2:-}"
      ENGINE_EXPLICIT=true
      if [[ "$ENGINE" != "docker" && "$ENGINE" != "podman" ]]; then
        err "Invalid --engine: $ENGINE (expected docker|podman)"; exit 1
      fi
      shift 2 ;;
    -h|--help) usage ;;
    -*)
      err "Unknown option: $1"
      err "Run with --help to see valid options."
      exit 1 ;;
    *) TARGETS+=("$1"); shift ;;
  esac
done

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

# Builds an `<engine> run ...` command line reproducing container $1's
# settings, diffed against image $2's own baked-in defaults (so we only
# emit overrides, not everything the image already provides).
get_run_command() {
  local name="$1" image="$2"
  local cjson ijson args quoted

  cjson=$($ENGINE inspect --format '{{json .}}' "$name" 2>/dev/null) || return 1
  ijson=$($ENGINE image inspect --format '{{json .Config}}' "$image" 2>/dev/null) || ijson='{}'

  args=$(jq -n --argjson c "$cjson" --argjson ic "$ijson" '
    def arr(x): if x == null then [] else x end;
    ( ($c.Id // "")[0:12] ) as $shortid |

    ["-d"] +

    (if ($c.Name // "") != "" then ["--name", ($c.Name | ltrimstr("/"))] else [] end) +

    (if (($c.Config.Hostname // "") != "") and ($c.Config.Hostname != $shortid)
       then ["--hostname", $c.Config.Hostname] else [] end) +

    (if (($c.Config.User // "") != "") then ["--user", $c.Config.User] else [] end) +

    (if (($c.Config.WorkingDir // "") != "") and ($c.Config.WorkingDir != ($ic.WorkingDir // ""))
       then ["--workdir", $c.Config.WorkingDir] else [] end) +

    ( [ (arr($c.Config.Env) - arr($ic.Env))[] | ("--env", .) ] | flatten ) +

    ( ( (($c.Config.Labels // {}) | to_entries) - (($ic.Labels // {}) | to_entries) )
      | map(["--label", (.key + "=" + .value)]) | flatten ) +

    ( [ ($c.HostConfig.PortBindings // {}) | to_entries[] as $e |
        $e.value[]? |
        (if (.HostPort // "") == "" then
           $e.key
         else
           (if ((.HostIp // "") != "" and (.HostIp) != "0.0.0.0") then (.HostIp + ":") else "" end)
           + .HostPort + ":" + $e.key
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

    (if ($c.Config.Entrypoint != null) and ($c.Config.Entrypoint != ($ic.Entrypoint // null))
       then ["--entrypoint", ($c.Config.Entrypoint[0] // "")] else [] end) +

    [$c.Config.Image] +

    (arr($c.Config.Cmd))
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
normalized_config() {
  local name="$1"
  $ENGINE inspect --format '{{json .}}' "$name" 2>/dev/null | jq -S '
    {
      Config: {
        User: .Config.User,
        WorkingDir: .Config.WorkingDir,
        Tty: .Config.Tty,
        OpenStdin: .Config.OpenStdin,
        Entrypoint: .Config.Entrypoint,
        Cmd: .Config.Cmd,
        ExposedPorts: ((.Config.ExposedPorts // {}) | keys | sort)
      },
      HostConfig: (.HostConfig | {
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
      Mounts: ((.Mounts // []) | map(
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
# Restart strategies
# ---------------------------------------------------------------------------

restart_simple() {
  local name="$1" run_cmd="$2"
  log "  [simple] Stopping $name..."
  $ENGINE stop "$name" >/dev/null
  log "  [simple] Removing $name..."
  $ENGINE rm "$name" >/dev/null
  log "  [simple] Starting new container..."
  eval "$run_cmd"
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
  local name="$1" run_cmd="$2" allow_rollback="$3"
  local old_name="${name}_old_$(date +%s)"
  local old_fingerprint new_fingerprint diff_output

  rollback() {
    local reason="$1"
    err "  [safe] $reason Rolling back."
    $ENGINE stop "$name" >/dev/null 2>&1 || true
    $ENGINE rm -f "$name" >/dev/null 2>&1 || true
    $ENGINE rename "$old_name" "$name"
    $ENGINE start "$name" >/dev/null
    log "  [safe] Rolled back, $name restored and started."
  }

  fail_no_rollback() {
    local reason="$1"
    err "  [safe] $reason This container was already failing before the" \
        "upgrade, so per policy it is left on the new image rather than" \
        "rolled back. The stopped previous container remains as" \
        "'$old_name' for manual recovery if needed."
  }

  log "  [safe] Capturing current config fingerprint..."
  old_fingerprint=$(normalized_config "$name")

  log "  [safe] Stopping $name..."
  $ENGINE stop "$name" >/dev/null

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

log "container-upgrade.sh v$SCRIPT_VERSION"
log "Engine: $ENGINE | Mode: $MODE | Timeout: ${TIMEOUT}s | Precheck: ${PRECHECK_SECONDS}s | Recent-restart-threshold: ${RECENT_RESTART_THRESHOLD}s | Restart-all: $RESTART_ALL | Skip-crashing: $SKIP_CRASHING"

# IMAGE_OF, OLD_ID_OF, NEW_ID_OF_IMAGE, PULL_FAILED_IMAGE, IMAGE_CHANGED,
# PRE_STATUS, CONTAINER_CHANGED and RESULT are all maps emulated with the
# map_* functions above (see that section for why) - no declaration
# needed, they come into existence on first map_set.
ATTEMPTED_ORDER=()
IMAGES_UPGRADED=()

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
  if ! $ENGINE pull "$image" >/tmp/pull_output.log 2>&1; then
    err "  Pull failed for $image. Containers using it will be marked pull_failed. See /tmp/pull_output.log"
    map_set PULL_FAILED_IMAGE "$image" true
    continue
  fi
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
  run_cmd=$(get_run_command "$name" "$image")
  if [[ -z "$run_cmd" ]]; then
    err "  Failed to capture run command for $name, skipping to avoid data loss."
    map_set RESULT "$name" reconstruct_failed
    ATTEMPTED_ORDER+=("$name")
    continue
  fi

  if $DRY_RUN; then
    log "  [dry-run] Would restart $name in $MODE mode (pre-status: $pre_status) with:"
    log "    $run_cmd"
    map_set RESULT "$name" dry_run
    ATTEMPTED_ORDER+=("$name")
    continue
  fi

  ATTEMPTED_ORDER+=("$name")
  allow_rollback="true"
  [[ "$pre_status" == "crashing" ]] && allow_rollback="false"

  if [[ "$MODE" == "simple" ]]; then
    restart_simple "$name" "$run_cmd"
  else
    rc=0
    restart_safe "$name" "$run_cmd" "$allow_rollback" || rc=$?
  fi

  if is_running_and_healthy "$name"; then
    final_status="healthy"
  else
    final_status="failing"
  fi

  if [[ "$pre_status" == "healthy" ]]; then
    if [[ "$final_status" == "healthy" ]]; then
      if [[ "$MODE" == "safe" && "${rc:-0}" -eq 2 ]]; then
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

  result="$(map_get RESULT "$name")"
  case "$result" in
    now_failing|still_failing)
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
  esac
}
STATUS_ORDER=(upgraded restarted rolled_back_working recovered now_failing still_failing pull_failed reconstruct_failed skipped_crashing)
ERROR_STATUSES=(now_failing still_failing pull_failed reconstruct_failed)

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

log "All containers checked."

if $HAD_ERRORS; then
  echo ""
  echo "${COLOR_RED}${COLOR_BOLD}ERRORS OCCURRED - REVIEW THE OUTPUT${COLOR_RESET}" >&2
  exit 1
fi

exit 0
