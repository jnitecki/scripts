#!/usr/bin/env bash
# generate-catalog.sh
# Version: 2.2.0
#
# Scans platforms/<lang>/<script-name>/ for script files, reads their header
# metadata (# Version / # Category / # Description comment lines), and
# regenerates:
#   - CATALOG.md at the repo root: a stable, flat, no-version, no-link index
#     (Name / Description / Categories / Platforms), one row per logical
#     script. Platform variants of the same script (e.g. the same folder
#     name under both platforms/bash/ and platforms/powershell/) are merged
#     into a single row.
#   - One <CATEGORY>.md file per category in use (e.g. CONTAINERS.md),
#     listing full detail per script: every category it belongs to, and one
#     line per platform with that platform's own version and a link to its
#     implementation. UNCATEGORIZED.md covers scripts with no Category
#     header. Category files with no remaining scripts are deleted.
#
# Categories are free text (no fixed vocabulary) — see
# docs/requirements/generic/script-header-convention.md. A script may list
# more than one, comma-separated on its Category: line.
#
# Pre-release version guard: if a script's freshly-scanned header version
# carries a -dev/-alpha/-beta/-rc suffix, it does not automatically overwrite
# the version already recorded for that script+platform in the existing
# committed category file, to keep in-progress/pre-release version bumps
# from clobbering the published catalog. See "Pre-release version guard"
# below for the exact precedence rule.
#
# Category values are validated against ^[a-z0-9]+(-[a-z0-9]+)*$ (lowercase,
# hyphen-separated) — see docs/requirements/generic/script-header-convention.md.
# An invalid value aborts the run before anything is written, since it's
# exactly what would let two differently-spelled categories collide onto
# the same category filename.
#
# Usage:
#   tools/generate-catalog.sh [--check] [--source=worktree|index]
#
#   --check          Don't write any files. Exit non-zero if regenerating
#                     would change CATALOG.md, any category file's content,
#                     or the set of category files that should exist
#                     (useful as a CI / pre-commit gate).
#   --source=index    Scan the git index (what's staged) instead of the
#                     working tree — enumerate via `git ls-files --cached`
#                     and read content via `git show :<path>`. Used by
#                     tools/git-hooks/pre-commit.sh so the catalog reflects
#                     exactly what's about to be committed, not whatever
#                     else happens to be sitting on disk. Default is
#                     `--source=worktree` (today's disk-scanning behavior).

if [ -z "${BASH_VERSION:-}" ]; then
    echo "ERROR: this script requires bash. Run it as './generate-catalog.sh' or 'bash generate-catalog.sh', not 'sh generate-catalog.sh'." >&2
    exit 1
fi

set -euo pipefail

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PLATFORMS_DIR="${REPO_ROOT}/platforms"
CATALOG_FILE="${REPO_ROOT}/CATALOG.md"

CHECK_MODE=0
SOURCE_MODE="worktree"
for arg in "$@"; do
    case "${arg}" in
        --check) CHECK_MODE=1 ;;
        --source=worktree) SOURCE_MODE="worktree" ;;
        --source=index) SOURCE_MODE="index" ;;
        *)
            echo "ERROR: unknown argument '${arg}'" >&2
            echo "Usage: tools/generate-catalog.sh [--check] [--source=worktree|index]" >&2
            exit 1
            ;;
    esac
done

if [[ "${SOURCE_MODE}" == "index" ]] && ! git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "ERROR: --source=index requires running inside a git repository" >&2
    exit 1
fi

# Extensions we know how to scan, mapped to a display label.
# (Deliberately not an associative array — those require bash 4+, and
# several homelab/macOS boxes still ship bash 3.2 as /bin/bash. Same reason
# we avoid ${var,,}/${var^^} case conversion below and use tr instead.)
SCAN_EXTENSIONS="sh ps1 pl"

label_for_ext() {
    case "$1" in
        sh)  echo "bash" ;;
        ps1) echo "powershell" ;;
        pl)  echo "perl" ;;
        *)   echo "" ;;
    esac
}

