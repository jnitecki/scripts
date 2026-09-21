# Self-upgrade implementation notes

Tracks how `container-upgrader.sh`'s self-upgrade mechanism is actually
implemented, kept in sync with the code. If a feature or its code is
removed, remove its section here too. This file covers only what's
specific to this script; the generic, cross-cutting convention it
implements lives in `docs/requirements/generic/` at the repo root (see
`docs/CONTEXT.md`'s "Per-script documentation" section for the split).

Requirement: `docs/requirements/generic/script-upgrade-convention.md`.
Blueprint followed: `tools/blueprints/bash.sh` (both renamed from their
`autoupdate`/`update` predecessors in the same rework). Identity:
`Upgrade-Source: github.com/jnitecki/scripts@bash/container-upgrader`.

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
  resolve to `${XDG_CACHE_HOME:-$HOME/.cache}/scripts-upgrade/bash/container-upgrader/container-upgrader.sh`.
  `upgrade_prepare_candidate` checks a cache hit's hash against the
  winning tag's declared hash before deciding whether to download at all.
- **Download validation**: `bash -n` against the fetched content via
  process substitution (syntax-only), then, best-effort, a content-hash
  match against the winning tag's own `[<hash>]`-prefixed message (see
  [release-tag-hook.md](../../../../docs/requirements/implemented/release-tag-hook.md)) —
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
- **Cooldown cache**: `${XDG_CACHE_HOME:-$HOME/.cache}/scripts-upgrade/bash_container-upgrader.state`,
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
  fallback, same as it does for any other unreadable path. **Superseded in
  1.1.6-dev7**: that `unknown`-fallback side effect turned out to be a real
  bug of its own, not a harmless edge case — every `overwrite`/`memory`
  trial run's startup banner reported itself as `vunknown` instead of the
  actual candidate version. Fixed by writing the candidate to a real
  scratch temp file and running `bash "$scratch_file" "$@"` instead of
  `bash -c "$content" /dev/null "$@"`, giving the candidate a genuine `$0`
  with genuine content — see
  `docs/requirements/generic/script-upgrade-convention.md` section 8's
  implementation note and `platforms/bash/container-upgrader/CHANGELOG.md`'s
  `1.1.6-dev7` entry.
- **`--help` grouping (1.1.5)**: the `# Options:` block now labels two
  sub-groups — this script's own container-upgrader flags, and the
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
    `platforms/bash/container-upgrader/CHANGELOG.md`, newest first; the
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
    `container-upgrader.sh`.
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
- **Run summary log (1.1.8-dev1)** — see
  `docs/requirements/implemented/run-summary-log.md`: `write_run_state_log()`
  (defined right where it's called, in the Report section, same local-helper
  pattern as `status_label()`) appends one `jq`-built JSON-lines entry to
  `STATE_LOG_FILE` (`${XDG_STATE_HOME:-$HOME/.local/state}/scripts-state/
  bash_container-upgrader.log` — a script-level constant defined alongside
  the self-upgrade identity constants, but explicitly not part of that
  block: `XDG_STATE_HOME`, not `XDG_CACHE_HOME`, since this is a meaningful
  record rather than disposable cache), then trims the file to its most
  recent `STATE_LOG_MAX_ENTRIES` (50) lines via `tail`. Called once, right
  after the existing `count_*` summary tally loop computes everything it
  needs — naturally skipped by `--dry-run` (which `exit`s before that tally
  even runs) and by `--upgrade-check`/`--upgrade-only` (which exit before
  any container work). The five logged counts map onto the existing
  `RESULT` outcome tally with no new per-container classification needed:
  `containers_updated_successfully` sums `count_upgraded`/`count_recovered`/
  `count_upgraded_externally`/`count_upgraded_via_quadlet`/
  `count_upgraded_via_manual_unit`; `containers_update_failed` sums
  `count_rolled_back_working`/`count_now_failing`/`count_still_failing`/
  `count_reconstruct_failed`/`count_reverted_externally`/
  `count_external_config_discrepancy`; `containers_not_uptodate` sums
  `count_pull_failed`/the three `count_systemd_unit_*`/
  `count_skipped_crashing` — together an exact partition of all 17 `RESULT`
  values (the remainder, containers never attempted because already current,
  plus `restarted`, are correctly uncounted). `images_updated_successfully`
  reuses `${#IMAGES_UPGRADED[@]}`; `images_update_failed` is a new
  `IMAGES_PULL_FAILED_COUNT` counter incremented alongside the existing
  `PULL_FAILED_IMAGE` map-set in the per-image pull loop. Every step
  (`mkdir -p`, the `jq` build, the append, the `mktemp`+trim+`mv`) is
  best-effort — a failure anywhere just `return 0`s, matching the
  self-upgrade cooldown cache's own philosophy elsewhere in this script;
  `HAD_ERRORS`/the exit code are never affected.
  **Tested**: `tests/test-container-upgrader.sh` extracts the function's
  exact source from the real script file (`sed` between its definition and
  closing brace, then `eval`) rather than stubbing `docker`/`podman` through
  the whole container lifecycle just to reach the report phase — a
  deliberate, narrower exception to `interface-configurator`'s fully
  black-box convention, justified because this function's only real
  dependency is `jq`. Covers: correct JSON shape/field values, ISO-8601
  `Z`-suffixed `date`, multi-run append ordering, trimming to
  `STATE_LOG_MAX_ENTRIES` (keeps the most recent, drops the oldest), and
  best-effort behavior when the target directory can't be created. Passing
  under both a modern `bash` and macOS's bundled `bash` 3.2.
