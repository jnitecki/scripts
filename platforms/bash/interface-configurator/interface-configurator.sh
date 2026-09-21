#!/usr/bin/env bash
# Version: 0.0.1-dev6
# Category: networking
# Description: Watches a matching network interface and runs registered add/remove commands as it transitions
# Upgrade-Source: github.com/jnitecki/scripts@bash/interface-configurator
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
# see script-maintenance-convention.md section 3. A script with no stable
# release yet (this one) starts that same way, from the section 4
# bootstrap baseline (0.0.0 -> first real version 0.0.1-dev1):
#   0.0.1 (in progress - currently 0.0.1-dev6) - initial implementation:
#           --install/--uninstall/--run, shared systemd template unit (a
#           persistent per-interface watcher, bound to the interface's own
#           device unit), per-pattern udev rule, add/remove command pairs
#           applied across the interface's whole lifecycle (up, down,
#           address change, removal), self-upgrade. watch_iface's ip
#           monitor coprocess no longer crashes the watcher on an unbound
#           variable if it exits unexpectedly - it's now detected, logged,
#           and restarted (bounded), and its stderr is no longer discarded.
#           Every reference to the coprocess's PID (not just the watch
#           loop's own read) is now guarded the same way, including right
#           after starting/restarting it - a coprocess that dies before
#           even that first log line ran was still an unguarded crash.
#           --add/--remove commands now also get IP4_ADDRESS/IP4_NETMASK/
#           IP4_PREFIX/IP4_GATEWAY and IP6_ADDRESS/IP6_PREFIX/IP6_GATEWAY
#           exported alongside IFACE - convenience shortcuts for the
#           single-address/default-route-only case. An add command's
#           values are stashed under /run so a later remove command still
#           sees them even once the interface itself is gone. The
#           per-pattern rule config file is now plain-text (one PATTERN=/
#           ADD=/REMOVE= per line, unescaped, no _<n>/*_COUNT bookkeeping)
#           read by simple line parsing rather than sourced as bash.
# HELP:IDENTITY:END
#
# HELP:INTRO:BEGIN
# Lets an operator register add/remove shell commands to run automatically
# as a network interface whose name matches a given glob pattern
# transitions through its lifecycle - via udev hotplug, or already present
# at install time. A single generated systemd service instance watches
# each matching interface for as long as it exists:
#
#   - becomes ready (administratively up, carrier present) -> add commands
#   - goes down (still present) -> remove commands
#   - becomes ready again -> add commands (again)
#   - an address changes while ready -> remove then add (full reapply)
#   - is removed entirely -> remove commands, then the watcher exits
#
# Registration (which patterns exist, and their commands) is backed by a
# generated udev rule plus a shared systemd template service, so it
# survives reboots without this script needing to run persistently in the
# background itself - only each active watcher instance does, one per
# currently-present matching interface.
#
# Linux-only (requires systemd + udev) - exits immediately with a clear
# error on any other platform.
# HELP:INTRO:END
#
# HELP:USAGE:BEGIN
# Usage:
#   ./interface-configurator.sh --install <interface_pattern> \
#       --add <command> [--add <command>...] \
#       [--remove <command> [--remove <command>...]]
#   ./interface-configurator.sh --uninstall [<interface_pattern>]
#   ./interface-configurator.sh --run <interface_name>
# HELP:USAGE:END
#
# HELP:CORE-OPTIONS:BEGIN
# Options (mutually exclusive - exactly one required):
#   --install <interface_pattern> --add <command> [--add <command>...]
#                        [--remove <command> [--remove <command>...]]
#                        Register one or more add commands (run whenever a
#                        network interface whose name glob-matches
#                        <interface_pattern>, e.g. 'eth*', becomes ready or
#                        becomes ready again) and, optionally, one or more
#                        remove commands (run whenever it goes down, its
#                        address changes - remove then add - or it's
#                        removed entirely). Each is a single shell command
#                        string. Upsert semantics: installing a pattern
#                        that's already registered replaces its whole
#                        add/remove list. Requires root. Applies
#                        immediately to any already-present matching
#                        interfaces, in addition to registering for future
#                        hotplug events. Example:
#                          ./interface-configurator.sh --install 'eth*' \
#                            --add 'ip route replace 10.0.0.0/24 via 10.0.0.1 dev "$IFACE"' \
#                            --remove 'ip route del 10.0.0.0/24 dev "$IFACE"'
#   --uninstall [<interface_pattern>]
#                        Remove a previously registered pattern (or, with
#                        no argument, every registered pattern), then stop
#                        the watcher for any interface no longer matched
#                        by any remaining pattern - without running its
#                        remove commands (registration is deleted first,
#                        so there's nothing left for the stopped watcher
#                        to find and run; whatever its add commands already
#                        applied is left as-is). Requires root. Removing a
#                        pattern that isn't registered is not an error -
#                        logged as a no-op.
#   --run <interface_name>
#                        Internal - invoked by the generated systemd
#                        service, not intended for direct interactive use.
#                        Waits for the interface to become ready, runs
#                        every matching pattern's add commands, then keeps
#                        watching that interface (its own long-running
#                        process, one per interface) for further
#                        transitions until it's removed or this process is
#                        stopped. Not hidden (documented here for
#                        transparency), but not a typical operator action.
# HELP:CORE-OPTIONS:END
#
# HELP:UPGRADE-OPTIONS:BEGIN
# Self-upgrade options (this script updating its own file):
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
#                        --install/--uninstall/--run work. Not combinable
#                        with --upgrade-check.
#   --no-autoupdate      Shortcut for --upgrade-type none: skip self-upgrade
#                        entirely for this run. Not combinable with
#                        --upgrade-type. Always in effect for --run
#                        (baked into the generated systemd unit - a
#                        hotplug-triggered run never self-upgrades).
# HELP:UPGRADE-OPTIONS:END
#
# HELP:TAIL:BEGIN
# <interface_pattern> uses shell glob syntax (*, ?, [...]) - the same
# syntax udev's own KERNEL== match and bash's [[ $name == $pattern ]] both
# use, so the same pattern string works in both places unmodified. Every
# add/remove command runs with IFACE exported and the interface name also
# passed as $1.
# HELP:TAIL:END
#
# HELP:UPGRADE-EXPLANATION:BEGIN
# Self-upgrade: on every --install/--uninstall invocation (unless
# --upgrade-type none / --no-autoupdate is given), the script checks
# github.com/jnitecki/scripts for a newer release of itself and, if
# eligible, upgrades - see docs/requirements/generic/script-upgrade-
# convention.md for the full behavior (apply modes, --upgrade-level,
# --upgrade-check, --upgrade-only). --run never self-upgrades (see
# --no-autoupdate above).
# HELP:UPGRADE-EXPLANATION:END
#
# HELP:OUTPUT:BEGIN
# Output: progress and errors are logged to stderr, one timestamped line
# each. Exit code reflects whether the run completed cleanly: 0 if no
# errors occurred, non-zero otherwise. A failed or skipped self-upgrade
# check never counts as an error for this purpose. --run itself normally
# only exits once its interface is removed (exit 0); an individual
# add/remove command failing while a watcher is running is logged but
# does not stop the watcher.
# HELP:OUTPUT:END

set -uo pipefail

# --- Domain paths (overridable via environment for testing) ----------------
: "${IC_SYSTEMD_DIR:=/etc/systemd/system}"
: "${IC_UDEV_RULES_DIR:=/etc/udev/rules.d}"
: "${IC_RULES_DIR:=/etc/interface-configurator/rules.d}"
: "${IC_STATE_DIR:=/run/interface-configurator}"
: "${IC_SYS_CLASS_NET:=/sys/class/net}"
: "${IC_READY_TIMEOUT_SECONDS:=300}"

# Version lives only in the header comment above (line 2). Read it from
# here rather than duplicating it in a variable, so the two can never
# drift out of sync. Falls back to "unknown" if the header is ever
# restructured and the pattern no longer matches.
version_line=$(grep -m1 -E '^# Version: [0-9]+\.[0-9]+\.[0-9]+(-[a-z]+[0-9]*)?$' "$0" 2>/dev/null || true)
SCRIPT_VERSION="${version_line##*: }"
[ -z "$SCRIPT_VERSION" ] && SCRIPT_VERSION="unknown"

# Identity used by the self-upgrade block below (see
# docs/requirements/generic/script-upgrade-convention.md) - matches this
# script's own "# Upgrade-Source:" header line and its path under platforms/.
SCRIPT_PATH="$0"
SCRIPT_LANG="bash"
SCRIPT_NAME="interface-configurator"
UPGRADE_HOST="github.com"
UPGRADE_OWNER="jnitecki"
UPGRADE_REPO="scripts"
UPGRADE_TIMEOUT=10
UPGRADE_COOLDOWN_SECONDS=1200
UPGRADE_BANNER_NOTE=""