if [[ ! -d "${PLATFORMS_DIR}" ]]; then
    echo "ERROR: platforms directory not found at ${PLATFORMS_DIR}" >&2
    exit 1
fi

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

category_to_filename() {
    printf '%s.md' "$(upper "$1" | tr ' ' '-')"
}

title_first() {
    local s="$1"
    printf '%s%s' "$(upper "${s:0:1}")" "${s:1}"
}

# ---------------------------------------------------------------------------
# Metadata extraction
# ---------------------------------------------------------------------------
# Reads the first N lines of a script and pulls out:
#   # Version: X
#   # Category: X[, X...]
#   # Description: X
# All three languages we support (bash, powershell, perl) use '#' as a
# line-comment marker, so one regex set covers all of them.

HEADER_SCAN_LINES=20
CATEGORY_RE='^[a-z0-9]+(-[a-z0-9]+)*$'

# $1 = path relative to REPO_ROOT. Prints its first HEADER_SCAN_LINES lines,
# read from the working tree or the git index per SOURCE_MODE.
read_header_lines() {
    local relpath="$1"
    if [[ "${SOURCE_MODE}" == "index" ]]; then
        git -C "${REPO_ROOT}" show ":${relpath}" 2>/dev/null | head -n "${HEADER_SCAN_LINES}"
    else
        head -n "${HEADER_SCAN_LINES}" "${REPO_ROOT}/${relpath}"
    fi
}

extract_field() {
    local relpath="$1" field="$2"
    read_header_lines "${relpath}" \
        | grep -m1 -E "^[[:space:]]*#[[:space:]]*${field}:[[:space:]]*" \
        | sed -E "s/^[[:space:]]*#[[:space:]]*${field}:[[:space:]]*//" \
        || true
}

# ---------------------------------------------------------------------------
# Walk platforms/<lang>/<script-name>/<script-file>
# ---------------------------------------------------------------------------
# ROWS_FILE: one row per scanned file (a single platform implementation).
#   key<TAB>platform<TAB>version<TAB>categories<TAB>description<TAB>relpath
# "key" is the leaf folder name — platform variants of the same logical
# script share a folder name under different platforms/<lang>/ trees, and
# are merged by that key downstream.
# "categories" is the trimmed, ", "-joined list from the header (or the
# single fallback value "uncategorized").
#
# CATSPLIT_FILE: key<TAB>category, one row per (script, category) pair,
# expanded from ROWS_FILE and de-duplicated — used both to find every
# category a script belongs to, and every script in a given category.

# Enumerates platforms/**/* relative to REPO_ROOT, NUL-separated — from the
# working tree or the git index per SOURCE_MODE. Extension filtering happens
# per-item in the loop below (both modes may yield non-script files).
list_relpaths() {
    if [[ "${SOURCE_MODE}" == "index" ]]; then
        git -C "${REPO_ROOT}" ls-files --cached -z -- 'platforms'
    else
        find "${PLATFORMS_DIR}" -type f \( -false \
            $(for e in ${SCAN_EXTENSIONS}; do printf -- '-o -name *.%s ' "$e"; done) \
        \) -print0 | while IFS= read -r -d '' f; do printf '%s\0' "${f#"${REPO_ROOT}"/}"; done
    fi
}

ROWS_FILE="$(mktemp)"
CATSPLIT_FILE="$(mktemp)"
trap 'rm -f "${ROWS_FILE}" "${CATSPLIT_FILE}"' EXIT

WARNINGS=0
INVALID_CATEGORY=0

