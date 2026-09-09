#!/usr/bin/env bash
# post-commit.sh
# Version: 1.0.0
#
# Repo-tooling git hook. Installed as .git/hooks/post-commit via a symlink
# (see README.md's "Repository tooling" section); git invokes it after
# every commit, with no arguments.
#
# For every platforms/<lang>/<script-name>/<script-name>.<ext> file whose
# "# Version:" header line changed in this commit (including a brand new
# script file), creates an annotated tag <lang>/<script-name>/v<X.Y.Z> (or
# v<X.Y.Z>-<suffix> for a pre-release version) pointing at the new commit.
# If a tag with that exact name already exists locally (e.g. re-running
# after `git commit --amend` without a version change), it is replaced —
# no other version's tag is ever touched.
#
# The tag's annotation message is a separate field from its (fixed-format)
# name: an identity line plus a best-effort excerpt of that version's entry
# from the script's own "Version history" header block, truncated to 500
# characters.
#
# Never pushes anything, under any condition — see README.md for the
# one-time `git config push.followTags` step that makes a plain `git push`
# carry new tags along automatically. Never fails the commit (it already
# happened) and always exits 0; problems are reported to stderr only.
#
# Design: docs/requirements/implemented/release-tag-hook.md
# Implementation notes: docs/implementation.md

if [ -z "${BASH_VERSION:-}" ]; then
    echo "post-commit hook: requires bash, skipping" >&2
    exit 0
fi

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}" || exit 0

EMPTY_TREE="4b825dc642cb6eb9a060e54bf8d69288fbee4904"
HEADER_SCAN_LINES=20
CHANGELOG_SCAN_LINES=300
EXCERPT_MAX_CHARS=500

if git rev-parse -q --verify HEAD^1 >/dev/null 2>&1; then
    BASE="HEAD^1"
else
    BASE="${EMPTY_TREE}"
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# $1 = git ref (commit-ish), $2 = path (relative to repo root).
# Prints the "# Version:" value, or nothing if the file doesn't exist at
# that ref or has no such header line.
extract_version() {
    local ref="$1" path="$2"
    git cat-file -e "${ref}:${path}" 2>/dev/null || return 0
    git show "${ref}:${path}" 2>/dev/null \
        | head -n "${HEADER_SCAN_LINES}" \
        | grep -m1 -E '^#[[:space:]]*Version:[[:space:]]*' \
        | sed -E 's/^#[[:space:]]*Version:[[:space:]]*//; s/[[:space:]]+$//' \
        || true
}

# $1 = post-commit file content (already scan-line-bounded), $2 = version
# string to find. Prints the excerpt (possibly empty).
extract_changelog_excerpt() {
    local content="$1" version="$2"
    local -a lines
    local line
    while IFS= read -r line; do
        lines+=("${line}")
    done <<<"${content}"

    local escaped_version="${version//./\\.}"
    local entry_re="^#[[:space:]]*${escaped_version}[[:space:]]*-[[:space:]]*(.*)"
    local new_entry_re='^#[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9]+)?[[:space:]]*-'

    local n=${#lines[@]}
    local i=0
    local start=-1
    while [ "${i}" -lt "${n}" ]; do
        if [[ "${lines[$i]}" =~ ${entry_re} ]]; then
            start="${i}"
            break
        fi
        i=$((i + 1))
    done

    [ "${start}" -eq -1 ] && return 0

    local excerpt="${BASH_REMATCH[1]}"
    local body
    i=$((start + 1))
    while [ "${i}" -lt "${n}" ]; do
        line="${lines[$i]}"
        body="${line#\#}"
        while [ "${body:0:1}" = " " ]; do body="${body:1}"; done
        [ -z "${body}" ] && break
        [[ "${line}" =~ ${new_entry_re} ]] && break
        excerpt="${excerpt} ${body}"
        i=$((i + 1))
    done

    excerpt="${excerpt% }"
    if [ "${#excerpt}" -gt "${EXCERPT_MAX_CHARS}" ]; then
        excerpt="${excerpt:0:${EXCERPT_MAX_CHARS}}…"
    fi
    printf '%s' "${excerpt}"
}

# $1 = path changed in this commit, relative to repo root.
tag_script() {
    local path="$1"

    case "${path}" in
        platforms/*/*/*) ;;
        *) return 0 ;;
    esac

    local rest="${path#platforms/}"
    local lang="${rest%%/*}"
    local rest2="${rest#*/}"
    local script_name="${rest2%%/*}"
    local filename="${rest2#*/}"

    case "${filename}" in
        */*) return 0 ;;
    esac

    local stem="${filename%.*}"
    [ "${stem}" = "${script_name}" ] || return 0

    local post_version pre_version
    post_version="$(extract_version "HEAD" "${path}")"
    [ -z "${post_version}" ] && return 0

    pre_version="$(extract_version "${BASE}" "${path}")"
    [ "${post_version}" = "${pre_version}" ] && return 0

    local tag_name="${lang}/${script_name}/v${post_version}"
    local content excerpt message
    content="$(git show "HEAD:${path}" 2>/dev/null | head -n "${CHANGELOG_SCAN_LINES}")"
    excerpt="$(extract_changelog_excerpt "${content}" "${post_version}")"

    message="${script_name} (${lang}) v${post_version}"
    if [ -n "${excerpt}" ]; then
        message="${message}"$'\n\n'"${excerpt}"
    fi

    if git rev-parse -q --verify "refs/tags/${tag_name}" >/dev/null 2>&1; then
        git tag -d "${tag_name}" >/dev/null 2>&1
    fi

    if git tag -a "${tag_name}" -m "${message}" HEAD >/dev/null 2>&1; then
        echo "post-commit: tagged ${tag_name}" >&2
    else
        echo "post-commit: WARNING: failed to create tag ${tag_name}" >&2
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

while IFS= read -r changed_path; do
    [ -z "${changed_path}" ] && continue
    tag_script "${changed_path}"
done < <(git diff --name-only "${BASE}" HEAD -- 'platforms/' 2>/dev/null)

exit 0
