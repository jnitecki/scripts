#!/usr/bin/env bash
# Reference blueprint — bash — for the self-upgrade mechanism defined in
# docs/requirements/generic/script-upgrade-convention.md.
#
# This file is NOT a standalone script and is never sourced by a deployed
# script at runtime. Scripts in this repo are self-contained single files
# (see cross-platform-shell-compatibility and the standalone-deployment
# note in script-upgrade-convention.md's section 1), so the functions below
# are a copy/adapt source: paste and adjust the relevant parts directly
# into a script's own file, substituting the placeholder identity values
# with that script's real ones.
#
# Written to be bash-3.2-safe (no `declare -A`, no `mapfile`, no `${x,,}`)
# per docs/requirements/generic/cross-platform-shell-compatibility.md.
#
# Per section 15 of the convention, every upgrade-related function lives in
# this one contiguous, clearly-marked block; an adopting script's own
# top-level flow should mark its upgrade-related call sites the same way
# (see the orchestration sketch at the bottom of this file for the pattern).

# =============================================================================
# Self-upgrade (script-upgrade-convention.md) - begins
# =============================================================================

# --- Identity, read from the adopting script's own header (section 1) ------
# SCRIPT_PATH="$0"
# SCRIPT_LANG="bash"
# SCRIPT_NAME="container-upgrader"                # matches platforms/<lang>/<name>/
# SCRIPT_VERSION="1.0.9"                          # parsed from own "# Version:" line
# UPGRADE_HOST="github.com"
# UPGRADE_OWNER="jnitecki"
# UPGRADE_REPO="scripts"
# UPGRADE_TIMEOUT=10                              # seconds, per HTTP call
# UPGRADE_COOLDOWN_SECONDS=1200                    # 20 minutes, section 14
# --- Parsed from CLI flags (section 13), all optional ----------------------
# UPGRADE_TYPE=""            # replacement|overwrite|link|memory|none
# UPGRADE_LEVEL=""           # dev|alpha|beta|rc|stable
# NO_AUTOUPDATE=0            # 1 if --no-autoupdate was passed

# --- section 3: release levels ----------------------------------------------
# dev < alpha < beta < rc < stable (same precedence as script-catalog-generator).
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

# args: $1="X.Y.Z" or "X.Y.Z-<level><N>" (N optional, e.g. "-dev", "-dev1",
# "-rc12") -> prints the bare level word ("dev"/"alpha"/"beta"/"rc"), or
# "stable" if there is no suffix at all. Strips a trailing revision number
# (docs/requirements/generic/script-maintenance-convention.md section 4)
# before returning, so "dev12" and "dev" both report level "dev" - the
# number is a within-level tiebreaker (see upgrade_version_number/
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
# Companion to upgrade_version_level - see its comment for why the number
# is stripped from the level there and compared here instead.
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

# --- numeric major.minor.patch comparison (no `sort -V`; BSD `sort` lacks --
# it, see cross-platform-shell-compatibility.md), with level+number as a ---
# tiebreaker when X.Y.Z is equal (script-maintenance-convention.md section --
# 4): 1.2.3-dev1 < 1.2.3-dev2 < 1.2.3-rc1 < 1.2.3 (stable) < 1.2.4-dev1. ----
# This is pure ordering - it does NOT enforce the separate eligibility gate
# (upgrade_highest_at_level's min-level filter) that keeps e.g. a running
# stable 1.2.3 from ever treating 1.2.4-beta1 as a candidate at all; that
# gate runs first, before this function is ever asked to compare anything.
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

# args: $1=owner $2=repo $3=lang $4=name -> prints the raw matching-refs
# JSON on stdout, or nothing + return 1 on any failure.
upgrade_fetch_tags_json() {
  local owner="$1" repo="$2" lang="$3" name="$4"
  curl -fsS --max-time "${UPGRADE_TIMEOUT:-10}" \
    "https://api.github.com/repos/${owner}/${repo}/git/matching-refs/tags/${lang}/${name}/v"
}

