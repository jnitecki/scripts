#!/usr/bin/env bash
# Reference blueprint — bash — for the autoupdate mechanism defined in
# docs/requirements/generic/script-autoupdate-convention.md.
#
# This file is NOT a standalone script and is never sourced by a deployed
# script at runtime. Scripts in this repo are self-contained single files
# (see cross-platform-shell-compatibility and the standalone-deployment
# note in script-autoupdate-convention.md's section 1), so the functions
# below are a copy/adapt source: paste and adjust the relevant parts
# directly into a script's own file, replacing the placeholder identity
# values with that script's real ones.
#
# Written to be bash-3.2-safe (no `declare -A`, no `mapfile`, no `${x,,}`)
# per docs/requirements/generic/cross-platform-shell-compatibility.md.

# --- Identity, read from the adopting script's own header (section 1) ---
# SCRIPT_PATH="$0"
# SCRIPT_LANG="bash"
# SCRIPT_NAME="container-upgrade"                # matches platforms/<lang>/<name>/
# LOCAL_VERSION="1.0.7"                           # parsed from own "# Version:" line
# UPDATE_HOST="github.com"
# UPDATE_OWNER="jnitecki"
# UPDATE_REPO="scripts"
# UPDATE_TIMEOUT=10                               # seconds, per HTTP call

# --- section 2: should a check even happen this run? -----------------------
autoupdate_should_check() {
  # args: $1=no_autoupdate_flag(0/1) $2=force_flag(0/1) $3=cache_file
  local no_autoupdate="$1" force="$2" cache_file="$3"
  [ "$no_autoupdate" = "1" ] && return 1
  [ "$force" = "1" ] && return 0
  [ -f "$cache_file" ] || return 0
  local last_checked now cooldown=$((24 * 3600))
  last_checked=$(sed -n '1p' "$cache_file" 2>/dev/null)
  [ -z "$last_checked" ] && return 0
  now=$(date +%s)
  [ $((now - last_checked)) -ge "$cooldown" ]
}

# --- section 3: discover the highest matching tag, no `git` required -------
autoupdate_discover_latest() {
  # args: $1=owner $2=repo $3=lang $4=script_name -> prints highest "X.Y.Z" or nothing
  local owner="$1" repo="$2" lang="$3" name="$4"
  local prefix="${lang}/${name}/v"
  local json
  json=$(curl -fsS --max-time "${UPDATE_TIMEOUT:-10}" \
    "https://api.github.com/repos/${owner}/${repo}/git/matching-refs/tags/${prefix}") || return 1

  # Extract "refs/tags/<lang>/<name>/vX.Y.Z" -> "X.Y.Z" without jq (not
  # every adopting script wants a jq dependency just for this).
  local versions best=""
  versions=$(printf '%s\n' "$json" \
    | sed -n 's/.*"ref": *"refs\/tags\/'"${lang}"'\/'"${name}"'\/v\([0-9][0-9.]*\)".*/\1/p')
  local v
  for v in $versions; do
    if [ -z "$best" ] || autoupdate_version_gt "$v" "$best"; then
      best="$v"
    fi
  done
  [ -n "$best" ] && printf '%s\n' "$best"
}

