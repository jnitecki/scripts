#!/usr/bin/env bash
# pre-commit.sh
# Version: 1.0.0
#
# Repo-tooling git hook. Installed as .git/hooks/pre-commit via a symlink
# (see README.md's "Repository tooling" section); git invokes it before a
# commit is created, with no arguments.
#
# If the staged change set touches anything under platforms/, CATALOG.md,
# or any per-category file CATALOG.md currently lists in its
# "<!-- CATEGORY-FILES: ... -->" manifest, regenerates the catalog via
# `tools/generate-catalog.sh --source=index` (reading the git index, not
# the working tree, so partially-staged or unstaged edits never leak into
# the catalog) and stages the result so it lands in the same commit.
#
# If the generator fails (a category-filename collision, or an invalid
# Category: header value), the commit is aborted — see
# docs/requirements/implemented/catalog-precommit-hook.md section 5 for why
# this fails closed rather than warning and committing anyway.
#
# Design: docs/requirements/implemented/catalog-precommit-hook.md
# Implementation notes: docs/implementation.md

if [ -z "${BASH_VERSION:-}" ]; then
    echo "pre-commit hook: requires bash, skipping" >&2
    exit 0
fi

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}" || exit 1

# $1 = "<!-- CATEGORY-FILES: ... -->" line's manifest contents (space-
# separated filenames, may be empty). Reads CATALOG.md's current manifest.
current_manifest() {
    [ -f CATALOG.md ] || return 0
    grep -m1 '^<!-- CATEGORY-FILES:' CATALOG.md | sed -E 's/^<!-- CATEGORY-FILES: (.*) -->/\1/'
}

OLD_MANIFEST="$(current_manifest)"

# ---------------------------------------------------------------------------
# Trigger condition: only run for a commit that touches platforms/,
# CATALOG.md, or a currently-tracked category file.
# ---------------------------------------------------------------------------

TRIGGER=0
while IFS= read -r staged_path; do
    [ -z "${staged_path}" ] && continue
    case "${staged_path}" in
        platforms/*) TRIGGER=1; break ;;
        CATALOG.md) TRIGGER=1; break ;;
    esac
    for manifest_file in ${OLD_MANIFEST}; do
        if [ "${staged_path}" = "${manifest_file}" ]; then
            TRIGGER=1
            break 2
        fi
    done
done < <(git diff --cached --name-only)

[ "${TRIGGER}" -eq 0 ] && exit 0

# ---------------------------------------------------------------------------
# Regenerate from the index, stage the result
# ---------------------------------------------------------------------------

if ! "${REPO_ROOT}/tools/generate-catalog.sh" --source=index; then
    echo "pre-commit: catalog generation failed — commit aborted (see above)." >&2
    exit 1
fi

NEW_MANIFEST="$(current_manifest)"

git add -- CATALOG.md

for new_file in ${NEW_MANIFEST}; do
    [ -f "${new_file}" ] && git add -- "${new_file}"
done

for old_file in ${OLD_MANIFEST}; do
    case " ${NEW_MANIFEST} " in
        *" ${old_file} "*) ;;
        *) git rm -q --cached --ignore-unmatch -- "${old_file}" >/dev/null 2>&1 ;;
    esac
done

exit 0