# Fully resolved absolute path, baked into the generated systemd unit's
# ExecStart at --install time - distinct from SCRIPT_PATH ("$0" as
# invoked, used only by the self-upgrade block's own filesystem-
# eligibility checks, same as container-upgrader.sh's own convention).
# Linux-only per this script's platform carve-out, so GNU `readlink -f` is
# safe to rely on directly with no BSD fallback needed.
RESOLVED_SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
err() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }

# =============================================================================
# Platform + privilege checks
# =============================================================================

# Linux + systemd + udev only (this script inherently solves an
# OS-specific problem, per the carve-out in docs/requirements/generic/
# cross-platform-shell-compatibility.md section 0).
require_platform() {
  local missing=()
  command -v systemctl >/dev/null 2>&1 || missing+=("systemctl")
  command -v udevadm >/dev/null 2>&1 || missing+=("udevadm")
  command -v ip >/dev/null 2>&1 || missing+=("ip")
  if [ ${#missing[@]} -gt 0 ]; then
    err "Error: interface-configurator requires systemd + udev (missing: ${missing[*]}) - not supported on this platform."
    exit 1
  fi
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "Error: --install/--uninstall require root (EUID 0). Re-run with sudo."
    exit 1
  fi
}

# args: $1=value $2=label for the error message -> exits 1 if $1 contains
# an embedded newline. The rule config file (write_rule_config/
# read_rule_config) stores the pattern and each add/remove command as one
# value per line; a literal newline inside a value would split it across
# two lines and corrupt that structure. Called on every --install
# <pattern>/--add <command>/--remove <command> as they're parsed, so this
# is rejected up front with a clear error rather than silently corrupting
# a config file (or being silently misread back) later.
reject_newline() {
  case "$1" in
    *$'\n'*)
      err "Error: ${2} may not contain a newline"
      exit 1
      ;;
  esac
}

# =============================================================================
# Pattern slug
# =============================================================================

# args: $1=pattern -> prints the first 8 hex chars of its plain SHA-1, or
# exits 1 if neither sha1sum nor shasum is available. Separate from the
# self-upgrade block's own 12-char upgrade_hash_prefix below - different
# length, different purpose (filename-safety slug vs. release-content
# verification) - not worth sharing one function for a one-line body.
hash_prefix8() {
  local input="$1" full
  if command -v sha1sum >/dev/null 2>&1; then
    full=$(printf '%s' "$input" | sha1sum | cut -d' ' -f1)
  elif command -v shasum >/dev/null 2>&1; then
    full=$(printf '%s' "$input" | shasum -a 1 | cut -d' ' -f1)
  else
    err "Error: sha1sum/shasum not found - cannot compute pattern slug."
    exit 1
  fi
  printf '%s' "${full:0:8}"
}

# args: $1=pattern -> prints the filename-safe slug: non-[A-Za-z0-9_-]
# characters replaced with '_', then '-' plus the pattern's own 8-hex-char
# hash appended, so distinct patterns that sanitize to the same prefix
# (e.g. 'eth*' vs 'eth?') never collide onto the same slug.
slug_for_pattern() {
  local pattern="$1" sanitized
  sanitized=$(printf '%s' "$pattern" | sed 's/[^A-Za-z0-9_-]/_/g')
  printf '%s-%s' "$sanitized" "$(hash_prefix8 "$pattern")"
}

# =============================================================================
# Storage: pattern -> add/remove command lists
# =============================================================================

rule_config_path() {
  printf '%s/%s.conf' "$IC_RULES_DIR" "$(slug_for_pattern "$1")"
}

# args: $1=pattern $2=name of the add-commands array $3=name of the
# remove-commands array -> writes/overwrites that pattern's config file as
# plain-text `KEY=value` lines: one `PATTERN=`, then one `ADD=` per add
# command and one `REMOVE=` per remove command, in order - no `_<n>`
# index suffix or `*_COUNT` line; read_rule_config collects every
# `ADD=`/`REMOVE=` line it finds, in file order, so the count falls out
# of "however many lines there are" rather than being tracked separately.
# `REMOVE` (not e.g. `DEL`) deliberately matches the `--remove` CLI flag
# name - this file is meant to stay readable by a human comparing it
# against the command that produced it.
#
# Values are written literally (no quoting/escaping) - each is everything
# after the first `=` on its line, unparsed, so it reproduces the
# original pattern/command string exactly including embedded spaces,
# quotes, `$IFACE`, `*`, etc.; read_rule_config reads it back the same
# way, by field-splitting on `=` rather than sourcing the file as bash
# (which is also why this format needs no escaping in the first place -
# nothing here is ever evaluated as shell syntax). The one thing this
# can't represent is a literal embedded newline inside a value, since
# that would split it across two lines - the CLI's --install/--add/
# --remove parsing rejects that upfront (reject_newline), so it can never
# reach this file.
write_rule_config() {
  local pattern="$1"
  local -n adds_ref="$2"
  local -n removes_ref="$3"
  local path cmd
  path=$(rule_config_path "$pattern")
  mkdir -p "$IC_RULES_DIR" 2>/dev/null || { err "Error: cannot create ${IC_RULES_DIR}"; exit 1; }
  {
    printf 'PATTERN=%s\n' "$pattern"
    for cmd in "${adds_ref[@]}"; do
      printf 'ADD=%s\n' "$cmd"
    done
    for cmd in "${removes_ref[@]}"; do
      printf 'REMOVE=%s\n' "$cmd"
    done
  } > "$path" || { err "Error: cannot write ${path}"; exit 1; }
}

# args: $1=config file path -> sets PATTERN/ADD_CMDS/REMOVE_CMDS in the
# caller's scope (cleared first, so a malformed file can't leak a
# previous iteration's values under `set -u`) by reading it line by line -
# never sourced as bash, so this file is always plain data, not
# executable code. `IFS='=' read -r key value` splits only on the first
# `=` (a `read` with more input fields than target variables dumps
# everything past the last split point, `=` characters included, into the
# final variable un-split), and performs no expansion/word-splitting of
# its own, so `value` comes back byte-for-byte identical to what
# write_rule_config wrote - unknown/malformed lines are silently ignored,
# forward-compatible with a config file written by a newer script
# version that adds a key this version doesn't know about.
read_rule_config() {
  local file="$1" key value
  PATTERN=""
  ADD_CMDS=()
  REMOVE_CMDS=()
  while IFS='=' read -r key value || [ -n "$key" ]; do
    case "$key" in
      PATTERN) PATTERN="$value" ;;
      ADD)     ADD_CMDS+=("$value") ;;
      REMOVE)  REMOVE_CMDS+=("$value") ;;
      *)       ;;
    esac
  done < "$file"
}

# =============================================================================
# Shared systemd template unit
# =============================================================================

shared_unit_path() {
  printf '%s/interface-configurator@.service' "$IC_SYSTEMD_DIR"
}

# Type=simple (not oneshot): the instance is a long-running watcher, not a
# run-once task - systemd only considers a oneshot unit "active" once its
# process exits, so TimeoutStartSec (~90s by default) would kill a
# genuinely long-running oneshot process before it ever finished
# "starting". BindsTo=/After= the interface's own device unit is
# systemd's native "stop this unit when this device disappears"
# mechanism - it sends SIGTERM automatically on real removal, which --run
# traps to run its remove commands and exit cleanly (belt-and-braces:
# --run's own watch loop also notices removal directly - see
# watch_iface). Restart=on-failure only restarts a non-zero (crashing)
# exit; a clean exit (device removed, or systemd/--uninstall stopping it
# on purpose) is never restarted.
shared_unit_content() {
  cat <<EOF
[Unit]
Description=interface-configurator: watch %i for add/remove/update events
After=sys-subsystem-net-devices-%i.device
BindsTo=sys-subsystem-net-devices-%i.device

[Service]
Type=simple
Restart=on-failure
ExecStart=${RESOLVED_SCRIPT_PATH} --no-autoupdate --run %i
EOF
}

# Ensures the shared template unit exists AND matches what this script
# version would generate; replaces + daemon-reloads on drift. daemon-
# reload alone never stops/restarts an already-running instance, so this
# is safe to run on every --install, not gated to "first install only".
ensure_shared_unit() {
  local path wanted current
  path=$(shared_unit_path)
  wanted=$(shared_unit_content)
  if [ -f "$path" ]; then
    current=$(cat "$path" 2>/dev/null)
    [ "$current" = "$wanted" ] && return 0
  fi
  mkdir -p "$IC_SYSTEMD_DIR" 2>/dev/null || { err "Error: cannot create ${IC_SYSTEMD_DIR}"; exit 1; }
  printf '%s\n' "$wanted" > "$path" || { err "Error: cannot write ${path}"; exit 1; }
  log "shared unit ${path} created/updated"
  systemctl daemon-reload
}

