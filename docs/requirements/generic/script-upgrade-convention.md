# Requirement: Script Self-Upgrade Convention

## Scope
Applies to every script in this repository that opts in by carrying the
`Upgrade-Source:` header line defined below. Builds on
[[script-header-convention]] (identity/version header) and
[[script-versioning-changelog-help-convention]] (the startup banner this
convention extends, and the exit-code rule that upgrade failures don't
affect). The overall algorithm below is language-agnostic; see
"Per-language blueprint" for how each language implements it. Only bash is
implemented today — the PowerShell and Python subsections are forward-looking
sketches to be refined when those platforms get their first script. See also
[[script-maintenance-convention]]: section 1 requires fixes to this
mechanism to land in the blueprint first and then be replicated to every
adopting script; section 4 extends sections 3-4 below with a numbered
pre-release suffix (`-dev1`, `-dev2`, ...) and the ordering rule for it.

## Blueprint (plain-language summary)
1. Unless `--upgrade-type none` (or its `--no-autoupdate` alias) was given,
   the script always attempts to upgrade itself before doing its normal
   work. `--upgrade-check` and `--upgrade-only` are separate, explicit entry
   points that short-circuit this default flow entirely (see 9-10 below).
2. Decide whether to check at all this run: an **implicit** run (none of
   `--upgrade-type`/`--upgrade-level`/`--upgrade-check`/`--upgrade-only`
   given) is gated by a cooldown cache; any **explicit** upgrade-related
   flag always forces a fresh check. This cooldown only gates the *remote*
   half of the process (steps 3-6 below) — the local apply-mode
   determination (step 5) always runs fresh regardless, so a candidate
   already sitting validated in the local cache from an earlier run can
   still be promoted straight to a stronger apply mode on a cooldown-gated
   run whose filesystem eligibility has newly changed (e.g. invoked via
   `sudo` this time) — see section 2. Whether a check happened, and what it
   found, is always surfaced in the startup banner unless self-upgrade is
   disabled outright — see section 10.