while IFS= read -r -d '' relpath; do
    ext="${relpath##*.}"
    label="$(label_for_ext "${ext}")"
    [[ -z "${label}" ]] && continue

    key="$(basename "$(dirname "${relpath}")")"

    version="$(extract_field "${relpath}" "Version")"
    category_raw="$(extract_field "${relpath}" "Category")"
    description="$(extract_field "${relpath}" "Description")"

    if [[ -z "${category_raw}" ]]; then
        echo "WARNING: ${relpath} has no '# Category:' header — filing under uncategorized" >&2
        category_raw="uncategorized"
        WARNINGS=$((WARNINGS + 1))
    fi
    if [[ -z "${version}" ]]; then
        echo "WARNING: ${relpath} has no '# Version:' header" >&2
        version="?"
        WARNINGS=$((WARNINGS + 1))
    fi
    if [[ -z "${description}" ]]; then
        echo "WARNING: ${relpath} has no '# Description:' header" >&2
        description="(no description)"
        WARNINGS=$((WARNINGS + 1))
    fi

    # Normalize the category list: split on comma, trim each token, drop
    # empties, re-join with ", " so downstream comparisons are consistent
    # regardless of the spacing the script author used.
    categories_joined=""
    IFS=',' read -ra _cat_tokens <<< "${category_raw}"
    for tok in "${_cat_tokens[@]}"; do
        tok="$(trim "${tok}")"
        [[ -z "${tok}" ]] && continue
        if [[ ! "${tok}" =~ ${CATEGORY_RE} ]]; then
            echo "ERROR: ${relpath} has invalid Category value '${tok}' — must be lowercase letters/digits, hyphen-separated (e.g. 'web-scraping')." >&2
            INVALID_CATEGORY=1
        fi
        printf '%s\t%s\n' "${key}" "${tok}" >> "${CATSPLIT_FILE}"
        categories_joined="${categories_joined:+${categories_joined}, }${tok}"
    done

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${key}" "${label}" "${version}" "${categories_joined}" "${description}" "${relpath}" \
        >> "${ROWS_FILE}"
done < <(list_relpaths)

if [[ "${INVALID_CATEGORY}" -eq 1 ]]; then
    echo "ERROR: invalid Category value(s) found — no files were written." >&2
    exit 1
fi

if [[ ! -s "${ROWS_FILE}" ]]; then
    echo "ERROR: no scripts found under ${PLATFORMS_DIR}" >&2
    exit 1
fi

sort -u -o "${CATSPLIT_FILE}" "${CATSPLIT_FILE}"

KEYS="$(cut -f1 "${ROWS_FILE}" | sort -u)"

key_description() {
    awk -F'\t' -v k="$1" '$1==k' "${ROWS_FILE}" | sort -t$'\t' -k2,2 | head -1 | cut -f5
}

key_platforms_joined() {
    awk -F'\t' -v k="$1" '$1==k{print $2}' "${ROWS_FILE}" | sort -u | paste -sd, - | sed 's/,/, /g'
}

key_categories_joined() {
    awk -F'\t' -v k="$1" '$1==k{print $2}' "${CATSPLIT_FILE}" | sort -u | paste -sd, - | sed 's/,/, /g'
}

# Description mismatches across platform variants of the same script are
# unexpected (the same logical script should describe itself the same way
# everywhere) — warn rather than silently picking one.
while IFS= read -r key; do
    distinct_count="$(awk -F'\t' -v k="${key}" '$1==k{print $5}' "${ROWS_FILE}" | sort -u | wc -l | tr -d ' ')"
    if [[ "${distinct_count}" -gt 1 ]]; then
        echo "WARNING: ${key} has differing descriptions across platform variants — using $(key_description "${key}")" >&2
        WARNINGS=$((WARNINGS + 1))
    fi
done <<< "${KEYS}"

# ---------------------------------------------------------------------------
# Category → filename mapping, with collision detection
# ---------------------------------------------------------------------------
# Categories are free text, so two distinct category values could uppercase/
# hyphenate to the same filename. Detect that before writing anything.

CATFILE_MAP="$(mktemp)"
trap 'rm -f "${ROWS_FILE}" "${CATSPLIT_FILE}" "${CATFILE_MAP}"' EXIT