# args: $1=json $2=lang $3=name -> prints "version level" pairs, one per
# discovered tag (stable and pre-release alike), one per line. `version` is
# the tag's full version string, suffix (and revision number) included -
# it is NOT reduced to bare X.Y.Z here, unlike an earlier version of this
# blueprint: doing so silently discarded the suffix before it ever reached
# upgrade_download/upgrade_fetch_tag_hash (both need the exact tag string,
# e.g. "1.0.8-beta", to build a correct `v<version>` URL) and made two
# same-X.Y.Z pre-release tags indistinguishable to upgrade_highest_at_level
# (see upgrade_version_gt's level+number tiebreak above, which only works
# if the full string survives this far). No `jq` dependency - a simple sed
# extraction, same tradeoff as the rest of this blueprint.
upgrade_parse_versions() {
  # `\?`/`\{0,1\}` (optional-group BRE syntax) is a GNU sed extension BSD
  # sed doesn't support (cross-platform-shell-compatibility.md) - capturing
  # everything up to the closing quote with [^"]* avoids needing it at all,
  # since a tag ref never contains anything else there.
  local json="$1" lang="$2" name="$3" refs r
  refs=$(printf '%s\n' "$json" \
    | sed -n 's/.*"ref": *"refs\/tags\/'"${lang}"'\/'"${name}"'\/v\([^"]*\)".*/\1/p')
  for r in $refs; do
    printf '%s %s\n' "$r" "$(upgrade_version_level "$r")"
  done
}

# args: $1=owner $2=repo $3=lang $4=name -> prints "version level" pairs for
# every discovered tag (one fetch), or nothing + return 1 on failure. Callers
# needing more than one filtered view (e.g. --upgrade-check's three lines)
# should call this once and reuse the result with upgrade_highest_at_level,
# rather than re-fetching.
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

# args: $1=mode $2=script_path $3=cache_dir -> 0 if that mode's filesystem
# precondition holds right now.
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

# args: $1=ceiling ("" = uncapped, i.e. start at replacement) $2=script_path
#       $3=cache_dir
# -> prints the strongest mode reachable at or below the ceiling. Always
# resolves to at least "memory" (its precondition is unconditional).
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

# args: $1=file path -> prints the version declared in that file's own
# "# Version: X.Y.Z[-<level><N>]" header line (script-header-convention,
# extended by script-maintenance-convention.md section 4's trailing
# revision number), or nothing + return 1 if the file doesn't exist or its
# header doesn't match. Used to read an already-cached candidate's version
# (section 7) locally, with no network round-trip - section 2's cooldown
# clarification relies on this to decide whether a cached file is worth
# promoting to a stronger apply mode.
upgrade_file_version() {
  local file="$1" line
  line=$(grep -m1 -E '^# Version: [0-9]+\.[0-9]+\.[0-9]+(-[a-z]+[0-9]*)?$' "$file" 2>/dev/null) || return 1
  printf '%s' "${line##*: }"
}

# --- section 5: download the candidate + syntax-only validation ------------

# args: $1=owner $2=repo $3=lang $4=name $5=version -> prints content on
# stdout, followed by a single sentinel byte (\x01, never legitimately
# part of a bash script's source). PITFALL (this convention's own
# reference implementation shipped with this bug - see section 5's
# "Implementation note" in the convention doc): a caller capturing this
# via plain `content=$(upgrade_download ...)` would otherwise silently
# lose every trailing newline to command substitution's stripping, which
# permanently mismatches the release-tag hook's declared hash (computed
# off `git show`'s output, newline intact) even though the download itself
# is perfectly fine. The sentinel defeats that stripping; the caller
# recovers the byte-exact original with `"${captured%$'\x01'}"`. Exit
# status is curl's own, not printf's.
upgrade_download() {
  # args: $1=owner $2=repo $3=lang $4=name $5=version
  local owner="$1" repo="$2" lang="$3" name="$4" version="$5" rc
  curl -fsS --max-time "${UPGRADE_TIMEOUT:-10}" \
    "https://raw.githubusercontent.com/${owner}/${repo}/${lang}/${name}/v${version}/platforms/${lang}/${name}/${name}.sh"
  rc=$?
  printf '\x01'
  return "$rc"
}