# =============================================================================
# Per-pattern udev rule
# =============================================================================

udev_rule_path() {
  printf '%s/99-interface-configurator-%s.rules' "$IC_UDEV_RULES_DIR" "$(slug_for_pattern "$1")"
}

# ACTION=="add" only, deliberately - not "change", and no
# ATTR{operstate}/ATTR{carrier} match either. Both alternatives were tried
# and found unreliable during design work against a real ZeroTier/TUN
# interface: "change" uevents were not observed at all across a real boot
# sequence (only "add" fired), and "operstate" stayed at "unknown"
# indefinitely (TUN devices commonly don't implement carrier detection the
# way operstate's computation expects). This rule's only job is to start
# the watcher once, the first time the interface appears - every
# subsequent transition (up/down/address-change/removal) is handled by
# the watcher itself (wait_for_ready/watch_iface below), which can wait
# and react as long as needed rather than depending on further uevents.
udev_rule_content() {
  local pattern="$1"
  printf 'ACTION=="add", SUBSYSTEM=="net", KERNEL=="%s", TAG+="systemd", ENV{SYSTEMD_WANTS}+="interface-configurator@%%k.service"\n' "$pattern"
}

# =============================================================================
# Interface state
# =============================================================================

# args: $1=interface name -> 0 if administratively up (IFF_UP) AND carrier
# is present right now.
iface_is_ready() {
  local iface="$1" flags carrier
  flags=$(cat "${IC_SYS_CLASS_NET}/${iface}/flags" 2>/dev/null) || return 1
  carrier=$(cat "${IC_SYS_CLASS_NET}/${iface}/carrier" 2>/dev/null) || return 1
  (( flags & 0x1 )) || return 1
  [ "$carrier" = "1" ]
}

# args: $1=interface name $2=timeout seconds -> 0 once the interface
# becomes ready, 1 if it doesn't within the timeout. Checks current state
# first; if not yet ready, waits passively (event-driven, no sleep/poll
# loop) on `ip monitor link`, re-checking real state (via iface_is_ready,
# not by parsing ip monitor's own text) on every line it emits, since the
# `add` uevent that triggers --run can fire before the interface is
# genuinely usable (confirmed against a real TUN interface).
wait_for_ready() {
  local iface="$1" secs="$2"
  iface_is_ready "$iface" && return 0
  timeout "$secs" ip monitor link dev "$iface" | while IFS= read -r _; do
    iface_is_ready "$iface" && break
  done
  iface_is_ready "$iface"
}

# args: $1=interface name -> prints a normalized snapshot of the
# interface's current addresses (sorted, one per line), used to detect an
# address change while otherwise ready (confirmed trigger for a "remove
# then add" reapply: any IPv4/IPv6 address change - not route/gateway
# changes specifically).
get_addresses() {
  ip -o addr show dev "$1" 2>/dev/null | sort
}

# =============================================================================
# Running registered commands
# =============================================================================

# args: -> prints every currently-present interface name, one per line.
list_interfaces() {
  local d
  for d in "${IC_SYS_CLASS_NET}"/*; do
    [ -e "$d" ] || continue
    basename "$d"
  done
}

# args: $1=prefix length (0-32) -> dotted IPv4 netmask, e.g. 24 ->
# 255.255.255.0. Relies on bash's 64-bit arithmetic: shifting the 32-bit
# all-ones mask left by (32 - prefix) - including the /0 edge case, which
# shifts it out of the low 32 bits entirely - always lands in the low 32
# bits with the correct value once masked back down with 0xffffffff.
ipv4_prefix_to_netmask() {
  local prefix="$1" mask
  mask=$(( (0xffffffff << (32 - prefix)) & 0xffffffff ))
  printf '%d.%d.%d.%d' $(( (mask >> 24) & 255 )) $(( (mask >> 16) & 255 )) \
    $(( (mask >> 8) & 255 )) $(( mask & 255 ))
}

# args: $1=interface name -> sets IP4_ADDRESS/IP4_NETMASK/IP4_PREFIX and
# IP6_ADDRESS/IP6_PREFIX (empty if the interface has none in that family)
# for run_command_for_iface to export - convenience shortcuts for the
# simple case (README "Convenience variables"): only the interface's
# first global-scope address in each family. An interface with more than
# one address in a family only ever gets the first one here; a
# --add/--remove command needing more queries `ip` itself. No IP6_NETMASK
# - IPv6 addresses aren't conventionally expressed with a dotted-style
# mask, only the prefix length already in IP6_PREFIX.
set_iface_address_vars() {
  local iface="$1" line cidr
  IP4_ADDRESS=""; IP4_NETMASK=""; IP4_PREFIX=""
  IP6_ADDRESS=""; IP6_PREFIX=""

  line="$(ip -4 -o addr show dev "$iface" scope global 2>/dev/null | head -n1)"
  if [ -n "$line" ]; then
    cidr="$(printf '%s' "$line" | awk '{print $4}')"
    IP4_ADDRESS="${cidr%%/*}"
    IP4_PREFIX="${cidr##*/}"
    IP4_NETMASK="$(ipv4_prefix_to_netmask "$IP4_PREFIX")"
  fi

  line="$(ip -6 -o addr show dev "$iface" scope global 2>/dev/null | head -n1)"
  if [ -n "$line" ]; then
    cidr="$(printf '%s' "$line" | awk '{print $4}')"
    IP6_ADDRESS="${cidr%%/*}"
    IP6_PREFIX="${cidr##*/}"
  fi
}

# args: $1=interface name -> sets IP4_GATEWAY/IP6_GATEWAY (empty if none)
# for run_command_for_iface to export: the gateway of this interface's own
# default route in each family. Independent per family - a dual-stack
# interface can have different IPv4/IPv6 default routes, or only one of
# the two.
set_iface_gateway_vars() {
  local iface="$1"
  IP4_GATEWAY="$(ip -4 route show default dev "$iface" 2>/dev/null \
    | awk '{for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}')"
  IP6_GATEWAY="$(ip -6 route show default dev "$iface" 2>/dev/null \
    | awk '{for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}')"
}

# args: $1=interface name -> path to that interface's stashed convenience
# variables (see write_iface_state/read_iface_state below). One file per
# interface, not per pattern - the address/gateway they hold are a
# property of the interface itself, shared by every pattern watching it.
iface_state_path() {
  printf '%s/%s.env' "$IC_STATE_DIR" "$1"
}

# args: $1=interface name -> writes the current IP4_*/IP6_* globals (as
# already set by set_iface_address_vars/set_iface_gateway_vars) to that
# interface's state file under IC_STATE_DIR (/run by default - cleared on
# reboot, which is correct: stale state from a previous boot is never
# valid). Called right after an add command runs, while the interface is
# known-ready, so a later remove command can recover these values even
# once the interface itself is gone (see read_iface_state). Best-effort:
# IC_STATE_DIR may not be writable (e.g. --run invoked by hand as a
# non-root user for testing) - logged, not fatal, since this only affects
# the convenience variables, never the add/remove commands themselves.
write_iface_state() {
  local iface="$1" path
  path="$(iface_state_path "$iface")"
  mkdir -p "$IC_STATE_DIR" 2>/dev/null || { err "Warning: cannot create ${IC_STATE_DIR} - remove commands for '${iface}' won't see a stashed address/gateway if it's since disappeared"; return 0; }
  {
    printf 'IP4_ADDRESS=%q\n' "$IP4_ADDRESS"
    printf 'IP4_NETMASK=%q\n' "$IP4_NETMASK"
    printf 'IP4_PREFIX=%q\n' "$IP4_PREFIX"
    printf 'IP4_GATEWAY=%q\n' "$IP4_GATEWAY"
    printf 'IP6_ADDRESS=%q\n' "$IP6_ADDRESS"
    printf 'IP6_PREFIX=%q\n' "$IP6_PREFIX"
    printf 'IP6_GATEWAY=%q\n' "$IP6_GATEWAY"
  } > "$path" || err "Warning: cannot write ${path} - remove commands for '${iface}' won't see a stashed address/gateway if it's since disappeared"
}

# args: $1=interface name -> sets the IP4_*/IP6_* globals from that
# interface's stashed state file if one exists, else leaves them empty
# (never unset, so this script's `set -u` is never tripped by a lookup
# that finds nothing).
read_iface_state() {
  local iface="$1" path
  path="$(iface_state_path "$iface")"
  IP4_ADDRESS=""; IP4_NETMASK=""; IP4_PREFIX=""; IP4_GATEWAY=""
  IP6_ADDRESS=""; IP6_PREFIX=""; IP6_GATEWAY=""
  [ -f "$path" ] && . "$path"
}