DISTINCT_CATEGORIES="$(cut -f2 "${CATSPLIT_FILE}" | sort -u)"
while IFS= read -r cat; do
    [[ -z "${cat}" ]] && continue
    printf '%s\t%s\n' "${cat}" "$(category_to_filename "${cat}")" >> "${CATFILE_MAP}"
done <<< "${DISTINCT_CATEGORIES}"

DUPLICATE_FILENAMES="$(cut -f2 "${CATFILE_MAP}" | sort | uniq -d)"
if [[ -n "${DUPLICATE_FILENAMES}" ]]; then
    echo "ERROR: category name collision(s) detected — no files were written:" >&2
    while IFS= read -r fname; do
        echo "  ${fname} claimed by categories:" >&2
        awk -F'\t' -v f="${fname}" '$2==f{print "    - " $1}' "${CATFILE_MAP}" >&2
    done <<< "${DUPLICATE_FILENAMES}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Pre-release version guard
# ---------------------------------------------------------------------------
# A freshly-scanned version carrying a -dev/-alpha/-beta/-rc suffix does not
# blindly overwrite what's already recorded for that (key, platform) in the
# currently-committed category file. Precedence, lowest to highest:
#   dev < alpha < beta < rc < stable (no suffix)
# - No prior recorded entry -> the scanned version is used as-is, whatever
#   it is (including -dev): there is nothing to protect yet.
# - Scanned version is stable (no suffix) -> always used, unchanged from
#   this script's original always-mirror-the-source behavior.
# - Scanned version is -dev -> never replaces an existing recorded entry,
#   regardless of that entry's own level. Only the "no prior entry" case
#   above lets a -dev version appear in the catalog.
# - Scanned version is -alpha/-beta/-rc -> replaces the recorded entry only
#   if the recorded entry's level is lower (progressing to a higher level
#   always wins), or the same level with a strictly higher X.Y.Z (e.g. an
#   existing -alpha can be replaced by a higher -alpha, but not an equal or
#   lower one). A higher-level recorded entry (e.g. stable, or -rc versus a
#   -alpha candidate) is never regressed.

version_level() {
    case "$1" in
        *-dev*)   echo 0 ;;
        *-alpha*) echo 1 ;;
        *-beta*)  echo 2 ;;
        *-rc*)    echo 3 ;;
        *)        echo 4 ;;
    esac
}

version_base() { printf '%s' "${1%%-*}"; }