upgrade_validate_parse() {
  # args: $1=content -> 0 if it parses as bash, 1 otherwise
  printf '%s\n' "$1" | bash -n - 2>/dev/null
}

# --- section 5 (best-effort): content-hash match against the release tag ---

# args: $1=owner $2=repo $3=lang $4=name $5=version -> prints the tag's
# declared 12-hex-char hash prefix (see release-tag-hook.md), or nothing on
# any failure (unreachable, no [<hash>] prefix on the tag) - not fatal, the
# caller treats "nothing" as "skip the check".
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

# args: $1=content -> prints the first 12 hex chars of its plain SHA-1, or
# nothing if neither sha1sum nor shasum is available locally.
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

# args: $1=file path -> prints the first 12 hex chars of its plain SHA-1,
# or nothing if neither sha1sum nor shasum is available, or the file can't
# be read. Hashes the file directly (no bash-variable round-trip), so
# unlike upgrade_hash_prefix on a captured variable, there is no risk of
# command substitution silently stripping trailing newlines and skewing
# the result - same pitfall upgrade_download's sentinel byte works around,
# but here avoided by not going through a variable at all. Used for a
# `link`-mode cache-hit's own hash check (section 7) and for the
# persist-time re-verification below (section 6).
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
# to compare against, same "not fail-closed" treatment as section 5's
# check) -> 0 if the file's on-disk hash matches (or there's nothing to
# verify), 1 on an actual computed mismatch.
upgrade_verify_disk_hash() {
  local path="$1" expected="$2" actual
  [ -n "$expected" ] || return 0
  actual=$(upgrade_hash_prefix_file "$path")
  [ -z "$actual" ] || [ "$actual" = "$expected" ]
}

# --- section 14: cooldown cache (implicit invocations only) ----------------
# args: $1=cache_file -> 0 (true) if the cooldown window has elapsed, or
# there's no cache yet.
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
# `chmod --reference`/`chown --reference` are GNU-only and fail silently
# under macOS's BSD chmod/chown (bash-3.2 target), so mode/owner/group are
# read via `stat` (GNU form tried first, BSD form as fallback - same pattern
# as cross-platform-shell-compatibility.md's `parse_to_epoch` for `date`)
# and re-applied explicitly instead.

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
  [ -n "$mode" ] && chmod "$mode" "$target" 2>/dev/null
  owner_group=$(upgrade_stat_owner_group "$source")
  [ -n "$owner_group" ] && chown "$owner_group" "$target" 2>/dev/null
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
# `content=$(cat ...)` round-trip through a bash variable - see section 5's
# "Implementation note" for why capturing file content into a variable is
# unsafe here (it would strip trailing newlines the same way a naive
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
# (upgrade_verify_disk_hash) before the actual overwrite commits - see
# "Persist-time re-verification" below. Prints the temp file's path, or
# nothing + return 1 on failure.
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
# way; an implementation that instead staged the write through some other
# intermediate file and then swapped it in would need to explicitly copy
# script_path's original mode/ownership onto that replacement first.
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
# cache location (creating its directory), executable. Unlike the other two
# modes, this happens *before* the trial run (the trial candidate's own
# location is the cache file) - upgrade_main removes it again if the trial
# then fails, so a broken version is never left cached.
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

# =============================================================================
# Self-upgrade (script-upgrade-convention.md) - ends
# =============================================================================

