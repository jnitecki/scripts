# Requirement: Script Self-Update (Autoupdate) Convention

## Scope
Applies to every script in this repository that opts in by carrying the
`Update-Source:` header line defined below. Builds on
[[script-header-convention]] (identity/version header) and
[[script-versioning-changelog-help-convention]] (the startup banner this
convention extends, and the exit-code rule that autoupdate failures don't
affect). The overall algorithm below is language-agnostic; see
"Per-language blueprint" for how each language implements it. Only bash is
implemented today — the PowerShell and Python subsections are forward-looking
sketches to be refined when those platforms get their first script.

## Blueprint (plain-language summary)
1. Decide whether to check at all this run (skip for `--help`; skip if
   disabled; skip if the last check is still within the cooldown window).
2. Discover the latest available version of *this exact* script (matched by
   language + script name) from its update source, without requiring `git`
   to be installed on the machine running the script.
3. Compare the discovered version to the script's own `Version:` header;
   stop here if there's nothing newer.
4. Download the candidate file.
5. Validate the download parses cleanly as a script in this language.
6. Apply it: prefer replacing the on-disk file atomically in place; if that
   isn't possible (e.g. read-only install location), run the fetched
   version for this invocation only — in memory where the language safely
   allows it, otherwise from a temp file — leaving the on-disk file
   untouched.
7. Any failure at steps 2-5 (connectivity, HTTP error, parse failure)
   abandons the update attempt: the script proceeds with the original,
   already-loaded version, and the failure is reported in the startup
   banner. It never aborts the run and never affects the exit code.
8. The outcome is recorded for the cooldown cache on a best-effort basis —
   a failure to write the cache is not itself an update failure.

## Detailed requirement

### 1. Identity & update source (header addition)
A script that supports autoupdate adds one line to its header, after
`Description:` and before the version history block:

```
# Update-Source: <host>/<owner>/<repo>@<lang>/<script-name>
```