# True (exit 0) if X.Y.Z of $1 is numerically greater than X.Y.Z of $2.
# Deliberately not `sort -V` (a GNU coreutils extension absent from macOS's
# BSD sort — see docs/requirements/generic/cross-platform-shell-compatibility.md).
version_num_gt() {
    local a b a1 a2 a3 b1 b2 b3 rest
    a="$(version_base "$1")"; b="$(version_base "$2")"
    a1=${a%%.*}; rest=${a#*.}; a2=${rest%%.*}; a3=${rest#*.}
    b1=${b%%.*}; rest=${b#*.}; b2=${rest%%.*}; b3=${rest#*.}
    [[ "${a1}" =~ ^[0-9]+$ ]] || a1=0
    [[ "${a2}" =~ ^[0-9]+$ ]] || a2=0
    [[ "${a3}" =~ ^[0-9]+$ ]] || a3=0
    [[ "${b1}" =~ ^[0-9]+$ ]] || b1=0
    [[ "${b2}" =~ ^[0-9]+$ ]] || b2=0
    [[ "${b3}" =~ ^[0-9]+$ ]] || b3=0
    [[ "${a1}" -gt "${b1}" ]] && return 0
    [[ "${a1}" -lt "${b1}" ]] && return 1
    [[ "${a2}" -gt "${b2}" ]] && return 0
    [[ "${a2}" -lt "${b2}" ]] && return 1
    [[ "${a3}" -gt "${b3}" ]]
}

# Scan the category files this repo's CATALOG.md currently claims to own
# (before anything is overwritten) for their recorded "- **platform**
# (vX.Y.Z)" lines, keyed by the "### key" heading each falls under.
OLD_MANIFEST=""
if [[ -f "${CATALOG_FILE}" ]]; then
    OLD_MANIFEST="$(grep -m1 '^<!-- CATEGORY-FILES:' "${CATALOG_FILE}" | sed -E 's/^<!-- CATEGORY-FILES: (.*) -->/\1/' || true)"
fi

OLD_VERSION_FILE="$(mktemp)"
trap 'rm -f "${ROWS_FILE}" "${CATSPLIT_FILE}" "${CATFILE_MAP}" "${OLD_VERSION_FILE}"' EXIT

for old_fname in ${OLD_MANIFEST}; do
    old_path="${REPO_ROOT}/${old_fname}"
    [[ -f "${old_path}" ]] || continue
    current_key=""
    while IFS= read -r line; do
        if [[ "${line}" =~ ^###\ (.+)$ ]]; then
            current_key="${BASH_REMATCH[1]}"
        elif [[ -n "${current_key}" && "${line}" =~ ^-\ \*\*([A-Za-z0-9]+)\*\*\ \(v([^\)]+)\) ]]; then
            printf '%s\t%s\t%s\n' "${current_key}" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" >> "${OLD_VERSION_FILE}"
        fi
    done < "${old_path}"
done

# Final version to display for a (key, platform), applying the guard above.
resolve_version() {
    local key="$1" platform="$2" candidate="$3" old clevel olevel
    old="$(awk -F'\t' -v k="${key}" -v p="${platform}" '$1==k && $2==p {print $3; exit}' "${OLD_VERSION_FILE}")"
    if [[ -z "${old}" ]]; then
        printf '%s' "${candidate}"
        return
    fi
    clevel="$(version_level "${candidate}")"
    if [[ "${clevel}" -eq 4 ]]; then
        printf '%s' "${candidate}"
        return
    fi
    if [[ "${clevel}" -eq 0 ]]; then
        printf '%s' "${old}"
        return
    fi
    olevel="$(version_level "${old}")"
    if [[ "${olevel}" -lt "${clevel}" ]]; then
        printf '%s' "${candidate}"
    elif [[ "${olevel}" -eq "${clevel}" ]] && version_num_gt "${candidate}" "${old}"; then
        printf '%s' "${candidate}"
    else
        printf '%s' "${old}"
    fi
}

# ---------------------------------------------------------------------------
# Render CATALOG.md
# ---------------------------------------------------------------------------

render_catalog() {
    local category_files_manifest="$1"
    echo "<!-- AUTO-GENERATED by tools/generate-catalog.sh — do not edit by hand -->"
    echo "<!-- CATEGORY-FILES: ${category_files_manifest} -->"
    echo "# Script Catalog"
    echo
    echo "_Generated $(date -u '+%Y-%m-%d %H:%M UTC'). Regenerate with \`tools/generate-catalog.sh\`._"
    echo
    echo "| Name | Description | Categories | Platforms |"
    echo "|---|---|---|---|"
    while IFS= read -r key; do
        printf '| %s | %s | %s | %s |\n' \
            "${key}" "$(key_description "${key}")" "$(key_categories_joined "${key}")" "$(key_platforms_joined "${key}")"
    done <<< "${KEYS}"
}

# ---------------------------------------------------------------------------
# Render one <CATEGORY>.md
# ---------------------------------------------------------------------------

render_category_file() {
    local category="$1"
    echo "<!-- AUTO-GENERATED by tools/generate-catalog.sh — do not edit by hand -->"
    echo "# $(title_first "${category}")"
    echo
    echo "_Generated $(date -u '+%Y-%m-%d %H:%M UTC'). Regenerate with \`tools/generate-catalog.sh\`._"
    echo

    local keys_in_category
    keys_in_category="$(awk -F'\t' -v c="${category}" '$2==c{print $1}' "${CATSPLIT_FILE}" | sort -u)"

    while IFS= read -r key; do
        echo "### ${key}"
        key_description "${key}"
        echo "Categories: $(key_categories_joined "${key}")"
        awk -F'\t' -v k="${key}" '$1==k' "${ROWS_FILE}" \
            | sort -t$'\t' -k2,2 \
            | while IFS=$'\t' read -r _k platform version _cats _desc relpath; do
                resolved="$(resolve_version "${key}" "${platform}" "${version}")"
                echo "- **${platform}** (v${resolved}) — [$(basename "${relpath}")](${relpath})"
            done
        echo
    done <<< "${keys_in_category}"
}

# ---------------------------------------------------------------------------
# Build the new file set in memory before writing/checking anything
# ---------------------------------------------------------------------------

NEW_CATEGORY_FILENAMES="$(cut -f2 "${CATFILE_MAP}" | sort -u)"
CATEGORY_FILES_MANIFEST="$(echo "${NEW_CATEGORY_FILENAMES}" | tr '\n' ' ' | sed -e 's/^ *//' -e 's/ *$//')"

NEW_CATALOG_CONTENT="$(render_catalog "${CATEGORY_FILES_MANIFEST}")"

# ---------------------------------------------------------------------------
# --check: validate CATALOG.md, every category file's content, and that the
# set of category files on disk matches the target set exactly (no missing,
# no orphaned).
# ---------------------------------------------------------------------------

strip_timestamp() { grep -v '^_Generated ' "$@" 2>/dev/null || true; }

if [[ "${CHECK_MODE}" -eq 1 ]]; then
    STALE=0

    if [[ ! -f "${CATALOG_FILE}" ]] \
        || ! diff -q <(strip_timestamp <(echo "${NEW_CATALOG_CONTENT}")) <(strip_timestamp "${CATALOG_FILE}") >/dev/null 2>&1; then
        echo "STALE: CATALOG.md is missing or out of date." >&2
        STALE=1
    fi

    while IFS= read -r cat; do
        [[ -z "${cat}" ]] && continue
        fname="$(category_to_filename "${cat}")"
        target="${REPO_ROOT}/${fname}"
        if [[ ! -f "${target}" ]] \
            || ! diff -q <(strip_timestamp <(render_category_file "${cat}")) <(strip_timestamp "${target}") >/dev/null 2>&1; then
            echo "STALE: ${fname} is missing or out of date." >&2
            STALE=1
        fi
    done <<< "${DISTINCT_CATEGORIES}"

    for old_fname in ${OLD_MANIFEST}; do
        if ! grep -qxF "${old_fname}" <<< "${NEW_CATEGORY_FILENAMES}"; then
            echo "STALE: ${old_fname} exists but should be removed (no scripts left in that category)." >&2
            STALE=1
        fi
    done

    if [[ "${STALE}" -eq 0 ]]; then
        echo "Catalog is up to date."
        exit 0
    else
        echo "Catalog is stale. Run tools/generate-catalog.sh to regenerate." >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Write CATALOG.md, write each category file, remove orphaned category files
# ---------------------------------------------------------------------------

echo "${NEW_CATALOG_CONTENT}" > "${CATALOG_FILE}"
echo "Wrote ${CATALOG_FILE}"

while IFS= read -r cat; do
    [[ -z "${cat}" ]] && continue
    fname="$(category_to_filename "${cat}")"
    render_category_file "${cat}" > "${REPO_ROOT}/${fname}"
    echo "Wrote ${REPO_ROOT}/${fname}"
done <<< "${DISTINCT_CATEGORIES}"

for old_fname in ${OLD_MANIFEST}; do
    if ! grep -qxF "${old_fname}" <<< "${NEW_CATEGORY_FILENAMES}"; then
        rm -f "${REPO_ROOT}/${old_fname}"
        echo "Removed ${REPO_ROOT}/${old_fname} (no scripts left in that category)"
    fi
done

if [[ "${WARNINGS}" -gt 0 ]]; then
    echo "Completed with ${WARNINGS} metadata warning(s) — see above." >&2
fi
