# Requirement: Script Catalog Generator (restructure)

## Scope
Replaces the earlier single-file catalog design. Applies to a single
generator script that produces a stable root-level master index plus one
detail file per category. Depends on [[script-header-convention]] for
per-script metadata, including the comma-separated `Category:` syntax and
the "reuse an existing category" convention it defines.

## Requirement

### Identifying a script across platforms
A script is identified by the leaf folder name under `platforms/<lang>/`.
When the same folder name exists under more than one `platforms/<lang>/`
tree (e.g. `platforms/bash/container-upgrade/` and
`platforms/powershell/container-upgrade/`), those are treated as platform
variants of the same logical script and merged into one catalog entry.
Each variant keeps its own independent `Version` — versions may differ
across platforms for the same script.

### CATALOG.md (master, root)
A single stable, low-churn file: a flat table, one row per logical script
(no `## category` heading grouping), with no links and no version:

| Name | Description | Categories | Platforms |
|---|---|---|---|
| container-upgrade | Docker image upgrade automation with rollback support | containers | bash |

- **Categories** lists every category the script belongs to, comma-separated.
- **Platforms** lists every platform name the script has an implementation
  for (e.g. `bash, powershell`), as plain text — no links.
- Carries the same `<!-- AUTO-GENERATED ... do not edit by hand -->` marker
  and generation timestamp convention as the original CATALOG.md.

### Per-category files (root)
One file per category currently in use, named from the category identifier
uppercased with spaces converted to hyphens (e.g. `containers` →
`CONTAINERS.md`). A script belonging to multiple categories appears in each
of its category files.

Each script entry includes the full Categories set (for cross-reference,
since the file is scoped to one category but the script may belong to
others) and one sub-line per platform, each carrying that platform's own
version and a link to its implementation file:

```
### container-upgrade
Docker image upgrade automation with rollback support
Categories: containers
- **bash** (v1.0.7) — [container-upgrade.sh](platforms/bash/container-upgrade/container-upgrade.sh)
```

**UNCATEGORIZED.md** is the catch-all for scripts with no `Category:`
header — same rules as any other category file (created only when at least
one such script exists).

### File lifecycle
- A category file is deleted by the generator when it would have zero
  entries (its last script was removed, recategorized, or renamed away from
  it) — a stale category file never persists past a regeneration.
- Because categories are free-text (no fixed vocabulary — see
  [[script-header-convention]]), two different category identifiers could
  in principle uppercase/hyphenate to the same filename. The generator
  detects this before writing anything and aborts with no files written,
  listing the colliding categories.

### Single generator, atomic output
`tools/generate-catalog.sh` produces CATALOG.md and every per-category file
in a single invocation. All content is rendered and validated (including
category-value format and filename-collision checks) before anything is
written, so a failed run leaves the existing files untouched rather than
partially updated.

`--check` mode validates the entire generated set in one pass — every
file's content against a fresh render, and the set of category files that
exist on disk against the set that should exist — and exits non-zero
without writing if anything is stale, for use as a CI gate.

### Source: working tree or git index
`--source=worktree` (default) scans `platforms/` on disk, as before.
`--source=index` scans the git index instead — file enumeration via
`git ls-files --cached` and content reads via `git show :<path>` — so the
generated catalog reflects exactly what's staged, not whatever else is
sitting in the working tree. Used by
[[catalog-precommit-hook]] (`tools/git-hooks/pre-commit.sh`) so a partially-
staged or unstaged edit to a platform script never leaks into a commit's
catalog. Both modes share the same rendering, pre-release-guard, and
validation logic — only file enumeration and content reads differ.

### Category value format
Each `Category:` token must match `^[a-z0-9]+(-[a-z0-9]+)*$` (see
[[script-header-convention]]). A non-conforming value is a hard error —
exit non-zero, nothing written, naming the offending file and value — same
severity as the filename-collision check below, since an invalid value is
exactly what makes that collision possible.

### Pre-release version guard
A script's `Version:` header may carry a pre-release suffix: `-dev`,
`-alpha`, `-beta`, or `-rc` (precedence, lowest to highest:
`dev < alpha < beta < rc < stable`, where "stable" is no suffix at all).
When regenerating, the freshly-scanned version does not automatically
overwrite what's already recorded for that (script, platform) in the
currently-committed category file:
- No entry recorded yet for that (script, platform): the scanned version is
  used as-is, whatever it is — including `-dev` — since there's nothing to
  protect.
- Scanned version is stable: always used (unchanged, mirrors the source of
  truth as before this guard existed).
- Scanned version is `-dev`: never replaces an existing recorded entry,
  regardless of that entry's own level. Only the "no entry recorded yet"
  case above lets a `-dev` version reach the catalog.
- Scanned version is `-alpha`/`-beta`/`-rc`: replaces the recorded entry
  only if the recorded entry's level is lower (progressing to a higher
  level always wins), or the same level with a strictly higher `X.Y.Z`
  (e.g. a recorded `-alpha` can be replaced by a higher `-alpha`, but not
  an equal or lower one). A higher-level recorded entry (e.g. stable, or
  `-rc` against an `-alpha` candidate) is never regressed.
- Only the displayed version string is affected by this guard — a script's
  description, categories, and implementation link always reflect the
  current scan, regardless of whether its version was held back.

This only applies to the version shown in each per-category file (`v${X.Y.Z}`
next to each platform); CATALOG.md carries no version field and is
unaffected.

## Implementation notes
- **Orphan tracking**: root-level files already follow an ALL-CAPS naming
  convention for hand-authored docs (README.md, CONFIGURATION.md,
  PREREQUISITES.md, FEATURES.md), so filename shape alone can't tell a
  generator-owned category file apart from one of those. CATALOG.md embeds
  an HTML comment (`<!-- CATEGORY-FILES: CONTAINERS.md ... -->`) listing the
  category files the last run produced; the generator diffs that manifest
  against the newly computed set to know exactly which files it owns and
  may delete, without ever touching a hand-authored root file.
- **`--check` timestamp handling**: the `_Generated <date> UTC._` line is
  excluded from all `--check` content comparisons. Including it would make
  the gate fail on every run after the file's commit minute regardless of
  whether anything meaningful changed, defeating its purpose as a CI gate.

## Rejected alternatives
- **Per-platform file** (`CATALOG-by-platform.md`): dropped as redundant —
  the `platforms/<lang>/` directory layout already gives that view.
- **Per-category files under a `category/` directory** using symlinks back
  to canonical scripts: dropped due to a known content-corruption risk when
  such symlinks are fetched via `raw.githubusercontent.com`. The current
  per-category files hold fully rendered content instead, so that risk
  doesn't apply, and they live at the repo root — deliberately visible
  alongside CATALOG.md rather than tucked in a subfolder.
- **Single consolidated CATALOG.md with `## category` headings and no
  per-category files**: the original design. Superseded because version
  numbers (high-churn) and category groupings (low-churn) were forced into
  one file, making every version bump touch the one file everyone browses
  first.

## Rationale
Splits volatility: CATALOG.md changes only when a script is added, removed,
renamed, or recategorized, so it stays a stable, low-diff-noise root index.
Per-category files absorb the high-churn field (version) and the
implementation links, without forcing every version bump to touch the file
everyone browses first.
