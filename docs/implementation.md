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

## Self-upgrade (`platforms/bash/container-upgrade/container-upgrade.sh`)

Requirement: `docs/requirements/generic/script-upgrade-convention.md`.
Blueprint followed: `tools/blueprints/bash.sh` (both renamed from their
`autoupdate`/`update` predecessors in the same rework). Identity:
`Upgrade-Source: github.com/jnitecki/scripts@bash/container-upgrade`.

- **Code organization**: every `upgrade_*` function lives in one
  contiguous block (between matching `# ===...=== Self-upgrade ... begins`
  / `... ends` banner comments), placed last among the script's function
  definitions, right before `usage()`. Call sites in the top-level flow
  (flag parsing, the `--upgrade-check`/`--upgrade-only` early-exit
  branches, the `upgrade_main` call) carry `# --- self-upgrade: ... ---`
  markers — per the convention's section 15 demarcation requirement.
- **Where it runs**: `upgrade_main` is called once, right after CLI
  argument parsing (and after the `--upgrade-check`/`--upgrade-only`
  early-exit branches, which run even earlier) and before container-engine
  work (engine auto-detect, the `jq` presence check, etc.). `--help` is
  unaffected since `usage()` exits inside the option-parsing loop, before
  any of this is reached.
- **Original argv capture**: `ORIGINAL_ARGS=("$@")` is captured immediately
  before the option-parsing `while` loop (which otherwise consumes `$@`
  entirely via repeated `shift`), so the trial-run candidate can be handed
  the exact original arguments.
- **Level-aware discovery**: `upgrade_parse_versions` extracts every
  matching tag's `X.Y.Z` plus its optional `-suffix` from the
  `matching-refs` JSON in one pass (`[^"]*` rather than an optional-group
  regex like `\?`/`\{0,1\}`, which is a GNU sed extension BSD/macOS sed
  doesn't support — caught by testing against real macOS `sed`, not just
  Linux). `upgrade_highest_at_level` then picks the numeric-highest tag at
  or above a given level, reused three ways: the effective upgrade target
  (own level, or `--upgrade-level`), and (for `--upgrade-check` only) the
  newest stable tag and newest tag overall — all from the *same* fetched
  tag list, no repeated HTTP calls.
- **Apply-mode cascade**: `upgrade_select_mode` walks
  `replacement → overwrite → link → memory` starting at `--upgrade-type`'s
  rank (or `replacement` if unset), returning the first whose filesystem
  precondition (`upgrade_mode_possible`) holds — directory-writable,
  file-writable, cache-dir-writable, or unconditional, respectively.
  `--upgrade-type` is a ceiling, never escalated past.
- **Persistent cache (link mode)**: `upgrade_cache_dir`/`upgrade_cache_file`
  resolve to `${XDG_CACHE_HOME:-$HOME/.cache}/scripts-upgrade/bash/container-upgrade/container-upgrade.sh`.
  `upgrade_prepare_candidate` checks a cache hit's hash against the
  winning tag's declared hash before deciding whether to download at all.
- **Download validation**: `bash -n` against the fetched content via
  process substitution (syntax-only), then, best-effort, a content-hash
  match against the winning tag's own `[<hash>]`-prefixed message (see
  [release-tag-hook.md](requirements/implemented/release-tag-hook.md)) —
  `upgrade_fetch_tag_hash` does two more `curl` GETs against GitHub's git
  database API (a ref lookup for the tag object's SHA, then the tag object
  itself for its `message`), extracting the bracketed hash with `grep -oE`
  rather than JSON-parsing the message field generally, since the hash
  sits at the very start of the message, before any encoded newline.
  `upgrade_hash_prefix` computes the same 12-hex-char plain-SHA1 prefix
  over the downloaded content. Both print nothing (not a failure) when
  they can't produce a value; a mismatch only counts when *both* sides
  actually produced one and they differ (banner outcome `hash_mismatch`).
- **Trial-run-then-persist apply**: all of `upgrade_only_main` and
  `upgrade_main`'s per-mode branches share the persistence primitives
  (`upgrade_write_temp_sibling`, `upgrade_persist_replacement`,
  `upgrade_persist_overwrite`, `upgrade_persist_link`) but differ in
  whether a trial run happens first. In the ordinary flow
  (`upgrade_main`), the candidate is executed for real — as a child
  process, original argv forwarded (a same-directory temp file for
  `replacement`; `bash -c` for `overwrite`/`memory`; the cache file itself
  for `link`) — and only a `0` exit gets persisted; `upgrade_main` then
  `exit`s with that child's exact code either way, never returning to run
  the old version's own logic too (confirmed: a failed trial is this
  invocation's own outcome, not retried). `upgrade_only_main` skips the
  trial (no "real work" applies to it) and persists directly.
