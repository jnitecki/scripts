# Implementation Notes

Tracks how this repo's requirements (`docs/requirements/`) are actually
implemented, kept in sync with the code. If a feature or its code is
removed, remove its section here too. Covers only repo-wide tooling not
specific to a single script (git hooks, the catalog generator) — a
generic, cross-cutting convention's *implementation in one particular
script* belongs in that script's own `platforms/<platform>/<script>/docs/`
instead (see `docs/CONTEXT.md`'s "Per-script documentation" section), even
though the convention itself stays documented here under
`docs/requirements/generic/`.

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
  pre-release) — the only part any tooling matches against. The content
  hash and changelog excerpt only ever go into the annotated tag's `-m`
  message.
- **Content-hash prefix**: `file_hash_prefix()` hashes the tagged file's
  raw content at `HEAD` with `sha1sum` (falling back to `shasum -a 1` on
  macOS, where `sha1sum` typically isn't installed), takes the first 12 hex
  characters, and prefixes it in brackets onto the message's identity line:
  `[<hash>] <script-name> (<lang>) v<X.Y.Z>`. Deliberately the plain hash of
  the file's bytes, not `git hash-object`'s blob-object hash (which
  prepends a `blob <length>\0` header) — so any client can reproduce it
  with one standard command, no git required. It's a lightweight
  fingerprint for spotting accidental mismatches, not a cryptographic
  guarantee; if neither hashing tool is found, the bracket prefix is
  silently omitted rather than failing the hook.
- **Pre-release tags**: tagged the same as stable versions, using the
  header's version string verbatim (suffix included). Which levels a given
  self-upgrade check actually considers is governed by
  `docs/requirements/generic/script-upgrade-convention.md` section 3.
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

## Catalog pre-commit hook (`tools/git-hooks/pre-commit.sh`)

Requirement: `docs/requirements/implemented/catalog-precommit-hook.md`.
Test: `tools/git-hooks/test-pre-commit.sh`.

- **Trigger**: reads `git diff --cached --name-only` and fires only if a
  staged path starts with `platforms/`, equals `CATALOG.md`, or matches a
  filename listed in `CATALOG.md`'s current `<!-- CATEGORY-FILES: ... -->`
  manifest comment (read once, before regeneration, so a hand-edited
  category file is caught even without any `platforms/` change). No match
  → hook exits `0` immediately, no scan.
- **Regeneration**: delegates entirely to `tools/generate-catalog.sh
  --source=index` rather than duplicating any rendering/validation logic —
  see the sibling section below for what that mode does. The hook's own
  logic is just: trigger check, run the generator, stage the result.
- **Staging**: after a successful run, `git add CATALOG.md` plus every
  filename in the freshly-written manifest, then `git rm --cached
  --ignore-unmatch` for any filename that was in the *old* manifest (read
  before regeneration) but isn't in the new one — the orphaned-category-
  file case, where the generator already deleted the file from disk but
  the hook still has to unstage it from the index.
- **Abort on failure**: the generator's own exit code is checked directly
  (`if ! generate-catalog.sh --source=index; then exit 1; fi`) — a
  category-filename collision or an invalid `Category:` value aborts the
  commit, matching the decision recorded in the requirement doc's section
  5 (fail closed, consistent with `--check`'s existing behavior).
- **No `--amend`**: deliberately a `pre-commit` hook, not a `post-commit`
  regenerate-then-amend — see the requirement doc's "Rejected alternatives"
  for why amending was ruled out (hash rewrite, ordering hazard against
  the release-tag hook, re-entrant `post-commit` invocation).
- **`--no-verify`**: git's own behavior skips this hook entirely; no
  hook-side mitigation. `tools/generate-catalog.sh --check` remains the
  CI-side backstop for a catalog left stale that way.
- **bash 3.2 compatibility**: same constraints and style as
  `post-commit.sh` above — no associative arrays, plain `while read` loops,
  explicit `break 2` (portable in bash 3.2) to exit the nested
  staged-path/manifest loop once a trigger match is found.

## Catalog generator index mode & category validation (`tools/generate-catalog.sh`)

Requirement: `docs/requirements/implemented/script-catalog-generator.md`,
`docs/requirements/generic/script-header-convention.md` (`Category:` value
format). Exercised indirectly via `tools/git-hooks/test-pre-commit.sh`
(no standalone test file for `generate-catalog.sh` predates this change).

- **`--source=worktree|index`**: enumeration and content-reading are the
  only two primitives that differ between modes — `list_relpaths()`
  (`find` vs. `git ls-files --cached -z -- platforms`) and
  `read_header_lines()` (`head -n 20 <file>` vs. `git show :<path> | head
  -n 20`). Every other function (rendering, the pre-release guard,
  collision detection) is unchanged and shared by both modes; both report
  paths relative to `REPO_ROOT`.
- **Category validation**: `CATEGORY_RE='^[a-z0-9]+(-[a-z0-9]+)*$'`,
  checked per comma-separated token during the same scan pass that already
  builds `CATSPLIT_FILE`. A miss sets `INVALID_CATEGORY=1` and prints the
  offending file/value immediately; the run aborts (exit 1, nothing
  written) right after the scan loop, before the pre-existing
  filename-collision check even runs — an invalid value is rejected at the
  source rather than only being caught once it collides with another.
- **`--source=index` requires a repo**: `git -C "${REPO_ROOT}"
  rev-parse --is-inside-work-tree` is checked once at startup; a
  non-repo invocation with `--source=index` fails fast with a clear error
  rather than failing deep inside `git ls-files`/`git show`.