# args: $1=interface name -> removes that interface's stashed state file,
# if any. Called once the watcher for this interface is done for good
# (watch_iface's own exit) - a stash from an interface that's gone is
# never valid for a future one that happens to get the same name later.
remove_iface_state() {
  rm -f "$(iface_state_path "$1")" 2>/dev/null || true
}

# args: $1=interface name $2=command string $3=kind ("add"|"remove") ->
# runs it with IFACE, plus the IP4_*/IP6_* convenience variables above,
# exported, and the interface name also passed as $1, logs its exit
# status, and returns that same status.
#
# "add" queries the variables live (the interface is known-ready at this
# point) and stashes them via write_iface_state for a later "remove" to
# recover - "remove" reads that same stash instead of querying live,
# since by the time a remove command runs - especially one triggered by
# the interface's own removal (see watch_iface's loop condition) - the
# interface, and whatever address/gateway it had, may already be gone.
# This also keeps add and remove seeing the *same* values for a given
# lifecycle transition, rather than remove picking up whatever's live at
# that moment (e.g. a since-renewed DHCP lease) if the interface happens
# to still be there.
run_command_for_iface() {
  local iface="$1" command="$2" kind="$3" code
  if [ "$kind" = "add" ]; then
    set_iface_address_vars "$iface"
    set_iface_gateway_vars "$iface"
    write_iface_state "$iface"
  else
    read_iface_state "$iface"
  fi
  log "running command for '${iface}': ${command}"
  IFACE="$iface" \
    IP4_ADDRESS="$IP4_ADDRESS" IP4_NETMASK="$IP4_NETMASK" IP4_PREFIX="$IP4_PREFIX" IP4_GATEWAY="$IP4_GATEWAY" \
    IP6_ADDRESS="$IP6_ADDRESS" IP6_PREFIX="$IP6_PREFIX" IP6_GATEWAY="$IP6_GATEWAY" \
    bash -c "$command" "$SCRIPT_NAME" "$iface"
  code=$?
  if [ "$code" -eq 0 ]; then
    log "command for '${iface}' exited 0"
  else
    err "command for '${iface}' exited ${code}"
  fi
  return "$code"
}

# args: $1=interface name -> 0 if at least one registered pattern
# glob-matches it.
any_pattern_matches() {
  local iface="$1" file
  shopt -s nullglob
  for file in "${IC_RULES_DIR}"/*.conf; do
    read_rule_config "$file"
    # shellcheck disable=SC2053
    if [[ "$iface" == $PATTERN ]]; then
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

# args: $1=interface name $2=kind ("add"|"remove") -> re-reads every
# registered pattern fresh - rules are deliberately re-read on every
# transition rather than cached from --run's own startup, so an
# --install/--uninstall change takes effect on the interface's next
# transition without needing to restart its watcher - and runs every
# matching pattern's $2 commands, in slug-sort order. A pattern whose
# config file was already deleted (e.g. by --uninstall, which deletes it
# before stopping the watcher - see cmd_uninstall) is naturally absent
# here, so this runs zero commands for it; no special-casing needed for
# that case.
run_matched() {
  local iface="$1" kind="$2" file cmd
  shopt -s nullglob
  for file in "${IC_RULES_DIR}"/*.conf; do
    read_rule_config "$file"
    # shellcheck disable=SC2053
    [[ "$iface" == $PATTERN ]] || continue
    if [ "$kind" = "add" ]; then
      for cmd in "${ADD_CMDS[@]}"; do
        run_command_for_iface "$iface" "$cmd" "add" || true
      done
    else
      for cmd in "${REMOVE_CMDS[@]}"; do
        run_command_for_iface "$iface" "$cmd" "remove" || true
      done
    fi
  done
  shopt -u nullglob
}

# =============================================================================
# --run: wait, apply, then watch for the interface's whole lifecycle
# =============================================================================

# args: $1=interface name -> runs once ready and this interface's add
# commands have already executed (see cmd_run below). Watches for further
# transitions until the interface is removed or this process is asked to
# stop (SIGTERM/SIGINT - sent by systemd on real device removal via this
# unit's BindsTo=, by `systemctl stop` from --uninstall, or manually):
#   - still ready, addresses changed -> remove then add (full reapply)
#   - was ready, now not ready (still present) -> remove
#   - was not ready, now ready again -> add
# On exit (either cause), re-reads fresh and runs remove commands one
# last time, but only if currently applied (ready) - an interface that was
# already down when this process stops never gets its remove commands run
# twice.
watch_iface() {
  local iface="$1" terminate=0 ready=1 addrs last_addrs line mon_failures=0
  trap 'terminate=1' TERM INT

  last_addrs=$(get_addresses "$iface")

  # Passive, event-driven watch via a coprocess (not a sleep/poll loop) -
  # `read -t 1` bounds how long each loop iteration blocks so the
  # TERM/INT trap above gets a chance to run promptly (within ~1s) even
  # while nothing on the interface is changing. Its stderr is left
  # attached to this process's own stderr (the systemd journal), not
  # discarded, so a real `ip monitor` failure is visible instead of
  # vanishing silently.
  coproc IC_MON ip monitor link addr dev "$iface"
  log "watching '${iface}' via ip monitor (pid ${IC_MON_PID:-unknown})"

  while [ "$terminate" -eq 0 ] && [ -e "${IC_SYS_CLASS_NET}/${iface}" ]; do
    line=""
    if [ -n "${IC_MON_PID:-}" ]; then
      read -t 1 -r -u "${IC_MON[0]}" line 2>/dev/null
    else
      # bash unsets IC_MON/IC_MON_PID the instant the coprocess exits -
      # without this check, the read above would crash on an unbound
      # variable under `set -u` instead of failing visibly (this is what
      # used to happen here). Restart it, bounded, so a coprocess that
      # can't stay up doesn't spin this loop forever; exhausting the bound
      # hands off to systemd's own Restart=on-failure instead.
      mon_failures=$((mon_failures + 1))
      err "ip monitor coprocess for '${iface}' exited unexpectedly (attempt ${mon_failures}/5)"
      if [ "$mon_failures" -ge 5 ]; then
        err "ip monitor coprocess for '${iface}' won't stay up - giving up"
        exit 1
      fi
      sleep 1
      coproc IC_MON ip monitor link addr dev "$iface"
      log "restarted ip monitor coprocess for '${iface}' (pid ${IC_MON_PID:-unknown})"
    fi

    if iface_is_ready "$iface"; then
      if [ "$ready" -eq 0 ]; then
        log "interface '${iface}' is up again"
        run_matched "$iface" add
        ready=1
        last_addrs=$(get_addresses "$iface")
      else
        addrs=$(get_addresses "$iface")
        if [ "$addrs" != "$last_addrs" ]; then
          log "address change detected on '${iface}'"
          run_matched "$iface" remove
          run_matched "$iface" add
          last_addrs="$addrs"
        fi
      fi
    else
      if [ "$ready" -eq 1 ]; then
        log "interface '${iface}' went down"
        run_matched "$iface" remove
        ready=0
      fi
    fi
  done

  kill "${IC_MON_PID:-}" 2>/dev/null
  wait "${IC_MON_PID:-}" 2>/dev/null

  if [ "$ready" -eq 1 ]; then
    run_matched "$iface" remove
  fi
  remove_iface_state "$iface"
  log "stopped watching '${iface}'"
  exit 0
}

cmd_run() {
  local iface="$1"

  if ! any_pattern_matches "$iface"; then
    log "no rule matches '${iface}'"
    exit 0
  fi

  if ! wait_for_ready "$iface" "$IC_READY_TIMEOUT_SECONDS"; then
    err "interface '${iface}' did not become ready within ${IC_READY_TIMEOUT_SECONDS}s"
    exit 1
  fi

  run_matched "$iface" add
  watch_iface "$iface"
}

# =============================================================================
# --install / --uninstall
# =============================================================================

# args: $1=pattern $2=name of the add-commands array -> for each
# already-present interface matching $1: if a watcher is already running
# for it, applies these add commands directly now (a running watcher only
# re-reads rules on its own next transition, so a newly-registered/
# changed pattern needs this to take effect immediately); otherwise starts
# the watcher instead and lets its own normal startup sequence
# (wait_for_ready, then run_matched add) apply everything - avoids running
# this pattern's add commands twice.
apply_now_for_pattern() {
  local pattern="$1"
  local -n adds_ref="$2"
  local iface unit cmd
  while IFS= read -r iface; do
    [ -z "$iface" ] && continue
    # shellcheck disable=SC2053
    [[ "$iface" == $pattern ]] || continue
    unit="interface-configurator@${iface}.service"
    if systemctl is-active --quiet "$unit"; then
      if wait_for_ready "$iface" "$IC_READY_TIMEOUT_SECONDS"; then
        for cmd in "${adds_ref[@]}"; do
          run_command_for_iface "$iface" "$cmd" "add" || true
        done
      else
        err "interface '${iface}' did not become ready within ${IC_READY_TIMEOUT_SECONDS}s - skipping immediate apply"
      fi
    else
      log "starting watcher for '${iface}'"
      systemctl start "$unit"
    fi
  done < <(list_interfaces)
}

# args: $1=pattern $2=name of the add-commands array $3=name of the
# remove-commands array (both populated by argument parsing below).
cmd_install() {
  local pattern="$1" adds_name="$2" removes_name="$3"
  local -n adds_ref="$adds_name"
  local -n removes_ref="$removes_name"

  write_rule_config "$pattern" "$adds_name" "$removes_name"
  log "registered pattern '${pattern}' (${#adds_ref[@]} add, ${#removes_ref[@]} remove)"
  ensure_shared_unit
  mkdir -p "$IC_UDEV_RULES_DIR" 2>/dev/null || { err "Error: cannot create ${IC_UDEV_RULES_DIR}"; exit 1; }
  udev_rule_content "$pattern" > "$(udev_rule_path "$pattern")" || { err "Error: cannot write udev rule"; exit 1; }
  udevadm control --reload-rules
  apply_now_for_pattern "$pattern" "$adds_name"
}

# args: $1=pattern -> removes its config + udev rule if registered; logs a
# no-op (not an error) if it wasn't. Returns 0 if something was actually
# removed, 1 if it was a no-op - callers use this to decide whether a
# reload/watcher-stop pass is warranted at all.
remove_pattern() {
  local pattern="$1" conf rule
  conf=$(rule_config_path "$pattern")
  rule=$(udev_rule_path "$pattern")
  if [ ! -f "$conf" ] && [ ! -f "$rule" ]; then
    log "nothing to remove for '${pattern}'"
    return 1
  fi
  rm -f "$conf" "$rule"
  log "removed pattern '${pattern}'"
  return 0
}

# args: $1=interface name -> stops that interface's watcher if no
# currently-registered pattern matches it any more. Called only after
# removing pattern(s) from storage, so a watcher stopped here always finds
# its config already gone and runs zero remove commands (see run_matched)
# - --uninstall deliberately never runs remove commands itself, only
# future events do.
stop_watcher_if_unmatched() {
  local iface="$1"
  any_pattern_matches "$iface" && return 0
  systemctl stop "interface-configurator@${iface}.service" 2>/dev/null
}

cmd_uninstall() {
  local pattern="${1:-}" removed_any=false file iface remaining

  if [ -n "$pattern" ]; then
    remove_pattern "$pattern" && removed_any=true
  else
    shopt -s nullglob
    for file in "${IC_RULES_DIR}"/*.conf; do
      read_rule_config "$file"
      remove_pattern "$PATTERN" && removed_any=true
    done
    shopt -u nullglob
  fi

  if $removed_any; then
    udevadm control --reload-rules
    while IFS= read -r iface; do
      [ -z "$iface" ] && continue
      stop_watcher_if_unmatched "$iface"
    done < <(list_interfaces)
  fi

  shopt -s nullglob
  remaining=("${IC_RULES_DIR}"/*.conf)
  shopt -u nullglob
  if [ ${#remaining[@]} -eq 0 ] && [ -f "$(shared_unit_path)" ]; then
    rm -f "$(shared_unit_path)"
    log "removed shared unit $(shared_unit_path) (no patterns remain)"
    systemctl daemon-reload
  fi
}

# =============================================================================
# Self-upgrade (script-upgrade-convention.md) - begins
# =============================================================================
# Copied/adapted from tools/blueprints/bash.sh - see docs/requirements/
# generic/script-maintenance-convention.md section 1: fixes to this
# mechanism land in the blueprint first, then get replicated here.

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

upgrade_version_gt() {
  # args: $1 > $2 ?
  local a1 a2 a3 b1 b2 b3 rest
  a1=${1%%.*}; rest=${1#*.}; a2=${rest%%.*}; a3=${rest#*.}; a3=${a3%%-*}
  b1=${2%%.*}; rest=${2#*.}; b2=${rest%%.*}; b3=${rest#*.}; b3=${b3%%-*}
  [ "$a1" -gt "$b1" ] && return 0
  [ "$a1" -lt "$b1" ] && return 1
  [ "$a2" -gt "$b2" ] && return 0
  [ "$a2" -lt "$b2" ] && return 1
  [ "$a3" -gt "$b3" ] && return 0
  [ "$a3" -lt "$b3" ] && return 1
  local la lb ra rb
  la=$(upgrade_version_level "$1"); ra=$(upgrade_level_rank "$la") || ra=-1
  lb=$(upgrade_version_level "$2"); rb=$(upgrade_level_rank "$lb") || rb=-1
  [ "$ra" -gt "$rb" ] && return 0
  [ "$ra" -lt "$rb" ] && return 1
  [ "$(upgrade_version_number "$1")" -gt "$(upgrade_version_number "$2")" ]
}

# --- section 3: discover every matching tag, no `git` required -------------
upgrade_fetch_tags_json() {
  local owner="$1" repo="$2" lang="$3" name="$4"
  curl -fsS --max-time "${UPGRADE_TIMEOUT:-10}" \
    "https://api.github.com/repos/${owner}/${repo}/git/matching-refs/tags/${lang}/${name}/v"
}

upgrade_parse_versions() {
  local json="$1" lang="$2" name="$3" refs r
  refs=$(printf '%s\n' "$json" \
    | sed -n 's/.*"ref": *"refs\/tags\/'"${lang}"'\/'"${name}"'\/v\([^"]*\)".*/\1/p')
  for r in $refs; do
    printf '%s %s\n' "$r" "$(upgrade_version_level "$r")"
  done
}