- **Re-entry guard**: before invoking the trial candidate, `upgrade_main`
  exports `CONTAINER_UPGRADE_APPLIED_FROM=<old version>` and
  `CONTAINER_UPGRADE_APPLIED_MODE=<mode>`; the candidate's own
  `upgrade_main` (run as a fresh process, so it goes through its own
  top-level flow from scratch) sees those, sets `UPGRADE_BANNER_NOTE`
  itself (`self-upgrading from vOLD via MODE`, printed *before* its trial's
  outcome is known — see the convention's section 10 on why the wording
  can't claim persistence yet), unsets both, and returns immediately
  without re-checking. Verified directly (exported vars reach a
  directly-executed child script) and via the real end-to-end run below;
  the banner note itself couldn't be observed live since the only tag
  currently on the remote (`v1.0.7`) predates this rework and doesn't know
  the new guard var name.
- **Cooldown cache**: `${XDG_CACHE_HOME:-$HOME/.cache}/scripts-upgrade/bash_container-upgrade.state`,
  a single Unix-epoch timestamp, 20-minute window
  (`UPGRADE_COOLDOWN_SECONDS`), written best-effort. Only gates a fully
  implicit invocation — any of `--upgrade-type`/`--upgrade-level`/
  `--upgrade-check`/`--upgrade-only` forces a fresh check (unless the net
  effect is disabled), which is why `--force-update-check` was removed as
  redundant.
- **New flags**: `--upgrade-type`, `--upgrade-level`, `--upgrade-check`,
  `--upgrade-only`, `--no-autoupdate` (kept as an alias for
  `--upgrade-type none`), documented in the header's `--help` text
  (`usage()`'s `sed -n '2,223p'` range updated to match the longer header)
  and in the platform README. Combination validation
  (`--upgrade-type`+`--no-autoupdate`, `--upgrade-check`+`--upgrade-type`,
  `--upgrade-check`+`--upgrade-only`) rejects immediately with a clear
  error, per the repo-wide unrecognized-option convention extended to
  option combinations here.
- **Banner-note coverage & persist-outcome reporting**: `upgrade_banner_note`
  now also covers `not_checked` (cooldown not elapsed on an implicit run)
  and `no_upgrade` (checked, nothing newer at the effective level) —
  previously both left the banner bare, indistinguishable from self-upgrade
  being disabled outright, which is now the only case with no note.
  `upgrade_prepare_candidate` sets the latter itself so `upgrade_only_main`'s
  own fallback text for "nothing to report" became dead code and was
  removed — `UPGRADE_BANNER_NOTE` is now unconditionally set on every
  failure path. Separately, `upgrade_main`'s `replacement`/`overwrite`
  branches now report the persist step's own outcome (a plain `mv`/rewrite,
  which can still fail after a successful trial run) via `log`/`err`, one
  line printed after the trial run's own output — this never changes
  `$code`, which the branch still `exit`s with unconditionally. `link` and
  `memory` need no equivalent: `link` persists *before* its trial run (a
  failure there is already a pre-trial `check_failed` note), and `memory`
  never persists at all.
- **Verified against the live remote**: `--upgrade-check` and a full
  ordinary run (real trial execution, including actual `podman` container
  inspection on the machine this was tested on) were exercised end-to-end
  against `github.com/jnitecki/scripts`'s real `bash/container-upgrade/v1.0.7`
  tag, using a scratch copy artificially downgraded to `v1.0.0` — discovery,
  download, parse/hash validation, the trial run, and the replacement
  persist step all confirmed working correctly. The mode-selection cascade,
  numeric/level comparison, and persistence primitives were additionally
  unit-tested in isolation (including the `link`/`memory`/ceiling-capping
  cases, which the live remote's single stable tag couldn't exercise on
  its own).
- **Content-hash capture bug (fixed in 1.1.2)**: `content=$(upgrade_download
  ...)` silently stripped the download's trailing newline (command
  substitution's documented behavior), so `upgrade_hash_prefix "$content"`
  hashed one byte fewer than `tools/git-hooks/post-commit.sh`'s
  `file_hash_prefix` did (`git show ref:path | sha1sum`, newline intact) —
  every check against every real tag failed with a false content-hash
  mismatch, caught only once a live check against the real `v1.1.1` tag was
  run (earlier isolated testing never round-tripped through the lossy
  capture). Fixed by having `upgrade_download` append a `\x01` sentinel
  after its real output and having the caller strip it back off
  (`"${content%$'\x01'}"`) instead of relying on the capture to preserve
  the tail itself. The same pattern existed in the `link`-mode cache-hit
  check (`upgrade_hash_prefix "$(cat "$cache_file")"`) — replaced with the
  new `upgrade_hash_prefix_file`, which hashes a file directly and so has
  no capture step to lose bytes to in the first place.
- **Persist-time re-verification (new in 1.1.2)**: `upgrade_verify_disk_hash`
  re-hashes the actual on-disk bytes (via `upgrade_hash_prefix_file`)
  against `$UPGRADE_TAG_HASH` (now exposed by `upgrade_prepare_candidate`
  alongside `UPGRADE_LATEST`/`UPGRADE_SELECTED_MODE`/
  `UPGRADE_CANDIDATE_CONTENT`, so it doesn't need re-fetching) right before
  each file-touching mode's own commit point: `replacement` re-hashes the
  temp file right before its `mv`; `overwrite` has no temp file to reuse
  (the trial runs `$content` directly via `bash -c`, and its directory
  isn't writable by definition), so `upgrade_write_temp_scratch` writes a
  verify-only copy to a generic `mktemp` location purely to get real bytes
  to re-hash, discarded either way afterward; `link` re-hashes the cache
  file immediately after writing it, since that mode persists *before* its
  trial run rather than after. A mismatch is reported via the existing
  persist-outcome line (`replacement`/`overwrite`, post-trial — `$code`
  unaffected) or as a pre-trial `hash_mismatch` banner note (`link`,
  same as the download-time check). `memory` is exempt — it never persists
  anything. End-to-end re-verified live: a scratch copy downgraded to
  `v1.1.0` and run with `--upgrade-only` against the real `v1.1.1` tag
  applied cleanly with no mismatch reported, and the resulting file came
  out byte-identical to the tag's raw content (confirmed via `diff`),
  trailing newline included — fixing, as a side effect, the fact that
  every self-upgraded file was previously missing its final newline too.
- **Fixed: trial-run hang in `overwrite`/`memory` modes (1.1.4)**: both
  ran the candidate as `bash -c "$content" -- "$@"`, which makes the
  literal string `--` the candidate's `$0`. The candidate's own
  version-detection line near the top of the file (`grep ... "$0"`) then
  received a trailing `--` with no filename after it; GNU grep treats
  that as "end of options" and falls back to reading stdin, which never
  reaches EOF, hanging the whole trial run indefinitely with no output at
  all (confirmed live via `ps`: a `bash -c` process with a `grep` child
  blocked on stdin). Fixed by passing `/dev/null` as `$0` instead of
  `--` — an always-existing, always-empty file, so the grep just finds no
  match and version detection falls through to its existing `unknown`
  fallback, same as it does for any other unreadable path.
- **`--help` grouping (1.1.5)**: the `# Options:` block now labels two
  sub-groups — this script's own container-upgrade flags, and the
  self-upgrade flags (which upgrade the script file itself) — instead of
  one flat list, since both sets used the word "upgrade" for unrelated
  things. Purely a `--help` text change; no flag behavior moved or
  changed. `usage()`'s `sed -n '2,NNNp'` range was adjusted to match the
  header comment's new line count each time it grew (1.1.4's changelog
  entry, then this section's own heading lines).
- **Repo-wide maintenance conventions implemented (1.1.6-dev1)** — see
  `docs/requirements/generic/script-maintenance-convention.md`:
  - **`--help` layering (supersedes 1.1.5's grouping)**: `usage()` no
    longer does one hardcoded `sed -n 'A,Bp'` slice of the whole header.
    The header now carries content-based markers
    (`# HELP:<region>:BEGIN`/`# HELP:<region>:END` around each of IDENTITY,
    INTRO, USAGE, CORE-OPTIONS, UPGRADE-OPTIONS, TAIL,
    UPGRADE-EXPLANATION, OUTPUT), and a new `usage_region()` helper
    extracts one by content via
    `sed -n '/^# HELP:$1:BEGIN$/,/^# HELP:$1:END$/p' "$0" | sed '1d;$d'`.
    `usage()` composes these per variant: bare `--help` (IDENTITY + core
    options), `--help upgrade` (IDENTITY + self-upgrade options only, with
    `UPGRADE-OPTIONS` + `UPGRADE-EXPLANATION`), `--help full` (everything,
    self-upgrade options last) — IDENTITY (the `Version:`/`Category:`/
    `Description:`/`Upgrade-Source:` lines plus the 3-entry changelog
    window) is common to all three, added after the first pass at this
    (which forgot it entirely, so no `--help` variant showed the version
    or changelog at all — caught immediately by re-reading the actual
    output, not just the exit code). This also permanently fixes the
    line-number fragility 1.1.5's note above already flagged — marker
    regions never need updating when unrelated header content changes.
  - **`CHANGELOG.md`**: the complete 1.0.0-1.1.5 history moved to
    `platforms/bash/container-upgrade/CHANGELOG.md`, newest first; the
    script header keeps only its 3 most recent entries, **also newest
    first** (most recent in full, two after it abbreviated) — matching
    `CHANGELOG.md`'s ordering, unlike the old in-script convention which
    appended at the bottom.
  - **Numbered pre-release suffixes**: `upgrade_version_level` now strips
    a trailing revision number before returning the level word (`"dev12"`
    → level `"dev"`); a new `upgrade_version_number` extracts that number.
    `upgrade_version_gt` gained a third comparison tier — level rank, then
    the number itself — used only when `X.Y.Z` is already equal, so
    `1.2.3-dev1 < 1.2.3-dev2`. Applied to the bash blueprint first (per
    the new blueprint-first-then-replicate rule), then to
    `container-upgrade.sh`.
  - **Real bug found and fixed along the way**: `upgrade_parse_versions`
    used to reduce every discovered tag to bare `X.Y.Z` (`v="${r%%-*}"`)
    before it ever reached `upgrade_download`/`upgrade_fetch_tag_hash` —
    both of which build a `v<version>` URL that needs the *exact* tag
    string. Any pre-release tag (e.g. `1.0.8-beta`) would therefore have
    always 404'd on download, pre-dating this session's numbered-suffix
    work entirely. Fixed by keeping the full tag string through
    `upgrade_parse_versions`/`upgrade_highest_at_level` instead of
    stripping it early. Same fix applied to
    `tools/generate-catalog.sh`'s `resolve_version`, which had the
    analogous gap: its same-level tiebreak (`version_num_gt`) compared
    only bare `X.Y.Z`, so e.g. a recorded `-alpha1` could never be
    replaced by `-alpha2` at the same `X.Y.Z`; a new `version_number()` +
    tiebreak closes it (`version_level`'s own glob matching already
    tolerated numbered suffixes, so only the tiebreak was missing).
  - **Second real bug found live**: adopting a numbered suffix
    (`1.1.6-dev1`) immediately broke the script's own `# Version:`
    header-parsing regex (`grep -m1 -E '^# Version: [0-9]+\.[0-9]+\.[0-9]+
    (-[a-z]+)?$'`), which only allowed letters after the dash — every
    invocation silently fell back to `SCRIPT_VERSION="unknown"`, caught
    live via a `bash -n`/smoke-test pass (`container-upgrade vunknown`,
    then an "unbound variable" crash downstream). Fixed by widening the
    suffix group to `(-[a-z]+[0-9]*)?`. Recorded in
    `script-maintenance-convention.md` as an implementation note so the
    next self-upgrading script doesn't repeat it.
- **Third real bug found live, same day**: the header-window reorder (newest
  first, done right after the above) put a `# HELP:IDENTITY:BEGIN` marker
  directly after the shebang, ahead of `Version:`/`Category:`/`Description:`/
  `Upgrade-Source:` — violating
  [[script-header-convention]]'s requirement that those four lines be the
  literal first lines after the shebang, before *any* other header content.
  Caught by the user asking whether the resulting line shift (`Version:`
  moved from line 2 to 3) affected the upgrade mechanism — it didn't (every
  reader uses `grep -m1`/`head -n <budget>`, none hardcode a line number),
  but the marker placement was still wrong per the convention regardless.
  Fixed by moving `HELP:IDENTITY:BEGIN` to start *after* those four lines,
  and adding `usage_header_fields()` — a deliberate, documented exception to
  "no line-number slicing" (`sed -n '2,5p'`), safe specifically because the
  header convention itself pins that block's position, unlike everything
  else marker-based extraction was introduced to stop hardcoding.
- **Changelog consolidation for pre-release cycles (1.1.6-dev2)** — see
  `script-maintenance-convention.md` section 3's new "Stable-only header
  entries; consolidated in-progress entry" subsection: the header's 3-entry
  window now shows **stable versions only**, one entry each. When the
  running version is itself a pre-release, the window's full-detail slot
  is a single consolidated entry for the whole cycle (e.g. `1.1.6 (in
  progress - currently 1.1.6-dev2)`), covering every pre-release bump since
  the last stable release (here, both `1.1.6-dev1` and `-dev2`) rewritten
  as one description — updated in place on each further pre-release bump,
  never adding a second header line. `CHANGELOG.md` is deliberately
  unaffected: every bump, pre-release included, still gets its own entry
  there (confirmed - `1.1.6-dev1` and `1.1.6-dev2` are both present as
  separate entries). Not yet exercised: the promotion-to-stable half of the
  rule (a stable version's `CHANGELOG.md` entry consolidating everything
  since the previous stable release, alongside the pre-release entries
  already there) — no cycle has reached stable since this rule was written,
  so it remains documentation-only until one does.
- **Cooldown-gates-remote-only promotion + permission/ownership
  preservation (1.1.6-dev3)** — see `script-upgrade-convention.md` section
  2's cooldown clarification and section 6's "Permission & ownership
  preservation":
  - **New `upgrade_prepare_cached_candidate`**: a network-free counterpart
    to `upgrade_prepare_candidate`, called only when an implicit invocation
    is cooldown-gated. Reads an already-cached file's own `# Version:` line
    via new `upgrade_file_version`, checks it's actually newer than
    `$SCRIPT_VERSION` and at or above the effective level (same gate as
    section 3, applied locally), then calls `upgrade_select_mode` fresh
    (always network-free, already re-evaluated every run before this
    change too) — only succeeding if that mode has escalated past `link`.
    `upgrade_main`'s cooldown branch now calls this before giving up;
    `$cache_source` (the cache file's path) threads through the
    `replacement`/`overwrite` branches as a signal to read bytes directly
    from that file (`upgrade_write_temp_sibling_from_file`,
    `upgrade_persist_overwrite_from_file` — both `cp`/`cat`-based, no
    `content=$(cat ...)` round-trip through a variable, same pitfall as
    the download path's sentinel-byte fix) instead of the normal
    downloaded-`$content` path. No cooldown timestamp is written on this
    path, since nothing remote was actually checked — the next implicit
    run's schedule is untouched. `--upgrade-check`/`--upgrade-only` are
    unaffected (both are explicit, already bypassing the cooldown
    entirely).
  - **New `upgrade_copy_mode_owner`** (plus `upgrade_stat_mode`/
    `upgrade_stat_owner_group`, GNU-`stat`-first with a BSD/macOS fallback
    verified directly against this machine's real `stat`, same pattern as
    `parse_to_epoch`'s `date -d`/`date -j -f`): `upgrade_write_temp_sibling`
    and its new `_from_file` sibling now copy the original file's mode bits
    and owner:group onto the temp file before the `replacement` `mv`,
    instead of `chmod +x` for the executable bit alone. `overwrite` needed
    no code change — its rewrite never creates a new inode, so it already
    preserved both by construction — but got an explanatory comment plus a
    new `_from_file` variant for the cache-promotion path. Ownership
    (`chown`) is best-effort, matching this convention's existing
    best-effort philosophy elsewhere; mode bits are always applied.
  - **Verified**: unit tests against the extracted self-upgrade function
    block covered `upgrade_stat_mode`/`upgrade_copy_mode_owner` (mode+owner
    copy onto a fresh file), `upgrade_write_temp_sibling`/`_from_file`
    (permission carry-over, byte-exact content), `upgrade_file_version`,
    and `upgrade_prepare_cached_candidate`'s three gates (no cache present,
    mode not actually escalated past `link`, cached version below the
    effective level, and the widened-`--upgrade-level` override) — all
    passing as designed. A full end-to-end run against a disposable copy of
    the real script confirmed the complete scenario this was written for:
    with a recent cooldown timestamp (check would normally be skipped) and
    a newer version already sitting in the `link` cache, the run still
    promoted it straight to `replacement`, ran the trial, persisted it, and
    the resulting live file carried over the original's exact mode (`750`)
    and owner:group — while a matching no-cache control run left the
    original file byte-for-byte untouched, confirming no regression to the
    pre-existing cooldown-skip behavior.
