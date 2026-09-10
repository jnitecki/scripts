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