upgrade_discover() {
  local owner="$1" repo="$2" lang="$3" name="$4" json
  json=$(upgrade_fetch_tags_json "$owner" "$repo" "$lang" "$name") || return 1
  upgrade_parse_versions "$json" "$lang" "$name"
}

upgrade_highest_at_level() {
  local versions="$1" min_level="$2" min_rank
  min_rank=$(upgrade_level_rank "$min_level") || return 1
  local best="" v level rank
  while IFS=' ' read -r v level; do
    [ -z "$v" ] && continue
    rank=$(upgrade_level_rank "$level") || continue
    [ "$rank" -ge "$min_rank" ] || continue
    if [ -z "$best" ] || upgrade_version_gt "$v" "$best"; then
      best="$v"
    fi
  done <<<"$versions"
  [ -n "$best" ] && printf '%s' "$best"
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

upgrade_mode_possible() {
  local mode="$1" script_path="$2" cache_dir="$3"
  case "$mode" in
    replacement) [ -w "$(dirname "$script_path")" ] ;;
    overwrite) [ -w "$script_path" ] ;;
    link) mkdir -p "$cache_dir" 2>/dev/null; [ -w "$cache_dir" ] ;;
    memory) return 0 ;;
    *) return 1 ;;
  esac
}

upgrade_select_mode() {
  local ceiling="$1" script_path="$2" cache_dir="$3" start_rank m rank
  if [ -n "$ceiling" ]; then
    start_rank=$(upgrade_mode_rank "$ceiling") || start_rank=0
  else
    start_rank=0
  fi
  for m in replacement overwrite link memory; do
    rank=$(upgrade_mode_rank "$m")
    [ "$rank" -ge "$start_rank" ] || continue
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

upgrade_file_version() {
  local file="$1" line
  line=$(grep -m1 -E '^# Version: [0-9]+\.[0-9]+\.[0-9]+(-[a-z]+[0-9]*)?$' "$file" 2>/dev/null) || return 1
  printf '%s' "${line##*: }"
}

# --- section 5: download the candidate + syntax-only validation ------------
upgrade_download() {
  local owner="$1" repo="$2" lang="$3" name="$4" version="$5" rc
  curl -fsS --max-time "${UPGRADE_TIMEOUT:-10}" \
    "https://raw.githubusercontent.com/${owner}/${repo}/${lang}/${name}/v${version}/platforms/${lang}/${name}/${name}.sh"
  rc=$?
  printf '\x01'
  return "$rc"
}

upgrade_validate_parse() {
  printf '%s\n' "$1" | bash -n - 2>/dev/null
}

# --- section 5 (best-effort): content-hash match against the release tag ---
upgrade_fetch_tag_hash() {
  local owner="$1" repo="$2" lang="$3" name="$4" version="$5"
  local ref_json tag_sha tag_json
  ref_json=$(curl -fsS --max-time "${UPGRADE_TIMEOUT:-10}" \
    "https://api.github.com/repos/${owner}/${repo}/git/refs/tags/${lang}/${name}/v${version}") || return 0
  tag_sha=$(printf '%s' "$ref_json" | sed -n 's/.*"sha": *"\([0-9a-f]*\)".*/\1/p' | head -n1)
  [ -n "$tag_sha" ] || return 0
  tag_json=$(curl -fsS --max-time "${UPGRADE_TIMEOUT:-10}" \
    "https://api.github.com/repos/${owner}/${repo}/git/tags/${tag_sha}") || return 0
  printf '%s' "$tag_json" | grep -oE '"message": *"\[[0-9a-f]{12}\]' | grep -oE '[0-9a-f]{12}' | head -n1
}

upgrade_hash_prefix() {
  local full
  if command -v sha1sum >/dev/null 2>&1; then
    full=$(printf '%s' "$1" | sha1sum | cut -d' ' -f1)
  elif command -v shasum >/dev/null 2>&1; then
    full=$(printf '%s' "$1" | shasum -a 1 | cut -d' ' -f1)
  else
    return 0
  fi
  printf '%s' "${full:0:12}"
}

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

upgrade_verify_disk_hash() {
  local path="$1" expected="$2" actual
  [ -n "$expected" ] || return 0
  actual=$(upgrade_hash_prefix_file "$path")
  [ -z "$actual" ] || [ "$actual" = "$expected" ]
}

# --- section 14: cooldown cache (implicit invocations only) ----------------
upgrade_cooldown_elapsed() {
  local cache_file="$1"
  [ -f "$cache_file" ] || return 0
  local last_checked now
  last_checked=$(sed -n '1p' "$cache_file" 2>/dev/null)
  [ -z "$last_checked" ] && return 0
  now=$(date +%s)
  [ $((now - last_checked)) -ge "${UPGRADE_COOLDOWN_SECONDS:-1200}" ]
}

# --- section 6: permission & ownership preservation -------------------------
upgrade_stat_mode() {
  local path="$1"
  stat -c '%a' "$path" 2>/dev/null && return 0
  stat -f '%OLp' "$path" 2>/dev/null
}

upgrade_stat_owner_group() {
  local path="$1"
  stat -c '%U:%G' "$path" 2>/dev/null && return 0
  stat -f '%Su:%Sg' "$path" 2>/dev/null
}

upgrade_copy_mode_owner() {
  local source="$1" target="$2" mode owner_group
  mode=$(upgrade_stat_mode "$source")
  [ -n "$mode" ] && chmod "$mode" "$target" 2>/dev/null
  owner_group=$(upgrade_stat_owner_group "$source")
  [ -n "$owner_group" ] && chown "$owner_group" "$target" 2>/dev/null
  return 0
}

# --- section 6/8: persistence primitives (pure filesystem, no execution) ---
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

upgrade_write_temp_scratch() {
  local content="$1" tmp
  tmp=$(mktemp 2>/dev/null) || return 1
  if ! printf '%s' "$content" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  printf '%s' "$tmp"
}

upgrade_persist_replacement() {
  mv -f "$1" "$2" 2>/dev/null
}

upgrade_persist_overwrite() {
  printf '%s' "$1" > "$2" 2>/dev/null
}

upgrade_persist_overwrite_from_file() {
  cat "$1" > "$2" 2>/dev/null
}

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
    *) ;;
  esac
}

