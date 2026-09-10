#!/usr/bin/env bash
# test-pre-commit.sh
# Version: 1.0.0
#
# Exercises tools/git-hooks/pre-commit.sh against a scratch git repo: catalog
# regeneration on a script-adding commit (staged atomically), no regen for a
# commit that doesn't touch platforms/ or the catalog, correction of a
# hand-edited CATALOG.md, orphaned category-file removal being staged, a
# category-filename collision aborting the commit, and an invalid Category:
# value aborting the commit.
#
# Usage: tools/git-hooks/test-pre-commit.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${SCRIPT_DIR}/pre-commit.sh"
GENERATOR="${SCRIPT_DIR}/../generate-catalog.sh"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

FAILURES=0
fail() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }
pass() { echo "PASS: $1"; }

REPO="${WORKDIR}/repo"
mkdir -p "${REPO}/tools"
cp "${GENERATOR}" "${REPO}/tools/generate-catalog.sh"
chmod +x "${REPO}/tools/generate-catalog.sh"
cd "${REPO}"
git init -q
git config user.email "test@example.com"
git config user.name "Test"
mkdir -p .git/hooks
ln -sf "${HOOK}" .git/hooks/pre-commit

# tools/ itself is committed up front (untracked in a real checkout too,
# it would just already be part of history) so later "working tree clean"
# assertions aren't tripped up by this test's own fixture copy.
git add tools/generate-catalog.sh
git commit -q -m "seed generator fixture"

# --- adding a script stages a freshly generated catalog in the same commit ---
mkdir -p platforms/bash/widget
cat > platforms/bash/widget/widget.sh <<'EOF'
#!/usr/bin/env bash
# Version: 1.0.0
# Category: testing
# Description: Fixture script for pre-commit hook tests
EOF
git add platforms/bash/widget/widget.sh
git commit -q -m "add widget v1.0.0"

if [ -f CATALOG.md ] && [ -f TESTING.md ]; then
    pass "catalog files created"
else
    fail "catalog files not created"
fi

if git show --stat HEAD | grep -q "CATALOG.md" && git show --stat HEAD | grep -q "TESTING.md"; then
    pass "catalog files staged into the same commit as the script"
else
    fail "catalog files not part of the triggering commit"
fi

if git status --porcelain | grep -q .; then
    fail "working tree not clean after commit (unstaged catalog drift)"
else
    pass "working tree clean after commit"
fi

# --- a commit that doesn't touch platforms/ or the catalog: no regen ---
CATALOG_BEFORE="$(cat CATALOG.md)"
echo "# notes" > NOTES.md
git add NOTES.md
git commit -q -m "add unrelated notes file"
CATALOG_AFTER="$(cat CATALOG.md)"

if [ "${CATALOG_BEFORE}" = "${CATALOG_AFTER}" ] && ! git show --stat HEAD | grep -q "CATALOG.md"; then
    pass "non-triggering commit left the catalog untouched"
else
    fail "catalog was regenerated for a commit that didn't touch platforms/ or CATALOG.md"
fi

# --- hand-edited CATALOG.md gets corrected and staged even with no platforms/ change ---
echo "garbage" >> CATALOG.md
git add CATALOG.md
git commit -q -m "corrupt catalog on purpose"

if grep -q "AUTO-GENERATED" CATALOG.md && ! grep -q "garbage" CATALOG.md; then
    pass "hand-edited CATALOG.md was regenerated and corrected"
else
    fail "hand-edited CATALOG.md was not corrected"
fi

# --- orphaned category file: removing the last script in a category stages its removal ---
mkdir -p platforms/bash/other
cat > platforms/bash/other/other.sh <<'EOF'
#!/usr/bin/env bash
# Version: 1.0.0
# Category: temp-category
# Description: Fixture script whose category will be orphaned
EOF
git add platforms/bash/other/other.sh
git commit -q -m "add other script with its own category"

if [ -f TEMP-CATEGORY.md ]; then
    pass "new category file created"
else
    fail "new category file was not created"
fi

git rm -q -r platforms/bash/other
git commit -q -m "remove other script, orphaning its category"

if [ ! -f TEMP-CATEGORY.md ] && ! git ls-files | grep -q "^TEMP-CATEGORY.md$"; then
    pass "orphaned category file removed from disk and unstaged from the index"
else
    fail "orphaned category file still present on disk or still tracked"
fi

# --- category-filename collision aborts the commit ---
mkdir -p platforms/bash/collide-a platforms/bash/collide-b
cat > platforms/bash/collide-a/collide-a.sh <<'EOF'
#!/usr/bin/env bash
# Version: 1.0.0
# Category: shared-thing
# Description: First half of a deliberate category collision
EOF
git add platforms/bash/collide-a/collide-a.sh
git commit -q -m "add collide-a"

cat > platforms/bash/collide-b/collide-b.sh <<'EOF'
#!/usr/bin/env bash
# Version: 1.0.0
# Category: Shared-Thing
# Description: Second half of a deliberate category collision
EOF
git add platforms/bash/collide-b/collide-b.sh
BEFORE_HEAD="$(git rev-parse HEAD)"
if git commit -q -m "add collide-b, should collide with collide-a" 2>/tmp/pre-commit-collide.err; then
    fail "commit with a category collision was not aborted"
else
    if [ "$(git rev-parse HEAD)" = "${BEFORE_HEAD}" ]; then
        pass "category collision aborted the commit"
    else
        fail "commit was created despite the collision"
    fi
fi
git reset -q --hard "${BEFORE_HEAD}"

# --- invalid Category: value aborts the commit ---
mkdir -p platforms/bash/badcat
cat > platforms/bash/badcat/badcat.sh <<'EOF'
#!/usr/bin/env bash
# Version: 1.0.0
# Category: Not Valid
# Description: Fixture script with an invalid Category value
EOF
git add platforms/bash/badcat/badcat.sh
BEFORE_HEAD2="$(git rev-parse HEAD)"
if git commit -q -m "add badcat, invalid category format" 2>/tmp/pre-commit-badcat.err; then
    fail "commit with an invalid Category: value was not aborted"
else
    if [ "$(git rev-parse HEAD)" = "${BEFORE_HEAD2}" ]; then
        pass "invalid Category: value aborted the commit"
    else
        fail "commit was created despite the invalid Category: value"
    fi
fi

echo
if [ "${FAILURES}" -eq 0 ]; then
    echo "All checks passed."
    exit 0
else
    echo "${FAILURES} check(s) failed."
    exit 1
fi