Example (this repo's actual remote,
`https://github.com/jnitecki/scripts.git`):
```
# Update-Source: github.com/jnitecki/scripts@bash/container-upgrade
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
A check is skipped (script just runs, unmodified) when any of:
- The invocation is `--help`/`-h` only.
- `--no-autoupdate` was passed (see section 9).
- A cached "last checked" timestamp exists and is within the cooldown
  window (proposed default: 24h — a tunable value, not a hard requirement of
  this convention) and `--force-update-check` was not passed.

### 3. Version discovery without `git`
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
pre-release alike. **By default, discovery considers only stable tags (no
suffix)** when determining "the latest available version" — pre-release
tags exist on the remote (so something can deliberately track them) but
are excluded from the default comparison. Whether a given script's
autoupdate implementation opts in to also considering pre-release tags
(and by what means — a flag, a config value) is a decision left to that
consuming script/blueprint; this convention doesn't mandate it either way.
The version suffix of each considered tag is parsed and compared
numerically (major.minor.patch — not as strings, so `1.10.0` correctly
sorts after `1.9.0`) to find the highest.

### 4. Version comparison
Highest discovered version (stable-only by default, per section 3) vs. the
script's own `Version:` header, using numeric major/minor/patch comparison.
If the discovered version is not greater than the local one, the check ends
here (nothing to do). An implementation that opts in to considering
pre-release tags must additionally apply the precedence rules
[[script-catalog-generator]] already defines for the header's own
pre-release suffix (`dev < alpha < beta < rc < stable`) — this convention
doesn't redefine them, to keep exactly one place that ordering is
specified.

### 5. Download & parse validation
The winning tag's copy of the script is fetched with one more HTTPS GET:
```
GET https://raw.githubusercontent.com/<owner>/<repo>/<lang>/<script-name>/v<X.Y.Z>/platforms/<lang>/<script-name>/<script-name>.<ext>
```
The downloaded content is then validated as **syntactically parseable** for
its language (e.g. `bash -n`, a PowerShell parser call, `compile()` in
Python — see per-language blueprint) before it is trusted at all. This is a
syntax check only, not an integrity/authenticity check (see "Accepted risk"
below) — it exists specifically to satisfy the "script fails parsing" fallback
case from this convention's requirement.

### 6. Apply: in place vs. temp/memory
- **Preferred: update in place.** Write the validated new content to a temp
  file in the same directory as the script, then atomically rename it over
  the original. On success, re-exec the script with its original arguments
  (bash `exec "$0" "$@"`, PowerShell relaunch, Python `os.execv`) so this
  same invocation also benefits immediately, rather than only the next run.
- **If in-place update isn't possible** (write permission denied, read-only
  filesystem, etc.): run the fetched version for **this invocation only**,
  original arguments forwarded, without persisting anything:
  - Prefer executing it **in memory** where the language supports that
    safely (see per-language blueprint) — no temp file touches disk at all.
  - Otherwise, write it to a securely-created temp file, execute it, and
    remove the temp file afterward (cleanup runs even on failure).
  - Either way this affects only the current run; every future invocation
    repeats the same check until whatever blocked the in-place write is
    fixed.

### 7. Failure handling & fallback
A failure at the check, download, or parse-validation step:
- Must never abort the run or change its exit code — see
  [[script-versioning-changelog-help-convention]] section 5.
- Falls back to the original, already-loaded version of the script
  continuing normally.
- Must be surfaced in the startup banner (section 8) with which stage
  failed and why (e.g. `network timeout`, `HTTP 404`, `parse error`).

### 8. Startup banner integration
Extends the banner defined in
[[script-versioning-changelog-help-convention]] section 4. Examples:
```
container-upgrade v1.0.7
container-upgrade v1.0.7 (update check failed: could not reach github.com)
container-upgrade v1.0.9 (updated in place from v1.0.7)
container-upgrade v1.0.7 (fetched v1.0.9, running from memory this run only — could not update in place: Permission denied)
container-upgrade v1.0.7 (fetched v1.0.9 failed to parse — running v1.0.7)
```

### 9. New CLI flags
Documented in `--help` per the existing convention's requirement that every
flag and its default appear there:
- `--no-autoupdate` — skip the update check entirely for this run.
- `--force-update-check` — ignore the cooldown cache and check now.

### 10. Cooldown cache
Best-effort, per script, stored outside the script's own (possibly
read-only) directory — e.g. `${XDG_CACHE_HOME:-$HOME/.cache}/scripts-autoupdate/`
on Linux/macOS, an equivalent per-user location on Windows for PowerShell.
Holds the last-checked timestamp and outcome. If the cache location isn't
writable, the check simply runs every time instead of failing — the cache is
an optimization, not a correctness requirement.

## Per-language blueprint
Concrete, copy/adapt-from reference implementations of sections 2-8 live
under `tools/blueprints/`, one file per platform, named `<platform>.<ext>`
(the platform's own native extension). They are not sourced by deployed
scripts at runtime (scripts stay self-contained single files, per section
1) — a script adopting autoupdate copies the relevant functions in and
substitutes its own identity values.

- **Bash** — [tools/blueprints/bash.sh](../../../tools/blueprints/bash.sh).
  Implemented against a real, cataloged script's constraints (bash 3.2
  safety, no `sort -V`, no `jq` dependency) since bash is the only platform
  in use today.
- **PowerShell (sketch)** —
  [tools/blueprints/powershell.ps1](../../../tools/blueprints/powershell.ps1).
  No PowerShell script exists in this repo yet, so treat this as a starting
  point to refine once one does, not a tested implementation.
- **Python (sketch)** —
  [tools/blueprints/python.py](../../../tools/blueprints/python.py). Same
  caveat as PowerShell — no Python script exists in this repo yet.

Each file covers: should-check gating (§2), tag discovery and version
comparison (§3-4), download and parse-only validation (§5), in-place apply
with re-exec vs. memory execution (§6), and the startup-banner note text
(§8). The cooldown cache (§10) and CLI flags (§9) are sketched as comments
in the bash file's orchestration section rather than duplicated as code in
all three, since flag-parsing conventions are otherwise unrelated to
autoupdate.

## Accepted risk (checksum/signature verification intentionally omitted)
This convention deliberately does **not** require checksum or signature
verification of downloaded content before it is applied or executed. The
update source is the same repository the script itself was originally
sourced from, fetched over TLS (integrity/authenticity of transport, and of
"this is what the tag actually contains," are already covered by HTTPS +
the hosting provider). What is explicitly accepted as out of scope: a
compromised tag/repo, or a hosting-provider compromise. If that risk profile
changes later, add a signature/checksum step here — the parse-validation
step (section 5) is unrelated and stays either way, since it exists to
satisfy the "fails parsing → fall back" requirement, not for security.

## Rejected alternatives
- **Separate release/manifest feed** (a JSON/text file listing latest
  version + URL, hosted independently of the repo): rejected in favor of
  git-tag-based discovery so there's no second system to keep in sync with
  the repo's actual releases.
- **Relying on a local `git` checkout/binary** to discover tags or fetch
  file contents: rejected because a deployed script is expected to run
  standalone on a target machine that may not have `git` installed or a
  full repo checkout present — only plain HTTPS is assumed.

## Open follow-up items (not defined by this doc)
- The exact default cooldown interval (proposed: 24h) and its override
  mechanism (flag vs. env var) are proposed defaults, not settled.
- Whether a plain `--version` flag (local header only, no network check) is
  added alongside `--help` is undecided — not currently required by
  [[script-versioning-changelog-help-convention]].

## Rationale
Lets every script stay current without a separate distribution/update
channel to maintain, degrades safely (original version keeps running) on any
failure instead of breaking the actual task the script was invoked to do,
and never leaves a partially-written script file on disk (atomic in-place
replace, or no disk write at all when falling back to memory/temp
execution).