# args: sets $latest/$mode/$content/$tag_hash in the caller's scope on
# success; on any pre-trial failure sets UPGRADE_BANNER_NOTE and returns 1
# (caller must not trial-run or persist anything - section 9).
upgrade_prepare_candidate() {
  local versions effective_level cache_dir
  cache_dir=$(upgrade_cache_dir "$SCRIPT_LANG" "$SCRIPT_NAME")
  mode=$(upgrade_select_mode "${UPGRADE_TYPE:-}" "$SCRIPT_PATH" "$cache_dir")
  if ! versions=$(upgrade_discover "$UPGRADE_OWNER" "$UPGRADE_REPO" "$SCRIPT_LANG" "$SCRIPT_NAME"); then
    UPGRADE_BANNER_NOTE=$(upgrade_banner_note check_failed "could not reach ${UPGRADE_HOST}")
    return 1
  fi
  effective_level="${UPGRADE_LEVEL:-$(upgrade_version_level "$SCRIPT_VERSION")}"
  latest=$(upgrade_highest_at_level "$versions" "$effective_level")
  if [ -z "$latest" ] || ! upgrade_version_gt "$latest" "$SCRIPT_VERSION"; then
    UPGRADE_BANNER_NOTE=$(upgrade_banner_note no_upgrade)
    return 1
  fi

  local cache_file
  cache_file=$(upgrade_cache_file "$SCRIPT_LANG" "$SCRIPT_NAME")
  tag_hash=$(upgrade_fetch_tag_hash "$UPGRADE_OWNER" "$UPGRADE_REPO" "$SCRIPT_LANG" "$SCRIPT_NAME" "$latest")
  if [ "$mode" = "link" ] && [ -f "$cache_file" ] && [ -n "$tag_hash" ] \
     && [ "$(upgrade_hash_prefix_file "$cache_file")" = "$tag_hash" ]; then
    content=""
    return 0
  fi

  local raw
  if ! raw=$(upgrade_download "$UPGRADE_OWNER" "$UPGRADE_REPO" "$SCRIPT_LANG" "$SCRIPT_NAME" "$latest"); then
    UPGRADE_BANNER_NOTE=$(upgrade_banner_note check_failed "download failed")
    return 1
  fi
  content="${raw%$'\x01'}"

  if ! upgrade_validate_parse "$content"; then
    UPGRADE_BANNER_NOTE=$(upgrade_banner_note parse_failed "$latest" "$SCRIPT_VERSION")
    return 1
  fi
  if [ -n "$tag_hash" ]; then
    local actual
    actual=$(upgrade_hash_prefix "$content")
    if [ -n "$actual" ] && [ "$actual" != "$tag_hash" ]; then
      UPGRADE_BANNER_NOTE=$(upgrade_banner_note hash_mismatch "$latest" "$SCRIPT_VERSION")
      return 1
    fi
  fi
  return 0
}

# args: sets $latest/$mode in the caller's scope on success (no $content -
# caller reads bytes straight from the cache file); returns 1 with no
# UPGRADE_BANNER_NOTE set (not itself a failure - see section 2) when
# there's nothing to promote.
upgrade_prepare_cached_candidate() {
  local cache_dir cache_file cached_version
  cache_dir=$(upgrade_cache_dir "$SCRIPT_LANG" "$SCRIPT_NAME")
  cache_file=$(upgrade_cache_file "$SCRIPT_LANG" "$SCRIPT_NAME")
  [ -f "$cache_file" ] || return 1
  cached_version=$(upgrade_file_version "$cache_file") || return 1
  upgrade_version_gt "$cached_version" "$SCRIPT_VERSION" || return 1
  local effective_level effective_rank cached_rank
  effective_level="${UPGRADE_LEVEL:-$(upgrade_version_level "$SCRIPT_VERSION")}"
  effective_rank=$(upgrade_level_rank "$effective_level") || return 1
  cached_rank=$(upgrade_level_rank "$(upgrade_version_level "$cached_version")") || return 1
  [ "$cached_rank" -ge "$effective_rank" ] || return 1
  mode=$(upgrade_select_mode "${UPGRADE_TYPE:-}" "$SCRIPT_PATH" "$cache_dir")
  case "$mode" in
    replacement|overwrite) ;;
    *) return 1 ;;
  esac
  latest="$cached_version"
  return 0
}

