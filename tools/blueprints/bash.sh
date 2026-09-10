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
# SCRIPT_NAME="container-upgrade"                # matches platforms/<lang>/<name>/
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

# args: $1="X.Y.Z" or "X.Y.Z-suffix" -> prints the suffix word, or "stable"
# if there is none.
upgrade_version_level() {
  case "$1" in
    *-*) printf '%s' "${1#*-}" ;;
    *) printf 'stable' ;;
  esac
}

# --- numeric major.minor.patch comparison (no `sort -V`; BSD `sort` lacks --
# it, see cross-platform-shell-compatibility.md). Ignores any -suffix on ----
# either side - level filtering (upgrade_highest_at_level) handles that. ----
upgrade_version_gt() {
  # args: $1 > $2 ?
  local a1 a2 a3 b1 b2 b3 rest
  a1=${1%%.*}; rest=${1#*.}; a2=${rest%%.*}; a3=${rest#*.}; a3=${a3%%-*}
  b1=${2%%.*}; rest=${2#*.}; b2=${rest%%.*}; b3=${rest#*.}; b3=${b3%%-*}
  [ "$a1" -gt "$b1" ] && return 0
  [ "$a1" -lt "$b1" ] && return 1
  [ "$a2" -gt "$b2" ] && return 0
  [ "$a2" -lt "$b2" ] && return 1
  [ "$a3" -gt "$b3" ]
}

# --- section 3: discover every matching tag, no `git` required -------------

# args: $1=owner $2=repo $3=lang $4=name -> prints the raw matching-refs
# JSON on stdout, or nothing + return 1 on any failure.
upgrade_fetch_tags_json() {
  local owner="$1" repo="$2" lang="$3" name="$4"
  curl -fsS --max-time "${UPGRADE_TIMEOUT:-10}" \
    "https://api.github.com/repos/${owner}/${repo}/git/matching-refs/tags/${lang}/${name}/v"
}

# args: $1=json $2=lang $3=name -> prints "X.Y.Z level" pairs, one per
# discovered tag (stable and pre-release alike), one per line. No `jq`
# dependency - a simple sed extraction, same tradeoff as the rest of this
# blueprint.
upgrade_parse_versions() {
  # `\?`/`\{0,1\}` (optional-group BRE syntax) is a GNU sed extension BSD
  # sed doesn't support (cross-platform-shell-compatibility.md) - capturing
  # everything up to the closing quote with [^"]* avoids needing it at all,
  # since a tag ref never contains anything else there.
  local json="$1" lang="$2" name="$3" refs r v
  refs=$(printf '%s\n' "$json" \
    | sed -n 's/.*"ref": *"refs\/tags\/'"${lang}"'\/'"${name}"'\/v\([^"]*\)".*/\1/p')
  for r in $refs; do
    v="${r%%-*}"
    printf '%s %s\n' "$v" "$(upgrade_version_level "$r")"
  done
}

# args: $1=owner $2=repo $3=lang $4=name -> prints "X.Y.Z level" pairs for
# every discovered tag (one fetch), or nothing + return 1 on failure. Callers
# needing more than one filtered view (e.g. --upgrade-check's three lines)
# should call this once and reuse the result with upgrade_highest_at_level,
# rather than re-fetching.
upgrade_discover() {
  local owner="$1" repo="$2" lang="$3" name="$4" json
  json=$(upgrade_fetch_tags_json "$owner" "$repo" "$lang" "$name") || return 1
  upgrade_parse_versions "$json" "$lang" "$name"
}

# args: $1=multiline "X.Y.Z level" pairs (as from upgrade_discover)
#       $2=minimum level name
# -> prints the numerically-highest version at or above that level, or
# nothing if none qualify.
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

# --- section 5: download the candidate + syntax-only validation ------------
upgrade_download() {
  # args: $1=owner $2=repo $3=lang $4=name $5=version -> prints content on stdout
  local owner="$1" repo="$2" lang="$3" name="$4" version="$5"
  curl -fsS --max-time "${UPGRADE_TIMEOUT:-10}" \
    "https://raw.githubusercontent.com/${owner}/${repo}/${lang}/${name}/v${version}/platforms/${lang}/${name}/${name}.sh"
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

# --- section 6/8: persistence primitives (pure filesystem, no execution) ---

# args: $1=content $2=script_path -> writes a fresh temp file alongside
# script_path, carrying over the executable bit; prints its path, or
# nothing + return 1 on failure.
upgrade_write_temp_sibling() {
  local content="$1" script_path="$2" tmp
  tmp=$(mktemp "${script_path}.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s' "$content" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  # `chmod --reference` is GNU-only and fails silently under macOS's BSD
  # chmod (bash-3.2 target) - carry over just the executable bit explicitly.
  [ -x "$script_path" ] && chmod +x "$tmp" 2>/dev/null
  printf '%s' "$tmp"
}

# args: $1=temp_file $2=script_path -> the "replacement" persist step.
upgrade_persist_replacement() {
  mv -f "$1" "$2" 2>/dev/null
}

# args: $1=content $2=script_path -> the "overwrite" persist step (rewrites
# the existing, file-writable-but-not-directory-writable script in place).
upgrade_persist_overwrite() {
  printf '%s' "$1" > "$2" 2>/dev/null
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
#   # Sets $latest, $mode, $content (possibly empty on a link-mode cache hit)
#   # in the caller's scope; returns 1 with UPGRADE_BANNER_NOTE set on any
#   # failure, exactly as upgrade_main's inline version does (see below) -
#   # in a real adopting script this logic is a single shared function rather
#   # than duplicated between the two callers.
#   :
# }
#
# --- self-upgrade: --upgrade-only (section 12) - sketch --------------------
# upgrade_only_main() {
#   # ... discover/download/validate via upgrade_prepare_candidate ...
#   # ... then persist directly, no trial run:
#   #   replacement -> upgrade_write_temp_sibling + upgrade_persist_replacement
#   #   overwrite   -> upgrade_persist_overwrite
#   #   link        -> upgrade_persist_link (already the persist step itself)
#   #   memory      -> nothing to persist; report that plainly
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
#   if [ "$explicit" = "0" ]; then
#     upgrade_cooldown_elapsed "$cache_file" || return 0
#   fi
#
#   # ... discover/download/validate via upgrade_prepare_candidate (sets
#   # $latest, $mode, $content) ...
#   # On any pre-trial failure: set UPGRADE_BANNER_NOTE and `return 0`
#   # (falls back to this process doing its own real work) - never `exit`.
#
#   export CONTAINER_UPGRADE_APPLIED_FROM="$SCRIPT_VERSION"
#   export CONTAINER_UPGRADE_APPLIED_MODE="$mode"
#   case "$mode" in
#     replacement)
#       local tmp; tmp=$(upgrade_write_temp_sibling "$content" "$SCRIPT_PATH") || { unset CONTAINER_UPGRADE_APPLIED_FROM CONTAINER_UPGRADE_APPLIED_MODE; UPGRADE_BANNER_NOTE=$(upgrade_banner_note check_failed "could not write temp file"); return 0; }
#       "$tmp" "$@"; local code=$?
#       [ "$code" -eq 0 ] && upgrade_persist_replacement "$tmp" "$SCRIPT_PATH" || rm -f "$tmp"
#       exit "$code"   # candidate's real work already ran either way - no retry, see section 9
#       ;;
#     overwrite)
#       bash -c "$content" -- "$@"; local code=$?
#       [ "$code" -eq 0 ] && upgrade_persist_overwrite "$content" "$SCRIPT_PATH"
#       exit "$code"
#       ;;
#     link)
#       local cache_file2; cache_file2=$(upgrade_cache_file "$SCRIPT_LANG" "$SCRIPT_NAME")
#       # $content is empty on a cache-hit (upgrade_prepare_candidate already
#       # confirmed the cached file's hash matches - nothing new to write).
#       [ -n "$content" ] && { upgrade_persist_link "$content" "$cache_file2" || { unset CONTAINER_UPGRADE_APPLIED_FROM CONTAINER_UPGRADE_APPLIED_MODE; UPGRADE_BANNER_NOTE=$(upgrade_banner_note check_failed "could not write cache"); return 0; }; }
#       "$cache_file2" "$@"; local code=$?
#       [ "$code" -ne 0 ] && rm -f "$cache_file2"   # don't leave a broken version cached
#       exit "$code"
#       ;;
#     memory)
#       bash -c "$content" -- "$@"
#       exit $?   # never persisted, regardless of outcome
#       ;;
#   esac
# }
