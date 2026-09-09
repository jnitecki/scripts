# Implementation Notes

Tracks how this repo's requirements (`docs/requirements/`) are actually
implemented, kept in sync with the code. If a feature or its code is
removed, remove its section here too.

## Release tag hook (`tools/git-hooks/post-commit.sh`)

Requirement: `docs/requirements/implemented/release-tag-hook.md`.
Test: `tools/git-hooks/test-post-commit.sh`.

- **Change detection**: diffs `HEAD` against `HEAD^1` (or the empty-tree
  hash `4b825dc642cb6eb9a060e54bf8d69288fbee4904` for a root commit),
  restricted to the `platforms/` pathspec. Keeps only paths of the shape
  `platforms/<lang>/<name>/<name>.<ext>` — the script's own main file,
  filtered by requiring the filename stem to equal its containing folder
  name (rules out a sibling `README.md`, etc.).
- **Version comparison**: the `# Version:` value is read via `git show
  <ref>:<path> | head -n 20 | grep/sed`, at both `HEAD` and the base ref;
  any string difference (including "file didn't exist before") qualifies
  as a change. No numeric ordering check — the hook reacts to "the header
  changed," not "the header increased."
- **Changelog excerpt**: scans the first 300 lines of the post-commit
  file's content for a `# <version> - ` comment line, then accumulates
  subsequent lines (comment marker and leading whitespace stripped) until
  either a blank line or a line starting a new version entry, joins them
  with single spaces, and truncates to 500 characters plus `…`. Uses
  bash's `[[ =~ ]]` / `BASH_REMATCH` only — no external regex tools.
  Known cosmetic artifact: a source line hard-wrapped at a hyphen (e.g.
  `cross-platform-shell-` / `compatibility` split across two lines)
  becomes `shell- compatibility` after joining — accepted as-is, since
  reliably distinguishing a hyphenation break from a real hyphen isn't
  worth the added parsing surface for a message field this cosmetic.
- **Tag identity vs. message are separate fields**: the tag's ref name is
  always exactly `<lang>/<script-name>/v<X.Y.Z>` (or `-<suffix>` for a
  pre-release) — the only part any tooling matches against. The changelog
  excerpt only ever goes into the annotated tag's `-m` message.
- **Pre-release tags**: tagged the same as stable versions, using the
  header's version string verbatim (suffix included). Whether an
  autoupdate implementation considers pre-release tags at all is a
  separate, per-script decision — see
  `docs/requirements/generic/script-autoupdate-convention.md` section 3.
- **Idempotent re-tag**: `git tag -d` then re-create, only when a tag
  with that *exact* name already exists locally (e.g. `commit --amend`
  without a version bump) — no other version's tag is ever touched.
- **No push, ever, from the hook**: `git config --local push.followTags
  true` (a one-time step, documented in README.md) makes a normal `git
  push` carry new annotated tags along natively. Re-syncing a tag that
  was replaced locally after already being pushed (the
  idempotent-re-tag-after-push case) is left as a manual `git push
  --force origin refs/tags/<tag>` step — deliberately not automated.
- **Never fails the commit**: no `set -e`; every code path ends with
  `exit 0`. Problems (e.g. `git tag` itself failing) are logged to
  stderr only.
- **bash 3.2 compatibility**: no associative arrays, no `mapfile` — plain
  indexed arrays and `while read` loops throughout, matching
  `docs/requirements/generic/cross-platform-shell-compatibility.md` and
  the style already used by `tools/generate-catalog.sh`.