# --- section 11: --upgrade-check --------------------------------------------
upgrade_check_main() {
  local mode cache_dir versions effective_level would stable_v overall_v
  cache_dir=$(upgrade_cache_dir "$SCRIPT_LANG" "$SCRIPT_NAME")
  mode=$(upgrade_select_mode "" "$SCRIPT_PATH" "$cache_dir")
  if ! versions=$(upgrade_discover "$UPGRADE_OWNER" "$UPGRADE_REPO" "$SCRIPT_LANG" "$SCRIPT_NAME"); then
    printf '%s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
    printf 'upgrade check failed: could not reach %s\n' "$UPGRADE_HOST"
    printf 'Supported upgrade mode: %s\n' "$mode"
    exit 1
  fi
  effective_level="${UPGRADE_LEVEL:-$(upgrade_version_level "$SCRIPT_VERSION")}"
  would=$(upgrade_highest_at_level "$versions" "$effective_level")
  stable_v=$(upgrade_highest_at_level "$versions" stable)
  overall_v=$(upgrade_highest_at_level "$versions" dev)
  printf '%s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
  if [ -n "$would" ] && upgrade_version_gt "$would" "$SCRIPT_VERSION"; then
    printf 'Would upgrade to: v%s (level: %s)\n' "$would" "$effective_level"
  else
    printf 'No upgrade present\n'
  fi
  [ -n "$stable_v" ] && [ "$stable_v" != "$would" ] && printf 'Newest stable release: v%s\n' "$stable_v"
  [ -n "$overall_v" ] && [ "$overall_v" != "$would" ] && [ "$overall_v" != "$stable_v" ] && printf 'Newest version overall: v%s\n' "$overall_v"
  printf 'Supported upgrade mode: %s\n' "$mode"
  exit 0
}

# --- section 12: --upgrade-only ---------------------------------------------
upgrade_only_main() {
  local latest mode content tag_hash
  if ! upgrade_prepare_candidate; then
    printf '%s v%s%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION" "$UPGRADE_BANNER_NOTE"
    exit 0
  fi
  case "$mode" in
    replacement)
      local tmp
      tmp=$(upgrade_write_temp_sibling "$content" "$SCRIPT_PATH")
      if [ -z "$tmp" ] || ! upgrade_verify_disk_hash "$tmp" "$tag_hash"; then
        [ -n "$tmp" ] && rm -f "$tmp"
        printf '%s v%s (upgrade to v%s failed to persist: write/verify failed)\n' "$SCRIPT_NAME" "$SCRIPT_VERSION" "$latest"
        exit 1
      fi
      if upgrade_persist_replacement "$tmp" "$SCRIPT_PATH"; then
        printf '%s: upgrade to v%s applied (replacement)\n' "$SCRIPT_NAME" "$latest"
        exit 0
      fi
      printf '%s v%s (upgrade to v%s failed to persist: could not rename temp file)\n' "$SCRIPT_NAME" "$SCRIPT_VERSION" "$latest"
      exit 1
      ;;
    overwrite)
      local scratch
      scratch=$(upgrade_write_temp_scratch "$content")
      if [ -z "$scratch" ] || ! upgrade_verify_disk_hash "$scratch" "$tag_hash"; then
        [ -n "$scratch" ] && rm -f "$scratch"
        printf '%s v%s (upgrade to v%s failed to persist: write/verify failed)\n' "$SCRIPT_NAME" "$SCRIPT_VERSION" "$latest"
        exit 1
      fi
      rm -f "$scratch"
      if upgrade_persist_overwrite "$content" "$SCRIPT_PATH"; then
        printf '%s: upgrade to v%s applied (overwrite)\n' "$SCRIPT_NAME" "$latest"
        exit 0
      fi
      printf '%s v%s (upgrade to v%s failed to persist: could not rewrite %s)\n' "$SCRIPT_NAME" "$SCRIPT_VERSION" "$latest" "$SCRIPT_PATH"
      exit 1
      ;;
    link)
      local cache_file
      cache_file=$(upgrade_cache_file "$SCRIPT_LANG" "$SCRIPT_NAME")
      if [ -n "$content" ]; then
        if ! upgrade_persist_link "$content" "$cache_file" || ! upgrade_verify_disk_hash "$cache_file" "$tag_hash"; then
          rm -f "$cache_file"
          printf '%s v%s (upgrade to v%s failed to persist: write/verify failed)\n' "$SCRIPT_NAME" "$SCRIPT_VERSION" "$latest"
          exit 1
        fi
      fi
      printf '%s: upgrade to v%s applied (link, cached at %s)\n' "$SCRIPT_NAME" "$latest" "$cache_file"
      exit 0
      ;;
    memory)
      printf '%s v%s (v%s validated successfully but nothing was kept - memory mode persists nothing)\n' "$SCRIPT_NAME" "$SCRIPT_VERSION" "$latest"
      exit 0
      ;;
  esac
}

# --- section 8: ordinary flow (trial-run-then-persist) ----------------------
upgrade_main() {
  # Re-entry guard: this process IS the candidate a parent just handed off
  # to - report the outcome and skip checking again (the parent already did).
  if [ -n "${INTERFACE_CONFIGURATOR_UPGRADE_APPLIED_FROM:-}" ]; then
    UPGRADE_BANNER_NOTE=$(upgrade_banner_note applying "$INTERFACE_CONFIGURATOR_UPGRADE_APPLIED_FROM" "$INTERFACE_CONFIGURATOR_UPGRADE_APPLIED_MODE")
    unset INTERFACE_CONFIGURATOR_UPGRADE_APPLIED_FROM INTERFACE_CONFIGURATOR_UPGRADE_APPLIED_MODE
    return 0
  fi
  [ "${UPGRADE_TYPE:-}" = "none" ] && return 0
  [ "$NO_AUTOUPDATE" = "true" ] && return 0

  local explicit=0
  [ -n "${UPGRADE_TYPE:-}" ] && explicit=1
  [ -n "${UPGRADE_LEVEL:-}" ] && explicit=1
  local cache_file="${XDG_CACHE_HOME:-$HOME/.cache}/scripts-upgrade/${SCRIPT_LANG}_${SCRIPT_NAME}.state"
  local cache_source="" latest="" mode="" content="" tag_hash=""

  if [ "$explicit" = "0" ] && ! upgrade_cooldown_elapsed "$cache_file"; then
    if ! upgrade_prepare_cached_candidate; then
      UPGRADE_BANNER_NOTE=$(upgrade_banner_note not_checked)
      return 0
    fi
    cache_source=$(upgrade_cache_file "$SCRIPT_LANG" "$SCRIPT_NAME")
  else
    if ! upgrade_prepare_candidate; then
      return 0
    fi
    mkdir -p "$(dirname "$cache_file")" 2>/dev/null
    date +%s > "$cache_file" 2>/dev/null || true
  fi

  export INTERFACE_CONFIGURATOR_UPGRADE_APPLIED_FROM="$SCRIPT_VERSION"
  export INTERFACE_CONFIGURATOR_UPGRADE_APPLIED_MODE="$mode"
  case "$mode" in
    replacement)
      local tmp
      if [ -n "$cache_source" ]; then
        tmp=$(upgrade_write_temp_sibling_from_file "$cache_source" "$SCRIPT_PATH")
      else
        tmp=$(upgrade_write_temp_sibling "$content" "$SCRIPT_PATH")
      fi
      if [ -z "$tmp" ]; then
        unset INTERFACE_CONFIGURATOR_UPGRADE_APPLIED_FROM INTERFACE_CONFIGURATOR_UPGRADE_APPLIED_MODE
        UPGRADE_BANNER_NOTE=$(upgrade_banner_note check_failed "could not write temp file")
        return 0
      fi
      chmod +x "$tmp" 2>/dev/null
      "$tmp" "$@"; local code=$?
      if [ "$code" -eq 0 ]; then
        if ! upgrade_verify_disk_hash "$tmp" "$tag_hash"; then
          rm -f "$tmp"
          printf '%s: upgrade to v%s failed to persist (replacement): on-disk content hash mismatch after trial run - not applied, will retry next run\n' "$SCRIPT_NAME" "$latest" >&2
        elif upgrade_persist_replacement "$tmp" "$SCRIPT_PATH"; then
          printf '%s: upgrade to v%s applied (replacement)\n' "$SCRIPT_NAME" "$latest" >&2
        else
          rm -f "$tmp"
          printf '%s: upgrade to v%s failed to persist (replacement): could not rename temp file - will retry next run\n' "$SCRIPT_NAME" "$latest" >&2
        fi
      fi
      exit "$code"
      ;;
    overwrite)
      local scratch=""
      if [ -n "$cache_source" ]; then
        bash "$cache_source" "$@"; local code=$?
      else
        scratch=$(upgrade_write_temp_scratch "$content")
        if [ -z "$scratch" ]; then
          unset INTERFACE_CONFIGURATOR_UPGRADE_APPLIED_FROM INTERFACE_CONFIGURATOR_UPGRADE_APPLIED_MODE
          UPGRADE_BANNER_NOTE=$(upgrade_banner_note check_failed "could not write temp file")
          return 0
        fi
        bash "$scratch" "$@"; local code=$?
      fi
      if [ "$code" -eq 0 ]; then
        if [ -n "$cache_source" ]; then
          if upgrade_persist_overwrite_from_file "$cache_source" "$SCRIPT_PATH"; then
            printf '%s: upgrade to v%s applied (overwrite)\n' "$SCRIPT_NAME" "$latest" >&2
          else
            printf '%s: upgrade to v%s failed to persist (overwrite): could not rewrite %s - will retry next run\n' "$SCRIPT_NAME" "$latest" "$SCRIPT_PATH" >&2
          fi
        else
          local mismatch=0
          if [ -n "$scratch" ]; then
            upgrade_verify_disk_hash "$scratch" "$tag_hash" || mismatch=1
          fi
          if [ "$mismatch" = "1" ]; then
            printf '%s: upgrade to v%s failed to persist (overwrite): on-disk content hash mismatch after trial run - not applied, will retry next run\n' "$SCRIPT_NAME" "$latest" >&2
          elif upgrade_persist_overwrite "$content" "$SCRIPT_PATH"; then
            printf '%s: upgrade to v%s applied (overwrite)\n' "$SCRIPT_NAME" "$latest" >&2
          else
            printf '%s: upgrade to v%s failed to persist (overwrite): could not rewrite %s - will retry next run\n' "$SCRIPT_NAME" "$latest" "$SCRIPT_PATH" >&2
          fi
        fi
      fi
      [ -n "$scratch" ] && rm -f "$scratch"
      exit "$code"
      ;;
    link)
      local cache_file2; cache_file2=$(upgrade_cache_file "$SCRIPT_LANG" "$SCRIPT_NAME")
      if [ -n "$content" ]; then
        if ! upgrade_persist_link "$content" "$cache_file2"; then
          unset INTERFACE_CONFIGURATOR_UPGRADE_APPLIED_FROM INTERFACE_CONFIGURATOR_UPGRADE_APPLIED_MODE
          UPGRADE_BANNER_NOTE=$(upgrade_banner_note check_failed "could not write cache")
          return 0
        fi
        if ! upgrade_verify_disk_hash "$cache_file2" "$tag_hash"; then
          rm -f "$cache_file2"
          unset INTERFACE_CONFIGURATOR_UPGRADE_APPLIED_FROM INTERFACE_CONFIGURATOR_UPGRADE_APPLIED_MODE
          UPGRADE_BANNER_NOTE=$(upgrade_banner_note hash_mismatch "$latest" "$SCRIPT_VERSION")
          return 0
        fi
      fi
      "$cache_file2" "$@"; local code=$?
      [ "$code" -ne 0 ] && rm -f "$cache_file2"
      exit "$code"
      ;;
    memory)
      local scratch; scratch=$(upgrade_write_temp_scratch "$content")
      if [ -z "$scratch" ]; then
        unset INTERFACE_CONFIGURATOR_UPGRADE_APPLIED_FROM INTERFACE_CONFIGURATOR_UPGRADE_APPLIED_MODE
        UPGRADE_BANNER_NOTE=$(upgrade_banner_note check_failed "could not write temp file")
        return 0
      fi
      bash "$scratch" "$@"; local code=$?
      rm -f "$scratch"
      exit "$code"
      ;;
  esac
}

