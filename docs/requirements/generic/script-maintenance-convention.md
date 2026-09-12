# Requirement: Script Maintenance Convention

## Scope
Applies to every script in this repository, regardless of scripting/programming
language or the platform/category directory it lives under. This doc collects
repo-wide *process* and *authoring* rules for how scripts are changed and
released, layered on top of [[script-header-convention]],
[[script-versioning-changelog-help-convention]], and
[[script-upgrade-convention]]. Where a rule here overrides or supersedes a
specific section of one of those docs, that section says so explicitly and
points back here.

## 1. Self-upgrade changes: fix the blueprint first, then replicate
- Any change or fix to the **self-upgrade mechanism itself** (not a script's
  own domain logic) must be made in the reference blueprint first —
  `tools/blueprints/<platform>.<ext>` (see [[script-upgrade-convention]]'s
  "Per-language blueprint" section).
- Only once the blueprint reflects the fix does it get replicated into every
  script in the repo that has adopted self-upgrade for that language/platform
  — not only the one script named in whatever issue report or improvement
  request triggered the fix.
- This does not apply to a script's own domain-specific bug fixes (e.g.
  container-upgrade's restart-policy handling) — only to the shared
  self-upgrade subsystem (anything inside the "Self-upgrade ... begins/ends"
  block a script copied from the blueprint).
- Rationale: the blueprint is the single source of truth for the self-upgrade
  mechanism. A fix that lands in one script without updating the blueprint
  (and the other adopters) re-ships the same bug the next time a script
  copies from the blueprint, and leaves existing adopters silently diverged
  from each other.

## 2. `--help` layering: core options vs. self-upgrade options
Supersedes [[script-versioning-changelog-help-convention]] section 3's flat
option list, for any script that also implements
[[script-upgrade-convention]]:
- Bare `--help` (or `-h`): shows the script's own core/domain options only.
  Self-upgrade options (`--upgrade-type`, `--upgrade-level`,
  `--upgrade-check`, `--upgrade-only`, `--no-autoupdate`, etc.) are omitted,
  with a one-line pointer to `--help full` / `--help upgrade` for them.
- `--help upgrade`: shows only the self-upgrade options, omitting the
  script's own core options (with a similar one-line pointer back to plain
  `--help` for those).
- `--help full`: shows everything — core options followed by self-upgrade
  options, each under its own labeled heading.
- Self-upgrade options are always listed after the script's own core
  options, never interleaved, in whichever of the three views includes both.
- A script with no self-upgrade support is unaffected — its `--help` stays
  exactly as [[script-versioning-changelog-help-convention]] section 3
  already specifies (a single, complete option list).

## 3. Changelog lives in `CHANGELOG.md`, not the script header
Supersedes [[script-versioning-changelog-help-convention]] section 2 in full:
- Each script's own directory (`platforms/<lang>/<name>/`) has a
  `CHANGELOG.md` holding the complete, append-only version history for that
  script — one entry per version bump, **newest entry at the top** (unlike
  the old in-script convention, which appended at the bottom; a standalone
  changelog file is read top-down, so the newest-first convention applies
  here).
- The script's own header keeps only the **3 most recent** version-bump
  entries, **newest first** (same ordering as `CHANGELOG.md`, and for the
  same reason — consistent top-down reading order between the two): the
  single most recent one in full detail (as before), listed first, and the
  two after it abbreviated to one line each (version number + short
  summary, no elaboration). Older entries are dropped from the header
  entirely once they age past that 3-entry window — they remain permanently
  in `CHANGELOG.md`.
- Every version bump updates both together: the full entry is written to
  `CHANGELOG.md` (newest at the top), and the header's 3-entry window shifts
  — the new entry is added in full at the top, the entry that was
  previously "full" becomes "abbreviated" (now second), and the oldest of
  the three is dropped entirely.
- `--help` and the startup banner are unaffected structurally — they still
  source the version from the header's `Version:` line — but `--help`'s
  usage text now shows only the header's trimmed 3-entry window, not the
  complete history; the complete history lives in `CHANGELOG.md`.

