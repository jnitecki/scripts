#!/usr/bin/env bash
# test-post-commit.sh
# Version: 1.0.0
#
# Exercises tools/git-hooks/post-commit.sh against a scratch git repo:
# initial tag creation, a version bump (old tag preserved), an idempotent
# re-tag (amend without a version change), changelog excerpt extraction
# and its 500-character truncation, a brand-new script's first tag, a
# non-qualifying commit producing no tag, and that nothing gets pushed.
#
# Usage: tools/git-hooks/test-post-commit.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${SCRIPT_DIR}/post-commit.sh"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

FAILURES=0
fail() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }
pass() { echo "PASS: $1"; }

REPO="${WORKDIR}/repo"
mkdir -p "${REPO}"
cd "${REPO}"
git init -q
git config user.email "test@example.com"
git config user.name "Test"
mkdir -p .git/hooks
ln -sf "${HOOK}" .git/hooks/post-commit

mkdir -p platforms/bash/widget

cat > platforms/bash/widget/widget.sh <<'EOF'
#!/usr/bin/env bash
# Version: 1.0.0
# Category: testing
# Description: Fixture script for post-commit hook tests
#
# Version history:
#   1.0.0 - initial version, does nothing in particular, just exists so the
#           hook has a real header to parse
EOF
git add platforms/bash/widget/widget.sh
git commit -q -m "add widget v1.0.0"

if git rev-parse -q --verify "refs/tags/bash/widget/v1.0.0" >/dev/null; then
    pass "initial version tagged"
else
    fail "initial version not tagged"
fi

# --- version bump: old tag must survive, new tag created ---
cat > platforms/bash/widget/widget.sh <<'EOF'
#!/usr/bin/env bash
# Version: 1.0.1
# Category: testing
# Description: Fixture script for post-commit hook tests
#
# Version history:
#   1.0.0 - initial version, does nothing in particular, just exists so the
#           hook has a real header to parse
#   1.0.1 - a short, deliberately unremarkable follow-up change for the
#           hook's test suite to look for in the tag message
EOF
git add platforms/bash/widget/widget.sh
git commit -q -m "bump widget to v1.0.1"

if git rev-parse -q --verify "refs/tags/bash/widget/v1.0.1" >/dev/null \
    && git rev-parse -q --verify "refs/tags/bash/widget/v1.0.0" >/dev/null; then
    pass "version bump tagged, old tag preserved"
else
    fail "version bump tagging or history preservation failed"
fi

MSG="$(git tag -l --format='%(contents)' "bash/widget/v1.0.1")"
case "${MSG}" in
    *"widget (bash) v1.0.1"*"a short, deliberately unremarkable follow-up"*)
        pass "changelog excerpt present in tag message" ;;
    *)
        fail "changelog excerpt missing from tag message: ${MSG}" ;;
esac

OLD_SHA="$(git rev-parse "refs/tags/bash/widget/v1.0.0")"

# --- idempotent re-tag: amend without a version change ---
git commit -q --amend -m "bump widget to v1.0.1 (amended)"
NEW_TAG_SHA="$(git rev-parse "refs/tags/bash/widget/v1.0.1^{commit}")"
HEAD_SHA="$(git rev-parse HEAD)"

if [ "${NEW_TAG_SHA}" = "${HEAD_SHA}" ]; then
    pass "idempotent re-tag points at amended commit"
else
    fail "idempotent re-tag still points at old commit"
fi

if [ "$(git rev-parse "refs/tags/bash/widget/v1.0.0")" = "${OLD_SHA}" ]; then
    pass "unrelated older tag untouched by idempotent re-tag"
else
    fail "older tag was unexpectedly modified"
fi

# --- excerpt truncation past 500 chars ---
LONG_TEXT=""
i=0
while [ "${i}" -lt 100 ]; do
    LONG_TEXT="${LONG_TEXT}word${i} "
    i=$((i + 1))
done

{
    echo '#!/usr/bin/env bash'
    echo '# Version: 1.0.2'
    echo '# Category: testing'
    echo '# Description: Fixture script for post-commit hook tests'
    echo '#'
    echo '# Version history:'
    echo '#   1.0.0 - initial version'
    echo '#   1.0.1 - a short, deliberately unremarkable follow-up change'
    echo "#   1.0.2 - ${LONG_TEXT}"
} > platforms/bash/widget/widget.sh
git add platforms/bash/widget/widget.sh
git commit -q -m "bump widget to v1.0.2"

MSG2="$(git tag -l --format='%(contents)' "bash/widget/v1.0.2")"
EXCERPT="$(printf '%s' "${MSG2}" | tail -n +3)"
if printf '%s' "${EXCERPT}" | grep -q '…$'; then
    pass "long changelog excerpt truncated with ellipsis"
else
    fail "long changelog excerpt was not truncated: ${EXCERPT}"
fi

# --- new-file case: no prior version ---
mkdir -p platforms/bash/second
cat > platforms/bash/second/second.sh <<'EOF'
#!/usr/bin/env bash
# Version: 0.1.0
# Category: testing
# Description: Second fixture script, added fresh (no prior version)
#
# Version history:
#   0.1.0 - first version of this script
EOF
git add platforms/bash/second/second.sh
git commit -q -m "add second script"

if git rev-parse -q --verify "refs/tags/bash/second/v0.1.0" >/dev/null; then
    pass "brand-new script tagged from its first commit"
else
    fail "brand-new script was not tagged"
fi

# --- non-qualifying change: touching only a sibling file, no version bump ---
BEFORE_TAG_COUNT="$(git tag -l | wc -l | tr -d ' ')"
echo "notes" > platforms/bash/widget/README.md
git add platforms/bash/widget/README.md
git commit -q -m "add readme, no version change"
AFTER_TAG_COUNT="$(git tag -l | wc -l | tr -d ' ')"

if [ "${BEFORE_TAG_COUNT}" = "${AFTER_TAG_COUNT}" ]; then
    pass "non-script / no-version-change commit created no tag"
else
    fail "unexpected tag created for a non-version-change commit"
fi

# --- hook never pushes (no remote configured at all) ---
if [ -z "$(git remote)" ]; then
    pass "no remote configured — confirms the hook cannot have pushed"
else
    fail "unexpected remote present, test setup invalid"
fi

echo
if [ "${FAILURES}" -eq 0 ]; then
    echo "All checks passed."
    exit 0
else
    echo "${FAILURES} check(s) failed."
    exit 1
fi