- **Login status banner (1.1.8-dev2)** — see
  `docs/requirements/implemented/login-status-banner.md`: `status_main`,
  `register_banner_main`, `unregister_banner_main`, and `resolve_script_path`
  live in their own `# === Login banner ... begins/ends ===` block, defined
  right after `usage()` and before the argument-parsing loop (the same
  "functions must be defined, i.e. that line already executed, before
  they're called" reason `parse_to_epoch` moved next to them - see the bug
  below). Dispatched from the top-level flow the same way as
  `--upgrade-check`/`--upgrade-only`: parsed, combination-validated (new
  block rejecting `--status`/`--register-banner`/`--unregister-banner`
  combined with each other or with `--upgrade-check`/`--upgrade-only`),
  then dispatched *before* `upgrade_main` and before engine auto-detect/the
  `jq`-for-engine check - `--status` in particular must work with neither
  docker/podman nor a network reachable, since it's meant to run
  unattended on every login.
  - `status_main`: `command -v jq` gate, then reads `STATE_LOG_FILE`'s last
    line (`tail -n1`), validates it's real JSON (`jq -e .`), sums
    `containers_not_uptodate + containers_update_failed` for the
    "awaiting upgrade" line, otherwise diffs `parse_to_epoch` of the
    entry's `date` against `date -u +%s` for the staleness line against
    `STATUS_STALE_DAYS`. Every failure path (`jq` missing, no log, bad
    JSON, unparseable date) is a silent `exit 0` - never stderr noise, never
    a non-zero exit, since this is meant to run unattended on every login.
  - `resolve_script_path`: `cd "$(dirname "$SCRIPT_PATH")" && pwd` +
    `basename` - the generated MOTD script needs an absolute path since it
    runs from an unknown CWD at login time; shares the pre-existing
    assumption that `$0`/`SCRIPT_PATH` is a real path (not a bare
    PATH-looked-up command name), same as the self-upgrade subsystem
    already assumes elsewhere.
  - `register_banner_main`: `$EUID -eq 0` gate, target user
    `${SUDO_USER:-$(id -un)}`, writes `${MOTD_DIR}/${MOTD_SCRIPT_NAME}`
    (`/etc/update-motd.d/92-container-upgrader`) with the `MOTD_MARKER`
    comment plus a `su - <user> -c '<path> --status'` line - both the
    username and the `<path> --status` command string go through
    `printf '%q'`, so either containing spaces/shell metacharacters can't
    break the generated script. Verified live (see below) that `printf
    '%q'`'s backslash-escaped-space form for the combined `<path>
    --status` string is parsed by bash as a single argument to `-c`,
    exactly what `su -c` expects (one command-line string, which `su`
    itself then splits) - confirmed via a plain argv-printing script
    rather than assuming it.
  - `--status-stale-days` handling (1.1.8-dev3): the parse case also sets
    `STATUS_STALE_DAYS_EXPLICIT=true` (same pattern as `ENGINE_EXPLICIT`),
    and the login-banner combination-validation block rejects an explicit
    value unless `STATUS` or `REGISTER_BANNER` is set. `register_banner_main`
    appends ` --status-stale-days $STATUS_STALE_DAYS` to the command string
    it embeds in the generated MOTD script when the flag was explicit, before
    the `printf '%q'` quoting. Covered by unit tests (generated line with and
    without the flag) and live checks of the combination errors.
  - `unregister_banner_main`: no-ops cleanly if the file doesn't exist;
    refuses to remove it (error, exit 1) if it exists but lacks
    `MOTD_MARKER` (`grep -qF`), so it can never delete a file it didn't
    generate itself.
  - **Real bug found live**: `status_main` calls `parse_to_epoch`
    (previously defined much later in the file, alongside the other
    container-inspection helpers it was originally added for). Since a
    bash function must be *defined* - its `name() { ... }` line actually
    executed - before it's called, not merely appear later in the file,
    and `status_main` is dispatched earlier in the top-level flow than
    that definition was reached, every call silently failed ("command not
    found", swallowed by the existing `2>/dev/null`), so `--status` never
    printed the "last upgraded N days ago" line at all - caught by live
    testing across all five `--status` scenarios (no log, awaiting-upgrade,
    stale, fresh, custom `--status-stale-days`), not by the unit tests
    alone. Fixed by relocating `parse_to_epoch`'s definition to right
    before `status_main`; its original caller
    (`check_recent_restart_or_stuck`, defined much later) is unaffected,
    since bash functions only need to be defined before they're *called*,
    not textually near their call site.
  - **Verified live**: all three flags exercised directly (not just unit
    tests) - `--status` across all five scenarios above (including on
    both a fresh macOS/BSD `date` and confirming `parse_to_epoch`'s
    GNU-then-BSD fallback actually parses this log's exact
    `date -u '+%Y-%m-%dT%H:%M:%SZ'` format correctly on this machine);
    `--register-banner`/`--unregister-banner` against a sandboxed
    `MOTD_DIR` (real `/etc/update-motd.d/` requires root and isn't
    something this session can safely touch) with the `$EUID` check
    patched for the test only - covering the non-root refusal, a
    successful register (correct generated content, target user, `chmod
    755`), unregister removing it, unregister no-op when already absent,
    and unregister refusing to delete a file without `MOTD_MARKER`.