3. Discover every matching release tag for *this exact* script (matched by
   language + script name), without requiring `git` on the machine running
   the script, and keep the ones at or above the effective release level
   (`--upgrade-level`, or else the running script's own level).
4. Compare the highest eligible discovered version to the script's own
   `Version:` header; stop here if there's nothing newer.
5. Determine the strongest apply mode actually usable on this filesystem
   (`replacement` → `overwrite` → `link` → `memory`), capped by
   `--upgrade-type` if given. Re-evaluated fresh every run and never itself
   cached, since it depends on the current process's filesystem privileges,
   which can differ run to run (e.g. a plain invocation vs. one via `sudo`).
6. Download the candidate file (skipped entirely for `link` mode when a
   cached copy's hash already matches — see section 7).
7. Validate the download parses cleanly, and, best-effort, that its content
   hash matches the value declared in its release tag's message.
8. Apply it using a **trial-run-then-persist** model: run the candidate to
   do the script's actual work first (skipped for `--upgrade-only`, which
   has no "actual work" to do), and only on that run's success is the
   candidate persisted per the chosen mode (file replace, content
   overwrite, or kept in cache) — see section 6. `replacement`/`overwrite`
   additionally carry over the original file's permissions and ownership
   (ownership best-effort) rather than whatever the write happened to
   produce — see section 6.
9. A failure *before* any candidate is trusted enough to run for real
   (connectivity, HTTP error, parse failure, hash mismatch) abandons the
   upgrade attempt: the script proceeds with the original, already-loaded
   version doing its own real work, and the failure is reported in the
   startup banner. A failure *of the trial run itself* is different and not
   a fallback case at all — see "Failure handling & fallback" below: the
   candidate's own exit code is this invocation's outcome, full stop, since
   its real work already ran. Neither case aborts the run or changes what
   the exit code reflects beyond what the work itself determines (except for
   `--upgrade-check` itself, whose entire purpose is reporting check
   success/failure — see section 11).
10. The outcome is recorded for the cooldown cache on a best-effort basis —
    a failure to write the cache is not itself an upgrade failure.

## Detailed requirement

### 1. Identity & upgrade source (header addition)
A script that supports self-upgrade adds one line to its header, after
`Description:` and before the version history block:

```
# Upgrade-Source: <host>/<owner>/<repo>@<lang>/<script-name>
```

Example (this repo's actual remote,
`https://github.com/jnitecki/scripts.git`):
```
# Upgrade-Source: github.com/jnitecki/scripts@bash/container-upgrade
```

- `<lang>/<script-name>` matches the script's own path under `platforms/`
  (e.g. `platforms/bash/container-upgrade/`) and doubles as the **tag
  prefix** used for version discovery (see below). It is stated explicitly
  rather than inferred from the running script's file path, since a script
  is expected to be deployable standalone, copied out of a full repo
  checkout onto a target machine.
- `v1` of this convention only defines the concrete lookup mechanism for a
  GitHub-style host (REST "matching refs" API + `raw.githubusercontent.com`
  content fetch, both plain HTTPS, no `git` binary required). A different
  host would need an equivalent pair of endpoints; the per-language
  blueprint sections assume GitHub.

### 2. When a check happens
An **implicit** invocation — none of `--upgrade-type`, `--upgrade-level`,
`--upgrade-check`, or `--upgrade-only` present — checks only when:
- The invocation is not `--help`/`-h` only.
- No cached "last checked" timestamp exists, or the cached one is older
  than the cooldown window (proposed default: 20 minutes — a tunable
  value, not a hard requirement of this convention).

An **explicit** invocation — any of those flags present — always checks
fresh, bypassing the cooldown cache, *except* when the net effect is
"upgrading is disabled" (`--upgrade-type none` or `--no-autoupdate`), which
skips the check entirely, the same as today. The cooldown timestamp is
still written (best-effort) after an explicit check, so a later implicit
run benefits from it.

**The cooldown gates remote discovery only, never local apply-mode
eligibility.** Even when the cooldown window above causes an implicit
invocation to skip a fresh remote check, the script still performs the
local, network-free half of section 6 on every single run: determine the
strongest apply mode actually usable on this filesystem right now. If a
previously-cached, already-validated candidate exists (a `link`-mode cache
file per section 7) whose version is still newer than the running script's
own, and this run's freshly-determined mode has escalated beyond what it
was when that candidate was originally cached — e.g. the script is invoked
via `sudo` this time, so `replacement`/`overwrite` are now reachable where
only `link` was before — that candidate is applied via the stronger mode
now, going through the same trial-run-then-persist model (section 8) and
persist-time re-verification (section 6) as any other apply, skipping only
the remote discovery/download steps (sections 3-5) since the content is
already in hand and was already hash-validated when it was cached. A
cooldown-skipped run that finds no such promotable candidate behaves
exactly as before this rule existed: nothing happens, and the banner
reports `upgrade not checked: cooldown active` (section 10). This
eligibility re-check is never itself cached or skipped — the entire point
is to notice a privilege/filesystem change (like a `sudo` re-invocation)
that the cooldown timestamp, which only records *when* discovery last ran,
has no way of knowing about.

### 3. Version & level discovery without `git`
Tags identifying releases of a given script follow the pattern:
```
<lang>/<script-name>/v<X.Y.Z>
```
e.g. `bash/container-upgrade/v1.0.7`, optionally with a pre-release suffix
using the same syntax as the header's `Version:` field
([[script-catalog-generator]]'s `-dev`/`-alpha`/`-beta`/`-rc`), e.g.
`bash/container-upgrade/v1.0.8-beta`. Created automatically by
`tools/git-hooks/post-commit.sh` — see
`docs/requirements/implemented/release-tag-hook.md`.

Matching tags are discovered via one HTTPS GET, no local git repository or
`git` binary needed:
```
GET https://api.github.com/repos/<owner>/<repo>/git/matching-refs/tags/<lang>/<script-name>/v
```
This returns every tag ref whose name starts with that prefix, stable and
pre-release alike.

**Release levels**, lowest to highest: `dev < alpha < beta < rc < stable`
(the same precedence [[script-catalog-generator]] already defines for the
header's own pre-release suffix — this convention doesn't redefine it, to
keep exactly one place that ordering is specified).

The **effective minimum level** for a given invocation is:
- `--upgrade-level <level>` if given, or else
- the level parsed from the running script's own `Version:` suffix (no
  suffix = `stable`).

Every discovered tag is parsed into (version, level); only tags at or above
the effective minimum level are kept as upgrade candidates. This means an
unqualified run of a script currently on a stable version only ever
considers other stable tags — unchanged behavior from a purely
stable-only scheme — while a script currently running a pre-release
considers same-or-higher levels too (e.g. a running beta also accepts
stable, but not alpha or dev, unless `--upgrade-level` explicitly widens
that). The winner among the kept candidates is the highest by numeric
major.minor.patch (not string comparison, so `1.10.0` correctly sorts
after `1.9.0`); level is only a tiebreaker on an equal version number. A
level's own name (`dev`, `alpha`, `beta`, `rc`) is parsed from the suffix
with any trailing revision number stripped first — see
[[script-maintenance-convention]] section 4.

### 4. Version comparison
Highest eligible discovered version (section 3) vs. the script's own
`Version:` header, using numeric major/minor/patch comparison. If the
discovered version is not greater than the local one, the check ends here
(nothing to do). When both are numerically equal, [[script-maintenance-convention]]
section 4 extends this comparison with a level-rank and then a
suffix-revision-number tiebreaker, so that e.g. `1.2.3-dev2` is recognized
as newer than the running `1.2.3-dev1`.

### 5. Download & validation (parse + content hash)
The winning tag's copy of the script is fetched with one more HTTPS GET:
```
GET https://raw.githubusercontent.com/<owner>/<repo>/<lang>/<script-name>/v<X.Y.Z>/platforms/<lang>/<script-name>/<script-name>.<ext>
```
(Skipped entirely for `link` mode when a cached copy already matches the
winning tag's hash — section 7.)

The downloaded content is then validated two independent ways before it is
trusted at all:

- **Syntax parse** — the content must be **syntactically parseable** for
  its language (e.g. `bash -n`, a PowerShell parser call, `compile()` in
  Python — see per-language blueprint). This is a syntax check only, not an
  integrity/authenticity check (see "Accepted risk" below) — it exists
  specifically to satisfy the "script fails parsing" fallback case from
  this convention's requirement.
- **Content-hash match (best-effort)** — if the winning tag's annotation
  message carries a `[<hash>]`-prefixed identity line (per
  [[release-tag-hook]]), the downloaded content's own plain SHA-1, first 12
  hex characters (same algorithm the hook uses), must match it. Fetching
  the tag's message costs two more GETs against GitHub's git database API,
  made only for the winning version, never for every discovered candidate:
  ```
  GET https://api.github.com/repos/<owner>/<repo>/git/refs/tags/<lang>/<script-name>/v<X.Y.Z>
  GET https://api.github.com/repos/<owner>/<repo>/git/tags/<tag-object-sha-from-the-ref-lookup-above>
  ```
  **Not fail-closed**: if either GET fails, the tag's message carries no
  `[<hash>]` prefix at all (e.g. a tag created before this check existed),
  or no local `sha1sum`/`shasum` is available, the check is skipped and the
  upgrade proceeds as if it had passed — an unusable check is treated as an
  optimization that didn't run, the same way the cooldown cache (section
  14) degrades when its storage location isn't writable. Only an actually
  computed mismatch (both sides produced a hash and they differ) counts as
  a failure, handled per section 9 the same way a parse failure is.

**Implementation note — a real bug this convention's own bash reference
implementation shipped with.** Capturing a download via plain
`content=$(curl ...)` looks lossless but isn't: command substitution
unconditionally strips every trailing newline from what it captures.
Since [[release-tag-hook]] computes its declared hash straight off `git
show`'s output — the tagged file's exact bytes, trailing newline included
— a client that captures its download the naive way ends up hashing one
byte fewer than the hook did, and *every* check against *every* tag then
fails with a content-hash mismatch, deterministically, regardless of how
healthy the actual release is (this shipped undetected until a live check
against a real tag surfaced it — the earlier isolated testing that
verified this section's logic used content built into the test itself,
which never round-tripped through a lossy capture). The fix: have the
download function append a single sentinel byte (never legitimately part
of a script's source, e.g. `\x01`) after its real output, so the caller
recovers the byte-exact original with `"${captured%$'\x01'}"` instead of
silently losing the tail to the capture itself. The same pitfall applies
anywhere an already-on-disk file gets re-read through a variable (e.g. a
`link`-mode cache hit, section 7) — hash the file directly there instead
of capturing its content first (see section 6's "Persist-time
re-verification", which does exactly that for a different reason: not
avoiding this pitfall a second time, but verifying the disk write itself).

### 6. Apply modes and the fallback cascade
Four apply modes, strongest to weakest, each gated by a filesystem
precondition:

| Mode | Precondition | What gets persisted |
|---|---|---|
| `replacement` | The script's containing directory is writable. | A same-directory temp file, `mv`'d over the original path. |
| `overwrite` | The directory isn't writable, but the script *file* itself is. | The original file's content, rewritten in place (no temp file possible without directory write access). |
| `link` | Neither the directory nor the file is writable, but the upgrade cache directory (section 7) is writable/creatable. | A copy in the cache directory — the original script path is never touched. |
| `memory` | Always available (no filesystem write of any kind is needed to execute fetched content). | Nothing — never persisted; every future invocation starts from the currently-loaded version again. |

`none` is not an apply mode but the "disabled" sentinel for
`--upgrade-type`/`--no-autoupdate` (section 9). It is not expected to be
reachable as a *detected* outcome, since `memory` has no precondition and
is therefore always available — the enum value exists for completeness
(diagnostic clarity in `--upgrade-check` output) rather than a real
fallback target.

**Selecting a mode**: the cascade starts at `--upgrade-type`'s value if
given, else `replacement`, and steps down through the table above (skipping
`overwrite`/`link` rows whose precondition isn't met) until it finds one
whose precondition holds. `--upgrade-type` acts as a **ceiling**, not a
minimum: e.g. `--upgrade-type link` never escalates to `replacement` or
`overwrite` even when those would in fact be possible on that machine — it
only ever attempts `link`, falling back further to `memory` if even the
cache directory isn't writable.

**Persist-time re-verification.** The content-hash check in section 5 runs
once, against the freshly downloaded bytes, before anything is written
anywhere — it doesn't guarantee those bytes reach disk unchanged (a write
can itself introduce corruption, or, as this convention's own reference
implementation demonstrated in practice, a subtler bug in how the
downloaded bytes were captured in the first place — see section 5's
"Implementation note"). For every apply mode that touches a real file
(`replacement`, `overwrite`, `link` — not `memory`, which never writes
anything), the actual on-disk bytes are hashed again, directly off the
file rather than through a variable (so no capture-related stripping can
skew this second check the same way), and compared against the same
declared hash from section 5, at the point closest to that mode's own
commit:
- `replacement`/`overwrite`: after a successful trial run, immediately
  before the temp-file `mv` / in-place rewrite that makes it live.
  `overwrite`'s scratch copy for this is the same file its trial run
  already wrote to get a real `$0` (section 8's implementation note) —
  written once, before the trial run, and reused here rather than
  rewritten. It can't be written next to the script itself — `overwrite`'s
  whole precondition is that the directory isn't writable — so it goes to
  some other writable location instead.
- `link`: immediately after writing the cache file, before it is ever
  trusted enough to run — this mode persists *before* its trial run
  (section 7), so there's no later "before the `mv`" moment the way there
  is for the other two.

A mismatch here is handled the same as any other outcome reachable at that
stage: for `replacement`/`overwrite` (post-trial), nothing is persisted
and it's reported via the persist-outcome line (section 8) without
changing the invocation's exit code, since the trial's own work already
succeeded; for `link` (pre-trial), it's a pre-trial failure like any other
in section 9 — a `hash_mismatch` banner note, falling back to the
already-loaded version. Like the section 5 check it re-verifies, this is
best-effort: if the expected hash was itself unavailable (section 5's
"not fail-closed" cases) or a scratch copy for `overwrite` couldn't even
be written, there is nothing to compare against and the check is skipped,
not treated as a failure.

**Permission & ownership preservation.** `replacement`'s temp file starts
out owned by whatever user created it, with permissions from the
prevailing umask — neither of which is guaranteed to match the file it's
about to replace (e.g. a script originally installed `root:wheel` mode
`0755`, now being upgraded by a differently-privileged process, or vice
versa). Immediately before the `mv` that makes it live, the temp file's
mode bits and ownership (owner and group) are copied from the original
file's current `stat` output, so the replacement is indistinguishable from
the original in that respect. `overwrite` rewrites the existing file's
content in place and so does not disturb its permissions/ownership by
default, but an implementation that stages the write through any
intermediate copy (e.g. a scratch file, per this section's persist-time
re-verification, whose bytes are then copied back into the original) must
explicitly re-apply the original file's mode/ownership afterward for the
same reason. Ownership changes (`chown`) are best-effort: a process
without sufficient privilege (typically, not running as `root`) cannot
change a file's owner, and failing to do so is not treated as an upgrade
failure — the mode bits, which an unprivileged owner can always set on
their own file, are still applied, and an ownership mismatch left in place
is silently accepted, consistent with this convention's best-effort
philosophy elsewhere (sections 5 and 14).

### 7. The persistent cache (link mode)
`${XDG_CACHE_HOME:-$HOME/.cache}/scripts-upgrade/<lang>/<name>/<name>.<ext>`
holds the most recently cached copy for a given script, used only by `link`
mode. Before downloading, if a cached file already exists there, its
locally-computed content hash is compared to the discovered winning tag's
declared `[<hash>]` (fetched per section 5). On a match, the download and
parse re-check are both skipped entirely — the file was already validated
when it was first cached — and the cached file is used directly. On a
miss (no cached file, a hash that differs, or a winning tag with no hash to
compare against), a normal download proceeds and, on success, the cache
file is (re)written.

A cached file is consulted for more than just this run's own `link`-mode
shortcut: per section 2's cooldown clarification, it also stands as a
ready, already-validated candidate that can be promoted straight to a
stronger mode (`replacement`/`overwrite`) on *any* run — including one
where the cooldown window has suppressed a fresh remote check — whenever
this run's freshly-determined filesystem eligibility (section 6) has
newly escalated past `link`.

### 8. Trial-run-then-persist execution model
Unlike a scheme that persists an upgrade purely on the strength of its
syntax/hash validation, this convention treats a candidate's **first real
invocation** as part of validating it — consistent with this repository's
own container-upgrade philosophy of never committing to a change until
it's proven to work:

- For an **ordinary** (non-`--upgrade-only`) invocation, once a candidate
  has passed section 5's checks (or section 7's cache-hit shortcut), it is
  executed with the run's original arguments to do the script's actual
  work — from the temp file (`replacement`), in memory (`overwrite`,
  `memory`), or from the cache file (`link`). Only if that run exits `0` is
  the candidate persisted (temp file `mv`'d over the original for
  `replacement`; its content written into the original file for
  `overwrite`; the cache file simply kept as-is for `link`, since it was
  already written there before the trial run). If the run fails, nothing is
  persisted and the failure is the run's own — this is not an upgrade
  failure to report in a banner, since the *upgrade itself* (validation)
  succeeded; only the work failed, same as any other failed invocation of
  the script.
- The process handling this candidate's real work is the candidate itself,
  invoked as a genuine child process (or, for `replacement`/`link`, as the
  eventual persisted file, but the *trial* is still a child-process
  invocation, not an in-place `exec`) — so it prints its own startup banner
  (as the new version, with an appropriate note — section 10) and its exit
  code is what the whole invocation reports. The original, already-running
  process never prints its own banner in this path; it has nothing further
  to do once the child's outcome is known.
- For `--upgrade-only`, there is no "actual work" to trial-run (see section
  12) — validated candidates are persisted directly instead.

**Implementation note — two real bugs this convention's own bash reference
implementation shipped with, both from running `overwrite`/`memory`
candidates via `bash -c` with a synthetic `$0` instead of a real file.**
The original approach ran the candidate as `bash -c "$content" -- "$@"`
(later `bash -c "$content" /dev/null "$@"` — see bug 2 below). In `bash -c
command_string [name [args]]`, the first argument after `command_string`
becomes the invoked script's own `$0`.

1. *The hang.* With `--` as `$0`, the candidate script (being a fresh copy
   of the same convention's own header logic) reads its own version off
   `# Version:` via `grep ... "$0"` near the very top of the file, before
   anything is ever printed — which then ran as `grep ... --`. GNU grep
   treats a trailing `--` with no filename after it as "end of options",
   not as a (nonexistent) filename, and falls back to reading stdin
   instead — which never reaches EOF here, hanging the entire trial run
   indefinitely with zero output, before the candidate's own startup
   banner (section 10) or any other line ever prints. This shipped
   undetected because earlier testing invoked candidates directly (a real
   path, not `--`) rather than through this exact `bash -c` form.
2. *The wrong version.* Swapping `--` for `/dev/null` (a real,
   always-empty file) fixed the hang — grep now has an actual filename —
   but broke the *content* of that same version-detection line instead:
   `/dev/null` is real but empty, so `grep ... "$0"` finds no `# Version:`
   line at all and the candidate falls back to reporting itself as version
   `unknown`. This surfaces directly in the startup banner the trial run
   prints for itself (section 10) — e.g. `container-upgrade.sh vunknown
   (self-upgrading from v1.1.6 via overwrite)` — misreporting the very
   version being applied, even though the upgrade itself completes
   correctly (nothing here affects persistence or the hash checks in
   section 6).

**The fix:** don't run the candidate via `bash -c` with a synthetic `$0`
at all — write `$content` to a real scratch temp file first and invoke it
as `bash "$scratch_file" "$@"`. Running bash against an actual file path
sets `$0` to that path automatically, so the candidate's version-detection
`grep` finds both a real file (no hang) and its real content (correct
version) in one step. `overwrite` already needs a scratch copy of the
content for section 6's persist-time hash re-verification — write it once,
before the trial run, and reuse the same file for that check afterward
instead of writing it twice. `memory` has no persist step to reuse a
scratch file for, but must still write one transiently, purely so its
trial run gets a real `$0` — discarded immediately after the trial run
exits, never persisted, consistent with `memory`'s existing "nothing
survives this run" contract.

**Persist-outcome reporting.** The banner note printed before a trial run
(section 10) necessarily describes only what's being *attempted* — it
prints before that run's own outcome is known, and before persistence is
even attempted. A trial run's real work can succeed (exit `0`) while
the persist step itself still fails afterward (e.g. the `mv` for
`replacement`, or the rewrite for `overwrite` — full disk, a permission
change mid-run, etc.). This is a distinct, later outcome that section 9's
pre-trial failure handling does not cover (that section is about failures
*before* a candidate is trusted enough to run at all), so it needs its own
reporting: once a trial run exits `0` and persistence is attempted, whoever
performs that persist step prints one more line — after all of the trial
run's own output, to stderr, never affecting the invocation's exit code
(still the trial run's own, per section 9) — stating whether it succeeded:
```
container-upgrade: upgrade to v1.1.0 applied (replacement)
container-upgrade: upgrade to v1.1.0 failed to persist (replacement): could not rename temp file — will retry next run
```
This line does not apply to every mode: `link` mode persists *before* its
trial run (section 7), so a persist failure there is already reported as a
pre-trial `check_failed` banner note (section 9), not this end-of-run line;
`memory` mode never persists anything by design — its trial-run banner note
already says "this run only", so there is nothing further to report. A
failure to determine or print this line is not itself an upgrade failure,
by the same best-effort principle as the rest of this convention.

### 9. Failure handling & fallback
A failure at the check, download, parse-validation, or content-hash-match
step (section 5) — i.e. before any candidate has been executed for real:
- Must never abort the run or change its exit code — see
  [[script-versioning-changelog-help-convention]] section 5. The one
  exception is `--upgrade-check` itself (section 11), whose purpose is
  reporting exactly this outcome.
- Falls back to the original, already-loaded version of the script
  continuing normally (printing its own banner and doing its own work) —
  this is a genuine fallback, since the candidate was never trusted enough
  to run.
- Must be surfaced in the startup banner (section 10) with which stage
  failed and why (e.g. `network timeout`, `HTTP 404`, `parse error`,
  `content hash mismatch`).

A **trial run that itself fails** (section 8) is handled differently and is
*not* one of the above: by the time a candidate is trial-run, it already
passed every check, so its own real work is this invocation's real work —
there is no fallback re-attempt with the old version (that would mean the
work potentially runs twice, once via each version, within a single
invocation). The candidate's exit code is the invocation's exit code,
exactly as if no upgrade had been attempted and that code had come from the
originally-loaded version failing on its own. Nothing is persisted, so the
next invocation starts fresh from the original version and may attempt the
same candidate (or a newer one) again.

A content-hash check that couldn't be run at all (network failure fetching
it, no `[<hash>]` prefix on the tag, no local hashing tool — section 5) is
*not* a failure by this section's definition; only a successfully computed
mismatch is.

### 10. Startup banner integration
Extends the banner defined in
[[script-versioning-changelog-help-convention]] section 4 — including its
"one line, printed before any real work" rule, which matters here: since a
trial run's own banner necessarily prints *before* that run's outcome
(success or failure) is known, its note must describe what's being
*attempted* this invocation, never assert that persistence has already
happened.

Printed by whichever process ends up doing the script's real work this
invocation:
- The **original** process, when no candidate was ever trusted enough to
  run: the check was skipped this run under the cooldown cache and no
  promotable cached candidate was found either (section 2/14), nothing
  eligible was found once checked, or the check/download/parse/hash-match
  step failed (section 9) — or, with no note at all, when self-upgrade is
  disabled outright (`--upgrade-type none` / `--no-autoupdate`), since
  there's nothing to report in that case.
- The **candidate** itself, once selected and validated, printing its own
  banner (as the new version) before its trial run — regardless of whether
  that run goes on to succeed or fail, since the note only describes what's
  being attempted, not a settled outcome (see section 8's "Persist-outcome
  reporting" for how that settled outcome is reported once known).

Examples:
```
container-upgrade v1.0.7
container-upgrade v1.0.7 (upgrade not checked: cooldown active)
container-upgrade v1.0.7 (no upgrade available)
container-upgrade v1.0.7 (upgrade check failed: could not reach github.com)
container-upgrade v1.0.7 (fetched v1.1.0 failed to parse — running v1.0.7)
container-upgrade v1.0.7 (fetched v1.1.0, content hash mismatch — running v1.0.7)
container-upgrade v1.1.0 (self-upgrading from v1.0.7 via replacement)
container-upgrade v1.1.0 (self-upgrading from v1.0.7 via link, running from cache)
container-upgrade v1.1.0 (self-upgrading from v1.0.7 via memory, this run only)
```
The bare first line (no parenthetical at all) is now reserved for exactly
one case: self-upgrade disabled for this run. Every other reachable outcome
gets a note, so the banner line alone always tells you whether a check
happened and what it found. The last three are printed by the candidate at
its own startup, identically whether its subsequent real-work run succeeds
or fails — see section 8's "Persist-outcome reporting" for the separate
line reporting what happened once that run's own outcome, and the persist
attempt that follows a successful one, are actually known.

### 11. `--upgrade-check`
Discovery only — never downloads, applies, or runs the script's real work.
Reports:
1. What version an upgrade would pick at the effective level (section 3),
   or `No upgrade present` if nothing there is newer than the running
   version.
2. The newest *stable* tag overall, if different from line 1.
3. The newest tag overall, any level including `dev`, if different from
   both lines above.
4. The single strongest apply mode this filesystem actually supports right
   now (section 6's cascade, evaluated from `replacement` regardless of any
   `--upgrade-type` — this is a filesystem capability report, not a
   prediction of what a specific `--upgrade-type` would do).

If discovery itself fails, lines 1-3 are replaced by `upgrade check failed:
<reason>`; line 4 (a pure local filesystem check, independent of network)
still prints regardless. Not combinable with `--upgrade-type` or
`--upgrade-only`; combinable with `--upgrade-level` (it changes what line 1
reports). Exits non-zero only when the check itself failed to run;
otherwise `0` regardless of whether an upgrade was found.

### 12. `--upgrade-only`
Performs the check and, if an eligible upgrade exists, the actual upgrade
(honoring `--upgrade-type`/`--upgrade-level` the same as an ordinary run),
then exits — it never runs the script's normal work, so section 8's trial
run doesn't apply here: a validated candidate is persisted directly
(temp file `mv` for `replacement`; direct content rewrite for `overwrite`;
write-to-cache for `link`). For a `memory`-only environment, there is
nothing `--upgrade-only` can persist at all; it reports that plainly
(validated successfully but nothing was kept — the next invocation starts
from scratch again) rather than implying something was saved. Not
combinable with `--upgrade-check`.

### 13. CLI flags reference
Documented in `--help` per the existing convention's requirement that every
flag and its default appear there:
- `--upgrade-type <replacement|overwrite|link|memory|none>` — caps which
  apply mode is attempted (section 6); `none` disables self-upgrade
  entirely. Default: unset (full cascade from `replacement`). Rejects an
  unrecognized value immediately with a clear error. Not combinable with
  `--upgrade-check`, nor with `--no-autoupdate`.
- `--upgrade-level <dev|alpha|beta|rc|stable>` — the minimum release level
  eligible for upgrade (section 3). Default: unset (the running script's
  own level). Rejects an unrecognized value immediately with a clear error.
- `--upgrade-check` — see section 11.
- `--upgrade-only` — see section 12.
- `--no-autoupdate` — shortcut/alias for `--upgrade-type none`. Not
  combinable with `--upgrade-type`.

### 14. Cooldown cache
Best-effort, per script, stored outside the script's own (possibly
read-only) directory — e.g.
`${XDG_CACHE_HOME:-$HOME/.cache}/scripts-upgrade/<lang>_<name>.state` on
Linux/macOS, an equivalent per-user location on Windows for PowerShell.
Holds only the last-checked timestamp. Only gates an **implicit**
invocation's *remote* check (section 2) — any explicit upgrade-related
flag always forces a fresh check, and even an implicit, cooldown-gated
invocation still re-evaluates local apply-mode eligibility every time and
may promote an already-cached candidate to a stronger mode on that basis
(section 2). If the cache location isn't writable, the check simply runs
every time instead of failing — the cache is an optimization, not a
correctness requirement.

### 15. Code organization (demarcation)
Because a full implementation of this convention is sizable relative to
most scripts' own domain logic, an adopting script must keep it clearly set
apart rather than interleaved throughout the file:
- Every upgrade-related function lives in one contiguous block, placed last
  among the script's function definitions (immediately before its
  `usage()`/argument-parsing/top-level invocation code), bounded by a clear
  banner comment marking where it begins and ends.
- Within the script's top-level flow — argument parsing, the
  `--upgrade-check`/`--upgrade-only` early-exit branches, and the ordinary
  upgrade-attempt call before the script's real work — every call site that
  belongs to the upgrade subsystem carries an inline marker comment (e.g.
  `# --- self-upgrade ---`) so it reads as clearly separate from the
  script's actual domain logic, even where the two are necessarily
  interleaved (argument parsing happens once, for both).

## Per-language blueprint
Concrete, copy/adapt-from reference implementations live under
`tools/blueprints/`, one file per platform, named `<platform>.<ext>` (the
platform's own native extension). They are not sourced by deployed scripts
at runtime (scripts stay self-contained single files, per section 1) — a
script adopting self-upgrade copies the relevant functions in and
substitutes its own identity values.

- **Bash** — [tools/blueprints/bash.sh](../../../tools/blueprints/bash.sh).
  Implemented against a real, cataloged script's constraints (bash 3.2
  safety, no `sort -V`, no `jq` dependency) since bash is the only platform
  in use today.
- **PowerShell (sketch)** —
  [tools/blueprints/powershell.ps1](../../../tools/blueprints/powershell.ps1).
  No PowerShell script exists in this repo yet, so treat this as a starting
  point to refine once one does, not a tested implementation — it has not
  been updated for this convention's apply-mode/level/cache rework; use the
  bash blueprint as the current reference in the meantime.
- **Python (sketch)** —
  [tools/blueprints/python.py](../../../tools/blueprints/python.py). Same
  caveats as PowerShell.

Each file covers: should-check gating (§2), level-aware tag discovery and
version comparison (§3-4), download and validation — parse plus
best-effort content-hash match (§5), the apply-mode cascade and persistent
cache (§6-7), the trial-run-then-persist execution model (§8), and the
startup-banner note text (§10). The cooldown cache (§14) and CLI flags
(§13) are sketched as comments in the bash file's orchestration section
rather than duplicated as code in all three, since flag-parsing conventions
are otherwise unrelated to self-upgrade.

## Accepted risk (checksum verification narrowed in scope, not eliminated)
Section 5's content-hash check catches download corruption, a stale
`raw.githubusercontent.com` CDN edge serving content that doesn't match the
tag, or a hook/tag desync bug — real, if narrow, failure modes worth
catching before an unmatching file is applied or executed. The same trust
model covers `link` mode's cache-hash reuse shortcut (section 7): a cache
hit is trusted because it was itself validated (parsed and hash-checked)
the first time it was written, not because caching adds any independent
guarantee.

It does **not** amount to signature verification and does **not** protect
against a compromised repository or tag: the hash (in the tag's annotation
message) and the script content (in the tag's tree) both come from the same
source, so an attacker — or a compromised hosting provider — able to alter
the tagged script is equally able to alter the hash alongside it. What
remains explicitly accepted as out of scope: a compromised tag/repo, or a
hosting-provider compromise. If that risk profile changes later, an
independently-sourced signature (not derived from the same repo/tag as the
content it covers) would be the next step here — the parse-validation step
(section 5) is unrelated and stays either way, since it exists to satisfy
the "fails parsing → fall back" requirement, not for security.

## Rejected alternatives
- **Separate release/manifest feed** (a JSON/text file listing latest
  version + URL, hosted independently of the repo): rejected in favor of
  git-tag-based discovery so there's no second system to keep in sync with
  the repo's actual releases.
- **Relying on a local `git` checkout/binary** to discover tags or fetch
  file contents: rejected because a deployed script is expected to run
  standalone on a target machine that may not have `git` installed or a
  full repo checkout present — only plain HTTPS is assumed.
- **Persisting an upgrade purely on parse/hash validation, then re-`exec`ing
  it** (the original design of this convention, before this rework):
  rejected in favor of the trial-run-then-persist model (section 8) — a
  candidate that parses fine and matches its declared hash can still fail
  at runtime (a bad release), and this repository's own container-upgrade
  philosophy is to never commit to a change unproven by an actual
  successful run.
- **`--upgrade-type` as a floor instead of a ceiling** (escalating to a
  stronger mode than requested when available): rejected — an explicit
  `--upgrade-type` is a deliberate choice (e.g. "never touch the original
  file, only ever use the cache"), and silently doing something stronger
  than asked would violate that intent.
- **A dedicated `--force-update-check` flag**: dropped once
  `--upgrade-check`/`--upgrade-only` existed as genuine on-demand,
  cooldown-bypassing entry points — the remaining case
  `--force-update-check` alone would have covered (force a fresh check but
  still do the script's normal work afterward) is already covered by any
  other explicit upgrade flag forcing a fresh check per section 2.

## Rationale
Lets every script stay current without a separate distribution/update
channel to maintain, degrades safely (original version keeps running) on
any failure instead of breaking the actual task the script was invoked to
do, and never leaves a partially-written script file on disk. The
trial-run-then-persist model and the four-mode cascade extend that same
safety principle to environments this convention didn't originally cover
(no write access anywhere but a user cache directory) and to the moment an
upgrade is actually exercised for the first time, not just its
download/validation.