# =============================================================================
# Self-upgrade (script-upgrade-convention.md) - ends
# =============================================================================

# =============================================================================
# --help (docs/requirements/generic/script-maintenance-convention.md sec. 2)
# =============================================================================

usage_region() {
  sed -n "/^# HELP:$1:BEGIN\$/,/^# HELP:$1:END\$/p" "$0" | sed '1d;$d'
}

usage_header_fields() {
  sed -n '2,5p' "$0"
}

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

# =============================================================================
# Argument parsing
# =============================================================================

MODE=""
INSTALL_PATTERN=""
declare -a ADD_COMMANDS=()
declare -a REMOVE_COMMANDS=()
UNINSTALL_PATTERN=""
RUN_IFACE=""
UPGRADE_TYPE=""
UPGRADE_LEVEL=""
NO_AUTOUPDATE=false
UPGRADE_CHECK=false
UPGRADE_ONLY=false

# Captured before the parsing loop below consumes "$@", so upgrade_main can
# forward the original arguments unchanged to a trial-run child process.
ORIGINAL_ARGS=("$@")

while [ $# -gt 0 ]; do
  case "$1" in
    --install)
      [ -n "$MODE" ] && { err "Error: --install/--uninstall/--run are mutually exclusive"; exit 1; }
      INSTALL_PATTERN="${2:-}"
      if [ -z "$INSTALL_PATTERN" ]; then
        err "Error: --install requires <interface_pattern>"
        exit 1
      fi
      reject_newline "$INSTALL_PATTERN" "--install <interface_pattern>"
      MODE="install"
      shift 2
      while [ $# -gt 0 ]; do
        case "$1" in
          --add)
            if [ -z "${2:-}" ]; then
              err "Error: --add requires a command"
              exit 1
            fi
            reject_newline "$2" "--add <command>"
            ADD_COMMANDS+=("$2")
            shift 2
            ;;
          --remove)
            if [ -z "${2:-}" ]; then
              err "Error: --remove requires a command"
              exit 1
            fi
            reject_newline "$2" "--remove <command>"
            REMOVE_COMMANDS+=("$2")
            shift 2
            ;;
          *) break ;;
        esac
      done
      if [ ${#ADD_COMMANDS[@]} -eq 0 ]; then
        err "Error: --install requires at least one --add <command>"
        exit 1
      fi
      ;;
    --uninstall)
      [ -n "$MODE" ] && { err "Error: --install/--uninstall/--run are mutually exclusive"; exit 1; }
      MODE="uninstall"
      shift
      if [ $# -gt 0 ] && [[ "$1" != -* ]]; then
        UNINSTALL_PATTERN="$1"
        shift
      fi
      ;;
    --run)
      [ -n "$MODE" ] && { err "Error: --install/--uninstall/--run are mutually exclusive"; exit 1; }
      RUN_IFACE="${2:-}"
      if [ -z "$RUN_IFACE" ]; then
        err "Error: --run requires <interface_name>"
        exit 1
      fi
      MODE="run"
      shift 2
      ;;
    -h|--help)
      case "${2:-}" in
        full) usage full ;;
        upgrade) usage upgrade ;;
        *) usage core ;;
      esac
      ;;
    # --- self-upgrade: flags (script-upgrade-convention.md section 13) ----
    --no-autoupdate) NO_AUTOUPDATE=true; shift ;;
    --upgrade-type)
      if [ -z "${2:-}" ]; then
        err "Error: --upgrade-type requires a value"
        exit 1
      fi
      case "$2" in
        replacement|overwrite|link|memory|none) ;;
        *) err "Error: invalid --upgrade-type value '$2'"; exit 1 ;;
      esac
      UPGRADE_TYPE="$2"
      shift 2
      ;;
    --upgrade-level)
      if [ -z "${2:-}" ]; then
        err "Error: --upgrade-level requires a value"
        exit 1
      fi
      case "$2" in
        dev|alpha|beta|rc|stable) ;;
        *) err "Error: invalid --upgrade-level value '$2'"; exit 1 ;;
      esac
      UPGRADE_LEVEL="$2"
      shift 2
      ;;
    --upgrade-check) UPGRADE_CHECK=true; shift ;;
    --upgrade-only) UPGRADE_ONLY=true; shift ;;
    *)
      err "Error: unrecognized option '$1'"
      exit 1
      ;;
  esac
done

if [ -n "$UPGRADE_TYPE" ] && { [ "$NO_AUTOUPDATE" = "true" ] || $UPGRADE_CHECK; }; then
  err "Error: --upgrade-type is not combinable with --no-autoupdate or --upgrade-check"
  exit 1
fi
if $UPGRADE_CHECK && $UPGRADE_ONLY; then
  err "Error: --upgrade-check is not combinable with --upgrade-only"
  exit 1
fi

# --- self-upgrade: standalone entry points ----------------------------------
$UPGRADE_CHECK && upgrade_check_main
$UPGRADE_ONLY && upgrade_only_main

if [ -z "$MODE" ]; then
  err "Error: exactly one of --install/--uninstall/--run is required"
  usage core
fi

require_platform

if [ "$MODE" = "run" ]; then
  # --run does not go through the standard self-upgrade flow - the unit
  # file already passed --no-autoupdate explicitly (see shared_unit_content).
  cmd_run "$RUN_IFACE"
fi

require_root

# --- self-upgrade: ordinary flow (section 8) --------------------------------
upgrade_main "${ORIGINAL_ARGS[@]+"${ORIGINAL_ARGS[@]}"}"

log "interface-configurator v${SCRIPT_VERSION}${UPGRADE_BANNER_NOTE}"

case "$MODE" in
  install) cmd_install "$INSTALL_PATTERN" ADD_COMMANDS REMOVE_COMMANDS ;;
  uninstall) cmd_uninstall "$UNINSTALL_PATTERN" ;;
esac

exit 0
