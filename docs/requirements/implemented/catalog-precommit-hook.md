# Requirement: Pre-Commit Catalog Regeneration Hook

## Scope
A `pre-commit` git hook that regenerates `CATALOG.md` and the per-category
files from the content that is about to be committed (the git **index**),
and stages any resulting changes so they land in the same commit as the
script changes that caused them. Sibling to [[release-tag-hook]]
(`post-commit`), but runs *before* the commit exists rather than after —
chosen specifically to avoid `post-commit` + `--amend`, which was
considered and rejected (see "Rejected alternatives").

Depends on and extends [[script-catalog-generator]] (`tools/generate-catalog.sh`
gains a new index-reading mode) and tightens one rule in
[[script-header-convention]] (`Category:` value format, see section 4).

## Requirement

### 1. Trigger condition
The hook inspects `git diff --cached --name-only` (staged paths only — never
the working tree) and runs the regeneration in section 2 only if that set
intersects:
- any path under `platforms/`, or
- `CATALOG.md`, or
- any filename currently listed in `CATALOG.md`'s
  `<!-- CATEGORY-FILES: ... -->` manifest comment (so a hand-edit to e.g.
  `CONTAINERS.md` is caught and corrected too).

If none match, the hook exits `0` immediately with no scan performed.

### 2. Source of truth: the git index, not the working tree
`tools/generate-catalog.sh` gains a `--source=index` option (default remains
`--source=worktree`, today's disk-scanning behavior, unchanged for the
manual/CI/`--check` use cases). In index mode:
- **Enumeration**: `git ls-files --cached` restricted to the scanned
  extensions under `platforms/`, instead of `find`.
- **Content reads**: `git show :<path>` (index stage 0), instead of reading
  the file off disk.
- **Scope**: still a *full* rescan of every matching index entry, exactly
  like today's full worktree scan — not limited to the staged diff. This
  keeps index and worktree modes sharing one rendering/validation/
  collision-detection code path, differing only in the two I/O primitives
  above.

This is the direct fix for the problem with using `generate-catalog.sh`
unmodified from a pre-commit hook: it would otherwise pick up unstaged or
partially-staged (`git add -p`) edits to platform scripts sitting in the
working tree, producing a catalog that doesn't match what's actually being
committed.

### 3. Write and stage the result
The hook runs the generator in index mode, writes `CATALOG.md` and every
category file to the working tree exactly as a normal run would, removes
any orphaned category file (per [[script-catalog-generator]]'s existing
lifecycle rule), then `git add`s every file it wrote and `git rm --cached`s
every file it removed, so the net effect is staged and included in the
commit about to be made.

Catalog files are already marked `<!-- AUTO-GENERATED ... do not edit by
hand -->`; the hook's write is authoritative and intentionally overwrites
whatever is on disk for these specific files (including any unrelated,
not-yet-staged local edit to them), the same way a formatter's pre-commit
hook overwrites unstaged formatting drift.

### 4. Category value validation (new rule)
[[script-header-convention]] already states `Category:` values should be
"short lowercase identifiers" but nothing validates that today, and the
convention is silent on word-separator style. Both gaps are closed:

- New rule: each comma-separated `Category:` token must match
  `^[a-z0-9]+(-[a-z0-9]+)*$` — lowercase letters/digits, hyphen-separated
  words, no spaces, no other punctuation.
- `tools/generate-catalog.sh` validates every scanned token against this
  pattern, in **both** source modes (not just index mode — this is a
  content rule, not a hook-specific one). A violation is a hard error:
  exit `1`, nothing written, naming the offending file and the invalid
  value — same severity as the existing category-filename-collision check,
  since an invalid value is exactly what makes that collision possible
  (e.g. `Containers` vs `containers`, or `web scraping` vs `web-scraping`
  no longer reach the collision check at all — they're rejected earlier,
  at the source).
- The existing collision check (two distinct, both-valid category values
  that still normalize to the same filename) is kept as-is; validation
  narrows when it can fire, it doesn't replace it.
- No migration needed: the one category currently in use (`containers`)
  already conforms.

### 5. Abort on failure
Both the validation failure (section 4) and the pre-existing
category-filename-collision check abort the **commit**, not just the
generation step: the hook exits non-zero, git refuses to create the commit,
and nothing is written or staged. This matches `--check`'s existing
fail-closed behavior and was a deliberate choice over warn-and-commit —
catalog corruption never enters history, at the cost of occasionally
blocking a commit until the offending header is fixed.

### 6. Atomic output, no partial writes
Inherited unchanged from [[script-catalog-generator]]: all content is
rendered and validated before anything is written in either mode.

### 7. Interaction with `--no-verify`
`git commit --no-verify` skips pre-commit hooks entirely — this is git's
own behavior, not something this hook can or should override. A commit made
that way can leave the catalog stale relative to `platforms/`. No hook-side
mitigation is proposed; `tools/generate-catalog.sh --check` (already usable
as a CI gate per [[script-catalog-generator]]) remains the backstop for
that case.

### 8. Distribution & install
Tracked file `tools/git-hooks/pre-commit.sh`, installed the same way as
`post-commit.sh`:
```
ln -sf ../../tools/git-hooks/pre-commit.sh .git/hooks/pre-commit
```
Documented in **README.md** alongside the existing hook-install step.

## Rejected alternatives
- **`post-commit` hook that regenerates and `git commit --amend`s**: the
  originally-proposed alternative. Rejected —
  - `--amend` rewrites the commit hash; if this lived in the same
    `post-commit.sh` as [[release-tag-hook]]'s tag creation, correctness
    would depend on running the amend *before* the tag is created (a tag
    made first would end up pointing at a commit that no longer exists on
    any branch) — a fragile ordering dependency that doesn't exist today.
  - `--amend` re-triggers `pre-commit`/`commit-msg` hooks, and completing
    the amend re-triggers `post-commit` itself, requiring an explicit
    re-entry guard to avoid recursion.
  - It silently changes the commit hash the user just saw printed by
    `git commit`, after the fact — surprising if that hash was already
    referenced anywhere.
  - [[release-tag-hook]] already treats `--amend` as a rare, manually-
    handled edge case (its section 3/4); routinely amending every commit
    for catalog regeneration contradicts that stance.
- **Diff-only rescan in index mode** (only re-derive rows for staged
  paths, patch them into the last-known catalog): rejected in favor of a
  full rescan identical in shape to the existing worktree mode — keeps one
  shared rendering/validation code path and avoids a second, harder-to-
  verify incremental-update algorithm.
- **Warn-and-commit on validation/collision failure**: rejected — see
  section 5.

## Rationale
Keeps the catalog and the code that produced it in the same commit, with no
history rewriting and no dependency ordering against the existing tag hook.
Extending the existing generator with a pluggable source (index vs.
worktree) reuses its rendering, pre-release-guard, and collision-detection
logic as-is rather than forking a second implementation that could drift
out of sync with it. Tightening the `Category:` format closes the specific
gap that made filename collisions possible in the first place, rather than
only detecting them after they occur.
