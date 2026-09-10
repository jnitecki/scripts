# Requirement: Post-Commit Release Tag Hook

## Scope
A `post-commit` git hook that automatically creates the release tags defined
by [[script-upgrade-convention]] (`<lang>/<script-name>/v<X.Y.Z>`),
resolving that document's open follow-up item ("How/when release tags
actually get created ... is undecided"). Depends on
[[script-header-convention]] for locating each script's `Version:` line, and
on [[cross-platform-shell-compatibility]] for the hook's own bash
portability (it must run under macOS's stock bash 3.2, same constraint as
`container-upgrade.sh`).

Applies only to scripts under `platforms/<lang>/<script-name>/`; does not
touch `tools/` scripts, catalog files, or any other repo content.

## Requirement

### 1. Trigger: detecting a version change
On every commit, the hook inspects the set of files changed in that commit
(`git diff --name-only`, first parent only — see "Merge commits" below)
and, for each changed path matching
`platforms/<lang>/<script-name>/<script-name>.<ext>` (the script's own main
file, per [[script-header-convention]]), compares the `Version:` header line
before and after the commit:
- **New file** (no previous version, i.e. added in this commit or repo
  root commit): treated as a version change from "none" to whatever the
  header declares.
- **Existing file**: a version change is any difference in the `Version:`
  value between the pre-commit and post-commit content of that exact path.
- A changed file whose `Version:` value is unchanged (e.g. only the
  description or changelog prose changed) is skipped — no tag activity.

Every qualifying version change is tagged, stable or pre-release — the
header's version string (`X.Y.Z`, optionally with a `-dev`/`-alpha`/`-beta`/
`-rc` suffix, per the syntax [[script-catalog-generator]] already defines)
is used verbatim as the tag's version component. See
[[script-upgrade-convention]] (updated alongside this doc) for how a
downloading script chooses whether to consider pre-release tags at all.

### 2. Tag creation
For each qualifying version change, the hook creates an **annotated** tag
pointing at the new `HEAD`, with two independent fields:

- **Ref name** — fixed format only, never carries changelog content:
  `<lang>/<script-name>/v<X.Y.Z>` (or `v<X.Y.Z>-<suffix>` for a
  pre-release version), exactly the pattern
  [[script-upgrade-convention]] defines for tag discovery. This is the
  only part any tooling matches/parses against.
- **Annotation message** — the tag's `-m` body (`git tag -a <name> -m
  "<message>"`), i.e. its description field, unrelated to the ref name and
  never consulted by discovery:
  ```
  [<hash>] <script-name> (<lang>) v<X.Y.Z>

  <changelog excerpt, see below>
  ```
  `<hash>` is the first 12 hex characters of the plain SHA-1 hash (`sha1sum`
  on Linux, falling back to `shasum -a 1` on macOS, per
  [[cross-platform-shell-compatibility]]) of the script file's raw content
  at the commit being tagged — the same content the tag itself points at.
  This is a lightweight content fingerprint for spotting accidental
  mismatches, not a cryptographic integrity guarantee, and is deliberately
  the plain hash of the file's bytes (not git's internal blob-object hash,
  which prepends a `blob <length>\0` header) so any client can reproduce it
  with a single standard command, without needing git. It has no bearing on
  the ref name (still fixed-format only, per above) or on tag discovery.

**Changelog excerpt extraction**: within the script's "Version history"
block ([[script-versioning-changelog-help-convention]] section 2), find the
line where the target version number appears and take everything that
follows it (after stripping the language's comment prefix, e.g. `# `, and
leading whitespace, from every line involved) as the excerpt, continuing
across subsequent lines until hitting whichever comes first:
- a line that itself starts a new version entry (matches
  `<version-number> - `), or
- an empty line (a bare comment marker with no content, or a fully blank
  line).
Collected lines are joined with a single space. If the result is longer
than 500 characters, it is cut to exactly 500 and an ellipsis (`…`) is
appended.

