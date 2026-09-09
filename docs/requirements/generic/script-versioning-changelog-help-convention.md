# Requirement: Script Versioning, In-Script Changelog, Help, and Exit Code Convention

## Scope
Applies to every script in this repository, regardless of scripting/programming
language or the platform/category directory it lives under. Builds on
[[script-header-convention]] (the `Version:`/`Category:`/`Description:` header
fields). See also [[script-autoupdate-convention]], which extends the startup
banner defined in section 4 below with an update-check outcome note.

## Requirement

### 1. Version bumping
- The `Version:` field in the script's header must be bumped at least at the
  patch level (the `Z` in `X.Y.Z`) on every functional change to the script.
- The version must live in exactly one place: the header's `Version:` line.
  Anywhere the script needs its own version at runtime (startup log line,
  `--version` output, etc.), it must read that value programmatically from
  the header itself rather than duplicating it in a separate constant or
  variable, so the two can never drift out of sync.

### 2. In-script version history / changelog
- Every script's header must include a version history section immediately
  following the `Version:`/`Category:`/`Description:` block, with one entry
  per version bump.
- Each entry records the version number and a concise description of what
  changed in that version.
- Entries are append-only: past entries are never rewritten or removed,
  newest entry at the bottom.
- This changelog lives inside the script itself, not in a separate
  `CHANGELOG.md`, so a script's history always travels with the file.

### 3. `--help` / usage implementation
- Every script must support a help invocation (`-h`/`--help`, or the
  idiomatic equivalent for that language/platform) that prints usage
  documentation.
- The usage text must be sourced directly from the script's own header/doc
  comment block (e.g. by slicing the script's own source, or referencing an
  inline doc string used for nothing else) rather than duplicated in a
  separate string literal, so the two can't drift out of sync.
- The header documentation shown by `--help` must cover: what the script
  does, requirements/dependencies, every option/flag with its default, any
  positional arguments, and a description of the script's output and
  exit-code behavior.
- Unrecognized options must be rejected immediately with a clear error,
  never silently ignored or misinterpreted as a positional argument.

### 4. Startup version banner
- Every normal (non-`--help`) invocation must print one line identifying the
  script and its version before doing any real work, e.g.:
  ```
  container-upgrade v1.0.7
  ```
- Sourced from the same header `Version:` line as `--help` and the changelog
  — never a separately maintained string (same rule as section 1).
- Printed to stderr, so it never contaminates stdout output that might be
  parsed or piped by a caller.
- `--help` shows the version as part of its usage text and does not need to
  print this separate banner line, since the invocation exits immediately
  afterward without doing any real work.
- A script that implements [[script-autoupdate-convention]] appends an
  update-check outcome note to this same line when relevant (update applied,
  update fetched but run standalone this invocation, or the check itself
  failed) — see that doc for the exact note formats.

### 5. Exit codes
- The script's exit code must reflect whether the run completed cleanly:
  `0` if no errors occurred, non-zero if any did. "The process reached the
  end" is not sufficient on its own to justify exit code `0`.
- A failed or skipped autoupdate check (see [[script-autoupdate-convention]])
  never counts as an error for this purpose — exit code reflects only the
  outcome of the script's actual functional work.

## Rationale
Generalizes the conventions established in `container-upgrade.sh` so every
future script in this repository is self-documenting, diagnosable without
external docs, and consistent regardless of author or language: version and
history are always where you'd look for them (the file itself), `--help`
always reflects reality because it's the same text as the header, and a
non-zero exit code is always a reliable signal that something needs review.