### Stable-only header entries; consolidated in-progress entry
The header's 3-entry window (above) shows **stable versions only** as
individual entries — a pre-release bump never gets its own line there. This
does not mean pre-release work goes undocumented in the header; it means
every pre-release bump since the last stable release is folded into one
running entry instead of each getting its own line:
- If the script's currently-running `Version:` is stable (no suffix), the
  window behaves exactly as described above: the 3 most recent *stable*
  entries, newest first, most recent in full.
- If the currently-running `Version:` carries a pre-release suffix (e.g.
  `1.1.6-dev2`), the window's first (full-detail) slot is not that specific
  pre-release version — it is a single **consolidated entry** for the whole
  in-progress cycle, headed something like `1.1.6 (in progress - currently
  1.1.6-dev2)`, whose body summarizes *every* change made across every
  pre-release bump since the last stable release (`1.1.5` here), rewritten
  as one coherent description rather than concatenated per-bump notes. Each
  further pre-release bump in the same cycle updates this one consolidated
  entry in place — it does not add a second header entry. The window's
  remaining two slots are still the 2 most recent *stable* entries,
  abbreviated, exactly as in the stable case.
- `CHANGELOG.md` is not consolidated the same way: every individual bump,
  pre-release included, keeps its own dedicated entry there (unaffected by
  this subsection). Consolidation is a `--help`/header-readability concern
  only — a reader of `--help` wants "what's changed since the last real
  release," not a blow-by-blow of intermediate dev iterations; a reader of
  `CHANGELOG.md` wants the exact history.
- When a pre-release cycle is finally promoted to stable (the suffix is
  dropped — a deliberate action per section 4 below, not automatic),
  `CHANGELOG.md` gains a **new stable-version entry** whose body is that
  same consolidated summary — i.e. the content that had been living in the
  header's in-progress entry graduates into `CHANGELOG.md` as the entry for
  the newly-stable version, *in addition to* (not replacing) the individual
  pre-release entries already recorded there for that cycle. The header
  then drops back to the plain stable-only case, with this new version now
  its most recent full entry.

## 4. Version increment scheme
Extends [[script-versioning-changelog-help-convention]] section 1's "bumped
at least at the patch level" rule with a precise algorithm, and extends
[[script-catalog-generator]]'s `-dev`/`-alpha`/`-beta`/`-rc` suffix (previously
unnumbered) with a trailing revision number:

- **Suffix present** (`-dev<N>`, `-alpha<N>`, `-beta<N>`, or `-rc<N>`):
  increment `N` by 1; `X.Y.Z` and the suffix word are unchanged.
  `1.2.3-dev1` → `1.2.3-dev2`.
- **Bare version** (`X.Y.Z`, no suffix — i.e. "stable"): increment `Z` and
  start a new pre-release cycle at `-dev1`. `1.2.3` → `1.2.4-dev1`. A stable
  version is never bumped directly to another stable version in place; it
  passes back through a fresh dev/alpha/beta/rc cycle. Promoting a
  pre-release to stable (dropping the suffix once ready to release) is a
  separate, deliberate release-management action, not an automatic side
  effect of this increment rule.
- Changing the suffix **word** itself (e.g. `-dev3` → `-alpha1`, or `-rc2` →
  stable) is likewise a deliberate action, not performed by this rule.
- Both [[script-catalog-generator]]'s suffix handling and
  [[script-upgrade-convention]]'s level parsing must treat the trailing
  digits as part of the *number*, not the level name, when determining a
  version's level — `1.2.3-dev7`'s level is `dev`, not `dev7`.

### Version ordering with numbered suffixes
Extends [[script-upgrade-convention]] sections 3-4's version comparison. Two
versions are compared, in order:
1. Numeric `X.Y.Z` (major, then minor, then patch) — a higher `X.Y.Z` always
   wins, regardless of suffix, *subject to the eligibility gate below*.