# --- section 4: numeric major.minor.patch comparison (no `sort -V`; BSD ----
# `sort` lacks it — see cross-platform-shell-compatibility.md) --------------
autoupdate_version_gt() {
  # args: $1 > $2 ?
  local a1 a2 a3 b1 b2 b3 rest
  a1=${1%%.*}; rest=${1#*.}; a2=${rest%%.*}; a3=${rest#*.}
  b1=${2%%.*}; rest=${2#*.}; b2=${rest%%.*}; b3=${rest#*.}
  [ "$a1" -gt "$b1" ] && return 0
  [ "$a1" -lt "$b1" ] && return 1
  [ "$a2" -gt "$b2" ] && return 0
  [ "$a2" -lt "$b2" ] && return 1
  [ "$a3" -gt "$b3" ]
}

# --- section 5: download the candidate + syntax-only validation ------------
autoupdate_download() {
  # args: $1=owner $2=repo $3=lang $4=script_name $5=version -> prints content on stdout
  local owner="$1" repo="$2" lang="$3" name="$4" version="$5"
  curl -fsS --max-time "${UPDATE_TIMEOUT:-10}" \
    "https://raw.githubusercontent.com/${owner}/${repo}/${lang}/${name}/v${version}/platforms/${lang}/${name}/${name}.sh"
}

autoupdate_validate_parse() {
  # args: $1=content -> 0 if it parses as bash, 1 otherwise
  printf '%s\n' "$1" | bash -n - 2>/dev/null
}

# --- section 6: apply — in place (preferred) or memory/temp fallback -------
autoupdate_apply_in_place() {
  # args: $1=script_path $2=new_content -> 0 on success (does not return: re-execs)
  local script_path="$1" new_content="$2" tmp
  tmp=$(mktemp "${script_path}.XXXXXX" 2>/dev/null) || return 1
  printf '%s\n' "$new_content" > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod --reference="$script_path" "$tmp" 2>/dev/null
  if mv -f "$tmp" "$script_path" 2>/dev/null; then
    # Re-exec so this same invocation also runs the new version, per
    # section 6 — otherwise only the *next* invocation would pick it up.
    exec "$script_path" "$@"
  fi
  rm -f "$tmp"
  return 1
}

autoupdate_run_from_memory() {
  # args: $1=new_content, remaining args are the script's original argv.
  # No temp file is created — content is handed to a child bash directly.
  local new_content="$1"; shift
  bash -c "$new_content" -- "$@"
  exit $?
}

# --- section 8: startup banner note ----------------------------------------
autoupdate_banner_note() {
  # args: $1=outcome  $2=detail
  case "$1" in
    check_failed)     printf ' (update check failed: %s)' "$2" ;;
    updated_in_place)  printf ' (updated in place from v%s)' "$2" ;;
    ran_from_memory)  printf ' (fetched v%s, running from memory this run only — could not update in place: %s)' "$2" "$3" ;;
    parse_failed)     printf ' (fetched v%s failed to parse — running v%s)' "$2" "$3" ;;
    *) ;;
  esac
}

# --- orchestration sketch (section 1-10, tie the pieces together) ----------
# autoupdate_main() {
#   local no_autoupdate=0 force=0
#   # ...parse --no-autoupdate / --force-update-check out of "$@" first...
#   local cache_file="${XDG_CACHE_HOME:-$HOME/.cache}/scripts-autoupdate/${SCRIPT_LANG}_${SCRIPT_NAME}.state"
#   if autoupdate_should_check "$no_autoupdate" "$force" "$cache_file"; then
#     local latest
#     if latest=$(autoupdate_discover_latest "$UPDATE_OWNER" "$UPDATE_REPO" "$SCRIPT_LANG" "$SCRIPT_NAME"); then
#       mkdir -p "$(dirname "$cache_file")" 2>/dev/null
#       date +%s > "$cache_file" 2>/dev/null   # best-effort cache write
#       if [ -n "$latest" ] && autoupdate_version_gt "$latest" "$LOCAL_VERSION"; then
#         local content
#         if content=$(autoupdate_download "$UPDATE_OWNER" "$UPDATE_REPO" "$SCRIPT_LANG" "$SCRIPT_NAME" "$latest"); then
#           if autoupdate_validate_parse "$content"; then
#             autoupdate_apply_in_place "$SCRIPT_PATH" "$content" "$@" || \
#               autoupdate_run_from_memory "$content" "$@"
#           else
#             BANNER_NOTE=$(autoupdate_banner_note parse_failed "$latest" "$LOCAL_VERSION")
#           fi
#         else
#           BANNER_NOTE=$(autoupdate_banner_note check_failed "download failed")
#         fi
#       fi
#     else
#       BANNER_NOTE=$(autoupdate_banner_note check_failed "could not reach ${UPDATE_HOST}")
#     fi
#   fi
# }