# =============================================================================
# Orchestration sketch (ties the pieces above together) - also part of the
# self-upgrade block; kept separate only because it's illustrative/commented
# rather than functions to copy verbatim, since flag parsing, the
# --upgrade-check/--upgrade-only branches, and the guard-var re-entry check
# all need to be wired into a specific script's own top-level flow.
# =============================================================================
#
# --- self-upgrade: flag parsing (add to the adopting script's own loop) ----
# --upgrade-type <replacement|overwrite|link|memory|none>  -> UPGRADE_TYPE
# --upgrade-level <dev|alpha|beta|rc|stable>                -> UPGRADE_LEVEL
# --upgrade-check                                            -> exit via upgrade_check_main
# --upgrade-only                                             -> exit via upgrade_only_main
# --no-autoupdate                                            -> NO_AUTOUPDATE=1
# (reject --upgrade-type combined with --no-autoupdate or --upgrade-check;
#  reject --upgrade-check combined with --upgrade-only; reject unrecognized
#  --upgrade-type/--upgrade-level values - all per section 13)
#
# --- self-upgrade: --help layering (docs/requirements/generic/script-------
# --- maintenance-convention.md section 2) - sketch --------------------------
# For a script that adopts self-upgrade, bare `--help` shows that script's
# own options only; `--help upgrade` shows only these self-upgrade options;
# `--help full` shows both, self-upgrade options always last. The adopting
# script's usage() should slice its self-upgrade option docs out of its own
# header by content (a "# HELP:UPGRADE-OPTIONS:BEGIN"/"...:END" marker
# pair), not by line number - line-number slicing breaks every time
# unrelated header content (e.g. the version history) grows or shrinks.
# usage_region() {
#   sed -n "/^# HELP:$1:BEGIN\$/,/^# HELP:$1:END\$/p" "$0" | sed '1d;$d'
# }
# usage() {
#   case "${1:-core}" in
#     full) ... usage_region CORE-OPTIONS; ... usage_region UPGRADE-OPTIONS; ... ;;
#     upgrade)
#       printf '# Self-upgrade options only - see --help for this script'"'"'s own\n# options, or --help full for everything together.\n'
#       usage_region UPGRADE-OPTIONS
#       ;;
#     core|*)
#       ... usage_region CORE-OPTIONS
#       printf '# Self-upgrade options are not shown here - see --help upgrade,\n# or --help full for everything together.\n'
#       ;;
#   esac
#   exit 1
# }
# -h|--help) case "${2:-}" in full) usage full ;; upgrade) usage upgrade ;; *) usage core ;; esac ;;
#
# --- self-upgrade: --upgrade-check (section 11) - sketch -------------------
# upgrade_check_main() {
#   local mode cache_dir versions effective_level would stable_v overall_v
#   cache_dir=$(upgrade_cache_dir "$SCRIPT_LANG" "$SCRIPT_NAME")
#   mode=$(upgrade_select_mode "" "$SCRIPT_PATH" "$cache_dir")
#   if ! versions=$(upgrade_discover "$UPGRADE_OWNER" "$UPGRADE_REPO" "$SCRIPT_LANG" "$SCRIPT_NAME"); then
#     printf '%s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
#     printf 'upgrade check failed: could not reach %s\n' "$UPGRADE_HOST"
#     printf 'Supported upgrade mode: %s\n' "$mode"
#     exit 1
#   fi
#   effective_level="${UPGRADE_LEVEL:-$(upgrade_version_level "$SCRIPT_VERSION")}"
#   would=$(upgrade_highest_at_level "$versions" "$effective_level")
#   stable_v=$(upgrade_highest_at_level "$versions" stable)
#   overall_v=$(upgrade_highest_at_level "$versions" dev)
#   printf '%s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
#   if [ -n "$would" ] && upgrade_version_gt "$would" "$SCRIPT_VERSION"; then
#     printf 'Would upgrade to: v%s (level: %s)\n' "$would" "$effective_level"
#   else
#     printf 'No upgrade present\n'
#   fi
#   [ -n "$stable_v" ] && [ "$stable_v" != "$would" ] && printf 'Newest stable release: v%s\n' "$stable_v"
#   [ -n "$overall_v" ] && [ "$overall_v" != "$would" ] && [ "$overall_v" != "$stable_v" ] && printf 'Newest version overall: v%s\n' "$overall_v"
#   printf 'Supported upgrade mode: %s\n' "$mode"
#   exit 0
# }
#
# --- self-upgrade: shared discovery + download + validate, used by both ----
# --- upgrade_only_main and upgrade_main below -------------------------------
# upgrade_prepare_candidate() {
#   # Sets $latest, $mode, $content (possibly empty on a link-mode cache
#   # hit), and $tag_hash (the winning tag's declared hash, possibly empty -
#   # reused by both callers below for persist-time re-verification instead
#   # of re-fetching it) in the caller's scope; returns 1 with
#   # UPGRADE_BANNER_NOTE set on any failure, exactly as upgrade_main's
#   # inline version does (see below) - in a real adopting script this logic
#   # is a single shared function rather than duplicated between the two
#   # callers. Discovery succeeding but finding nothing eligible (nothing at
#   # the effective level, or nothing newer than $SCRIPT_VERSION) is also a
#   # "failure" by this function's contract: set UPGRADE_BANNER_NOTE via
#   # `upgrade_banner_note no_upgrade` and return 1, same as any other
#   # pre-trial outcome (section 10). A link-mode cache-hit check compares
#   # via `upgrade_hash_prefix_file "$cache_file"`, never
#   # `upgrade_hash_prefix "$(cat "$cache_file")"` - see section 5's
#   # "Implementation note" for why that capture-then-hash form is broken.
#   :
# }
#
# --- self-upgrade: local-only counterpart to upgrade_prepare_candidate, ----
# --- used only when the cooldown has suppressed a fresh remote check -------
# --- (section 2's cooldown clarification) - sketch --------------------------
# upgrade_prepare_cached_candidate() {
#   # No network calls at all - looks only at whatever already sits in the
#   # link-mode cache (section 7) from an earlier run, and at this run's own
#   # freshly-determined filesystem eligibility (section 6, always
#   # re-evaluated, never cached). Sets $latest and $mode in the caller's
#   # scope on success (mirroring upgrade_prepare_candidate's contract), but
#   # never sets $content - the caller reads bytes straight from the cache
#   # file itself (upgrade_cache_file) via upgrade_write_temp_sibling_from_
#   # file / upgrade_persist_overwrite_from_file, never through a variable
#   # (same capture pitfall as section 5's "Implementation note"). Returns 1
#   # with no UPGRADE_BANNER_NOTE set (this is not itself a failure - the
#   # caller's existing cooldown "not_checked" banner still applies) when
#   # there is nothing to promote: no cache file, its declared version isn't
#   # actually newer than $SCRIPT_VERSION, it's below the effective level, or
#   # this run's mode hasn't actually escalated past `link` (still `link` or
#   # `memory` - nothing gained by "promoting" to the same or a weaker mode).
#   local cache_dir cache_file cached_version
#   cache_dir=$(upgrade_cache_dir "$SCRIPT_LANG" "$SCRIPT_NAME")
#   cache_file=$(upgrade_cache_file "$SCRIPT_LANG" "$SCRIPT_NAME")
#   [ -f "$cache_file" ] || return 1
#   cached_version=$(upgrade_file_version "$cache_file") || return 1
#   upgrade_version_gt "$cached_version" "$SCRIPT_VERSION" || return 1
#   local effective_level effective_rank cached_rank
#   effective_level="${UPGRADE_LEVEL:-$(upgrade_version_level "$SCRIPT_VERSION")}"
#   effective_rank=$(upgrade_level_rank "$effective_level") || return 1
#   cached_rank=$(upgrade_level_rank "$(upgrade_version_level "$cached_version")") || return 1
#   [ "$cached_rank" -ge "$effective_rank" ] || return 1
#   mode=$(upgrade_select_mode "$UPGRADE_TYPE" "$SCRIPT_PATH" "$cache_dir")
#   case "$mode" in
#     replacement|overwrite) ;;
#     *) return 1 ;;
#   esac
#   latest="$cached_version"
#   return 0
# }
#
# --- self-upgrade: --upgrade-only (section 12) - sketch --------------------
# upgrade_only_main() {
#   # ... discover/download/validate via upgrade_prepare_candidate ...
#   # ... then persist directly, no trial run - each mode's write is
#   # re-verified against $tag_hash (upgrade_verify_disk_hash) before it's
#   # treated as committed, same "Persist-time re-verification" (section 6)
#   # upgrade_main applies below, just with no trial run to have already
#   # produced a file for replacement/overwrite to reuse:
#   #   replacement -> upgrade_write_temp_sibling, verify, then
#   #                  upgrade_persist_replacement
#   #   overwrite   -> upgrade_write_temp_scratch (a verify-only copy, since
#   #                  there's no temp file otherwise), verify, then
#   #                  upgrade_persist_overwrite, then discard the scratch
#   #   link        -> upgrade_persist_link, then verify the cache file
#   #                  itself (already the persist step - link has no
#   #                  separate "commit" moment to check before)
#   #   memory      -> nothing to persist; report that plainly
#   #   A verify failure here reports the mismatch and `exit 1` - unlike
#   #   upgrade_main's trial-run flow, nothing has run yet, so there's no
#   #   trial exit code to preserve.
#   exit 0
# }
#
# --- self-upgrade: ordinary flow (section 8, trial-run-then-persist) -------
# upgrade_main() {
#   # Re-entry guard: this process IS the candidate a parent just handed off
#   # to - report the outcome and skip checking again (the parent already did).
#   if [ -n "${CONTAINER_UPGRADE_APPLIED_FROM:-}" ]; then
#     UPGRADE_BANNER_NOTE=$(upgrade_banner_note applying "$CONTAINER_UPGRADE_APPLIED_FROM" "$CONTAINER_UPGRADE_APPLIED_MODE")
#     unset CONTAINER_UPGRADE_APPLIED_FROM CONTAINER_UPGRADE_APPLIED_MODE
#     return 0
#   fi
#   [ "$UPGRADE_TYPE" = "none" ] && return 0
#   [ "$NO_AUTOUPDATE" = "1" ] && return 0
#
#   local explicit=0
#   [ -n "$UPGRADE_TYPE" ] && explicit=1
#   [ -n "$UPGRADE_LEVEL" ] && explicit=1
#   local cache_file="${XDG_CACHE_HOME:-$HOME/.cache}/scripts-upgrade/${SCRIPT_LANG}_${SCRIPT_NAME}.state"
#   local cache_source=""
#   if [ "$explicit" = "0" ] && ! upgrade_cooldown_elapsed "$cache_file"; then
#     # Section 2's cooldown clarification: the cooldown only gates the
#     # *remote* discovery/download below - local apply-mode eligibility is
#     # always re-evaluated fresh regardless, so an already-cached,
#     # already-validated candidate can still be promoted straight to a
#     # stronger mode right now if that eligibility has newly escalated past
#     # `link` (e.g. this run is `sudo`, the one that cached it wasn't). No
#     # cooldown timestamp is written below in this branch - nothing remote
#     # was actually checked, so the original schedule is left untouched.
#     if ! upgrade_prepare_cached_candidate; then
#       UPGRADE_BANNER_NOTE=$(upgrade_banner_note not_checked)
#       return 0
#     fi
#     cache_source=$(upgrade_cache_file "$SCRIPT_LANG" "$SCRIPT_NAME")
#   else
#     # ... discover/download/validate via upgrade_prepare_candidate (sets
#     # $latest, $mode, $content, $tag_hash) ...
#     # On any pre-trial failure (including "nothing eligible" - see that
#     # function's own comment above): set UPGRADE_BANNER_NOTE and
#     # `return 0` (falls back to this process's own work) - never `exit`.
#     #
#     # Best-effort cache write (section 14) - only here, since only this
#     # branch actually performed a remote check.
#   fi
#
#   export CONTAINER_UPGRADE_APPLIED_FROM="$SCRIPT_VERSION"
#   export CONTAINER_UPGRADE_APPLIED_MODE="$mode"
#   case "$mode" in
#     replacement)
#       # $content is empty when this candidate was promoted from the local
#       # cache (cache_source set above, not a remote download) - read bytes
#       # straight from that file instead, byte-exact, no variable round-trip.
#       local tmp
#       if [ -n "$cache_source" ]; then
#         tmp=$(upgrade_write_temp_sibling_from_file "$cache_source" "$SCRIPT_PATH")
#       else
#         tmp=$(upgrade_write_temp_sibling "$content" "$SCRIPT_PATH")
#       fi
#       [ -n "$tmp" ] || { unset CONTAINER_UPGRADE_APPLIED_FROM CONTAINER_UPGRADE_APPLIED_MODE; UPGRADE_BANNER_NOTE=$(upgrade_banner_note check_failed "could not write temp file"); return 0; }
#       "$tmp" "$@"; local code=$?
#       if [ "$code" -eq 0 ]; then
#         # Persist-time re-verification (section 6): re-hash the actual
#         # bytes on disk - not $content again, which wouldn't catch
#         # anything new - right before they become the live script. Then
#         # persist-outcome reporting (section 8): the trial run's own
#         # output already printed; this is a separate line, after it,
#         # stating what happened. Neither ever changes $code.
#         if ! upgrade_verify_disk_hash "$tmp" "$tag_hash"; then
#           rm -f "$tmp"
#           printf '%s: upgrade to v%s failed to persist (replacement): on-disk content hash mismatch after trial run - not applied, will retry next run\n' "$SCRIPT_NAME" "$latest" >&2
#         elif upgrade_persist_replacement "$tmp" "$SCRIPT_PATH"; then
#           printf '%s: upgrade to v%s applied (replacement)\n' "$SCRIPT_NAME" "$latest" >&2
#         else
#           rm -f "$tmp"
#           printf '%s: upgrade to v%s failed to persist (replacement): could not rename temp file - will retry next run\n' "$SCRIPT_NAME" "$latest" >&2
#         fi
#       fi
#       exit "$code"   # candidate's real work already ran either way - no retry, see section 9
#       ;;
#     overwrite)
#       local scratch=""
#       if [ -n "$cache_source" ]; then
#         # A real, already-executable file on disk - run it directly, no
#         # need for the scratch-file workaround below at all.
#         "$cache_source" "$@"; local code=$?
#       else
#         # Write the content to a real scratch file and run bash against
#         # that path, rather than `bash -c "$content" <placeholder> "$@"`.
#         # A literal "--" as $0 there would make the candidate's own
#         # version-detection `grep ... "$0"` see a trailing "--" with no
#         # filename after it - GNU grep treats that as "end of options"
#         # and falls back to reading stdin, hanging forever with no
#         # output. Swapping in /dev/null (a real, always-empty file) fixes
#         # that hang but breaks the same grep a different way: empty means
#         # no `# Version:` line to find, so the candidate misreports
#         # itself as version "unknown" in its own startup banner instead
#         # (see the convention doc's section 8 implementation note for
#         # both bugs). A real scratch file with real content sidesteps
#         # both at once, and doubles as the persist-time re-verification
#         # copy below instead of being written twice.
#         scratch=$(upgrade_write_temp_scratch "$content")
#         [ -n "$scratch" ] || { unset CONTAINER_UPGRADE_APPLIED_FROM CONTAINER_UPGRADE_APPLIED_MODE; UPGRADE_BANNER_NOTE=$(upgrade_banner_note check_failed "could not write temp file"); return 0; }
#         bash "$scratch" "$@"; local code=$?
#       fi
#       if [ "$code" -eq 0 ]; then
#         if [ -n "$cache_source" ]; then
#           # Already-on-disk, already-hash-validated bytes (section 7) -
#           # copy them straight in, no re-verification target to compare
#           # against (nothing new was downloaded this run).
#           if upgrade_persist_overwrite_from_file "$cache_source" "$SCRIPT_PATH"; then
#             printf '%s: upgrade to v%s applied (overwrite)\n' "$SCRIPT_NAME" "$latest" >&2
#           else
#             printf '%s: upgrade to v%s failed to persist (overwrite): could not rewrite %s - will retry next run\n' "$SCRIPT_NAME" "$latest" "$SCRIPT_PATH" >&2
#           fi
#         else
#           # Persist-time re-verification (section 6), reusing the
#           # scratch file the trial run above already wrote instead of
#           # writing a second copy. A failure to have gotten that scratch
#           # copy just skips the check (best-effort), not a mismatch.
#           local mismatch=0
#           if [ -n "$scratch" ]; then
#             upgrade_verify_disk_hash "$scratch" "$tag_hash" || mismatch=1
#           fi
#           if [ "$mismatch" = "1" ]; then
#             printf '%s: upgrade to v%s failed to persist (overwrite): on-disk content hash mismatch after trial run - not applied, will retry next run\n' "$SCRIPT_NAME" "$latest" >&2
#           elif upgrade_persist_overwrite "$content" "$SCRIPT_PATH"; then
#             printf '%s: upgrade to v%s applied (overwrite)\n' "$SCRIPT_NAME" "$latest" >&2
#           else
#             printf '%s: upgrade to v%s failed to persist (overwrite): could not rewrite %s - will retry next run\n' "$SCRIPT_NAME" "$latest" "$SCRIPT_PATH" >&2
#           fi
#         fi
#       fi
#       [ -n "$scratch" ] && rm -f "$scratch"
#       exit "$code"
#       ;;
#     link)
#       local cache_file2; cache_file2=$(upgrade_cache_file "$SCRIPT_LANG" "$SCRIPT_NAME")
#       # $content is empty on a cache-hit (upgrade_prepare_candidate already
#       # confirmed the cached file's hash matches - nothing new to write or
#       # re-verify).
#       if [ -n "$content" ]; then
#         upgrade_persist_link "$content" "$cache_file2" || { unset CONTAINER_UPGRADE_APPLIED_FROM CONTAINER_UPGRADE_APPLIED_MODE; UPGRADE_BANNER_NOTE=$(upgrade_banner_note check_failed "could not write cache"); return 0; }
#         # Persist-time re-verification (section 6): unlike replacement/
#         # overwrite, "link" persists *before* its trial run (section 7),
#         # so this runs here instead - before the cache file is ever
#         # trusted enough to execute. A mismatch is therefore still a
#         # pre-trial failure (section 9), not a post-trial one: fall back
#         # via `return 0`, never `exit`.
#         if ! upgrade_verify_disk_hash "$cache_file2" "$tag_hash"; then
#           rm -f "$cache_file2"
#           unset CONTAINER_UPGRADE_APPLIED_FROM CONTAINER_UPGRADE_APPLIED_MODE
#           UPGRADE_BANNER_NOTE=$(upgrade_banner_note hash_mismatch "$latest" "$SCRIPT_VERSION")
#           return 0
#         fi
#       fi
#       "$cache_file2" "$@"; local code=$?
#       [ "$code" -ne 0 ] && rm -f "$cache_file2"   # don't leave a broken version cached
#       exit "$code"
#       ;;
#     memory)
#       # See the "overwrite" case above for why the candidate is run from
#       # a real scratch file instead of `bash -c "$content" <placeholder>
#       # "$@"`. Unlike "overwrite", there is no persist step to reuse this
#       # file for afterward - it exists purely to give the trial run a
#       # real $0, discarded immediately once that run exits.
#       local scratch; scratch=$(upgrade_write_temp_scratch "$content")
#       [ -n "$scratch" ] || { unset CONTAINER_UPGRADE_APPLIED_FROM CONTAINER_UPGRADE_APPLIED_MODE; UPGRADE_BANNER_NOTE=$(upgrade_banner_note check_failed "could not write temp file"); return 0; }
#       bash "$scratch" "$@"; local code=$?
#       rm -f "$scratch"
#       exit "$code"   # never persisted, regardless of outcome
#       ;;
#   esac
# }