This assumes every currently-supported language in this repo comments with
`#` (true for bash, Python, and PowerShell per
[[script-header-convention]]'s own examples); a future language using a
different comment syntax (e.g. Batch's `::`) would need its own
prefix-stripping rule added here.

### 3. Idempotent re-tag (same tag name already exists)
If a tag with that **exact same name** already exists (same script, same
platform, same version — e.g. after `git commit --amend` re-runs the hook
against a commit whose version didn't change since the tag was made, or the
hook is re-invoked against the same state), the hook deletes the existing
tag first, then creates a fresh annotated tag pointing at the current
`HEAD`. This does **not** touch tags for any other version of the same
script — prior release tags (`v1.0.6`, `v1.0.7`, ...) are never deleted;
only an exact name collision is replaced. Tag history for a script is
otherwise append-only, matching the versioning convention's own
changelog-is-append-only rule.

### 4. Remote sync — no push from the hook itself
The hook never pushes anything — no branch, no tag, under any condition. It
only ever creates/replaces local tag refs (sections 2-3). Pushing is left
entirely to git's own native tag-following behavior, configured once per
clone rather than driven by hook logic:

```
git config --local push.followTags true
```

(documented as an install step in **README.md**, alongside the hook
symlink in section 8). With this set, every future plain `git push`
automatically includes any new annotated tag that is reachable from what's
being pushed — the release tag rides along with the commit that carries
it, with no separate `git push --tags` step and no need for the hook to
reason about whether `HEAD` is already on the remote.

`push.followTags` only pushes tags that don't already exist on the remote
— it will never overwrite a remote tag that's already there. The one case
that doesn't cover is section 3's idempotent re-tag when the old tag had
already been pushed (e.g. `commit --amend` after a push, without a version
change): the local tag is replaced, but syncing that to the remote needs a
manual, explicit step:
```
git push --force origin refs/tags/<lang>/<script-name>/v<X.Y.Z>
```
This is intentionally left manual and undocumented-by-automation — it's a
rare edge case (amending an already-pushed commit), and a force-push of a
tag should be a deliberate, visible action rather than something a hook
does unattended.

### 5. Merge commits
Only first-parent diff is considered (`git diff --name-only HEAD~1 HEAD`
sourced via first parent), matching plain `git log`/`git diff` default
behavior for a merge commit. A version bump that arrives solely via a
merge's non-first-parent side is not separately detected by this hook (it
was already detected and tagged when it was originally committed on its
own branch, if that branch also has the hook installed).

### 6. Multiple scripts in one commit
Each qualifying changed script file is processed independently in the same
hook invocation — one commit that bumps two scripts' versions produces two
tags.

### 7. Never blocks or fails the commit
`post-commit` runs after the commit already exists, so it cannot abort it.
With no push logic in the hook (section 4), the remaining failure modes are
purely local (e.g. `git tag` itself failing) — printed to stderr, but the
hook still exits `0` in every case, benign or not.

### 8. Distribution & install
The hook's logic lives as a tracked file, `tools/git-hooks/post-commit.sh`,
so it ships with the repo and is reviewable like any other script (compare
`tools/generate-catalog.sh`). Install, documented in **README.md** (created
as part of this feature, since none exists yet), is two one-time steps:
1. Symlink the hook into place — git's hook lookup requires an exact-named
   executable file (`post-commit`, no extension) inside the active hooks
   directory:
   ```
   ln -sf ../../tools/git-hooks/post-commit.sh .git/hooks/post-commit
   ```
2. Enable tag-following pushes (section 4):
   ```
   git config --local push.followTags true
   ```
`tools/git-hooks/` is named generically (not `tools/git-hooks/post-commit/`)
so future hooks (e.g. `pre-push.sh`) can live alongside this one, each
installed the same way.

## Rejected alternatives
- **Delete the previous version's tag whenever a script's version
  changes** (keep only the latest tag per script): rejected — breaks the
  append-only release history this repo already keeps for everything else
  (script changelogs, tag list), and isn't needed by
  [[script-upgrade-convention]]'s discovery algorithm, which already
  only cares about the *highest* matching (by default, stable-only) tag
  regardless of how many older ones exist.
- **Hook pushes automatically, gated on whether the commit is already on
  the remote**: an earlier draft of this doc. Superseded by
  `push.followTags` (section 4) — git's own tag-following push does the
  same job natively, without the hook having to reason about remote state
  or ever force-push unattended.
- **`core.hooksPath` pointing straight at `tools/git-hooks/`**: rejected
  because git's hook lookup needs an exact-named file per hook
  (`post-commit`, no extension), which would force the tracked file itself
  to lose its `.sh` extension. A one-line symlink keeps the tracked source
  file conventionally named while still satisfying git's lookup.
- **Only tagging stable versions**: an earlier draft of this doc. Changed
  to tagging every version, pre-release included — filtering pre-releases
  out of *discovery* (a downloading script's decision, see
  [[script-upgrade-convention]]) is a different concern from whether a
  release tag exists for them at all.
- **No changelog excerpt in the tag message, or extraction based on
  matching each continuation line's indentation column**: an earlier draft
  of this doc. Dropped entirely (identity-line-only) or reconsidered
  (indentation-based) in favor of the simpler start/end rule in section 2 —
  bounded by the next version number or a blank line, with no assumption
  about how far continuation lines are indented.
- **`git hash-object` (git's blob SHA-1) instead of a plain file hash**:
  rejected — it's SHA-1 over git's internal `blob <length>\0<content>`
  object format, not the file's raw bytes, so a client without git would
  need to replicate that header exactly to reproduce the same value. A
  plain `sha1sum`/`shasum -a 1` of the file content is one standard command
  for any client, with no git-specific format to reimplement.

## Rationale
Closes the one open question left by [[script-upgrade-convention]]:
release tags now come into existence automatically, from the same
`Version:` header that already drives the changelog, `--help`, and startup
banner, so there is exactly one place a script's version is declared and
every downstream artifact (tag included) derives from it. Pushing rides on
git's own `push.followTags`, a config toggle, instead of hook logic
re-implementing what git already does — one less thing this hook can get
wrong, and it disappears entirely as a source of unattended force-pushes.