2. If `X.Y.Z` is equal: level rank (`dev < alpha < beta < rc < stable`) — a
   higher level wins.
3. If `X.Y.Z` and level are both equal: the trailing suffix number — a
   higher number wins. `1.2.3-dev1 < 1.2.3-dev2 < 1.2.3-dev3 < 1.2.4-dev1`.

**Eligibility gate (unchanged from [[script-upgrade-convention]] section 3,
restated for clarity with numbered suffixes):** a script only ever considers
upgrade candidates at or above its *effective minimum level* — the level of
`--upgrade-level` if given, else the running script's own level. This gate
is applied *before* the ordering above and is independent of `X.Y.Z`: a
stable `1.2.3` does not consider `1.2.4-beta2` an eligible candidate at all
(`beta < stable`), even though `1.2.4 > 1.2.3` numerically — no matter how
large the numeric jump. Widening `--upgrade-level` (e.g. to `beta` or
`alpha`) is the only way to make such a candidate eligible; once eligible,
the three-step ordering above picks the winner among everything that passed
the gate.

**Implementation note — a real bug this section's own rollout hit
immediately.** A script's own `Version:` header-parsing regex (e.g.
`container-upgrade.sh`'s `grep -m1 -E '^# Version: [0-9]+\.[0-9]+\.[0-9]+
(-[a-z]+)?$'`) also has to accept the trailing revision number, not just
[[script-upgrade-convention]]'s comparison functions — the pattern above only
allowed letters after the dash. Adopting a numbered suffix without updating
this regex too makes the script fail to parse its own version at all (silent
fallback to `"unknown"`), which then breaks everything downstream that
assumes a valid version string. The fix is `(-[a-z]+[0-9]*)?` (letters,
then optional trailing digits) in place of `(-[a-z]+)?`.

## Rationale
These are cross-cutting authoring/process rules discovered while maintaining
`container-upgrade.sh` and its shared self-upgrade mechanism — kept separate
from the topic-specific convention docs they extend so that "how we make
changes across every script" stays in one place, rather than scattered
implicitly across individual fix commits.

## Implementation status
Sections 2-4 are implemented in `container-upgrade.sh` (v1.1.6-dev1) and,
per section 1's own rule, in the bash blueprint first:
- Section 4 (version comparison): `upgrade_version_level`/
  `upgrade_version_gt` in both `tools/blueprints/bash.sh` and
  `container-upgrade.sh` strip the trailing revision number before computing
  level and use it as the final ordering tiebreaker; a new
  `upgrade_version_number` extracts it. `upgrade_parse_versions` in both no
  longer discards a discovered tag's suffix (a pre-existing bug — see
  `CHANGELOG.md`'s 1.1.6-dev1 entry). `tools/generate-catalog.sh`'s
  `resolve_version` guard got the matching same-level/same-`X.Y.Z` tiebreak
  (its `version_level` already tolerated numbered suffixes via glob
  matching, so only the tiebreak itself was missing).
- Section 3 (changelog): `platforms/bash/container-upgrade/CHANGELOG.md`
  holds the complete history, newest first; the script header keeps only
  its 3 most recent entries.
- Section 2 (`--help` layering): `container-upgrade.sh`'s `usage()` now
  slices its header by content-based markers (`# HELP:<region>:BEGIN`/
  `:END`) instead of hardcoded line numbers, and supports `--help` (core
  options only), `--help upgrade` (self-upgrade options only), and
  `--help full` (both). The bash blueprint's orchestration sketch documents
  the same `usage_region`/`usage` pattern.
- Section 1 (blueprint-first workflow): followed for this very rollout —
  the version-comparison fix (section 4) was written into
  `tools/blueprints/bash.sh` first, then replicated into
  `container-upgrade.sh`. Still has no tooling enforcement; it remains a
  process rule for whoever makes the next self-upgrade change, and for any
  other adopting script once one exists.

Not yet done: no other script in the repo adopts self-upgrade yet, so
section 1's "replicate to every adopting script" and section 2's `--help`
layering have only ever been exercised against this one script.
