# Requirement: Cross-Platform Shell Script Compatibility (Linux + macOS)

## Scope
Applies to every shell script (bash/sh) in this repository. Does not apply
to scripts written in other languages (PowerShell, Perl, Python, etc.),
which have their own, separate portability concerns.

## Requirement
Every shell script must run correctly on both Linux and macOS. The two
platforms differ in ways that silently break naive bash scripts:

### 1. Bash version
- macOS ships bash 3.2 as `/bin/bash` (Apple has not updated it since,
  because 3.2 is the last GPLv2 release; later bash is GPLv3). Linux
  distributions typically ship bash 4+ or 5 (GNU coreutils/GPLv3).
- A script's `#!/usr/bin/env bash` shebang resolves to whichever `bash` is
  first on `PATH` at run time - on a given macOS machine that may be the
  ancient system 3.2, or a newer Homebrew-installed bash, depending on that
  machine's setup. **Do not assume bash 4+.**
- Do not use bash 4+-only features unless the script explicitly requires
  and checks for them: associative arrays (`declare -A`), `mapfile`/
  `readarray`, `${var,,}`/`${var^^}` case conversion, `&>>`, etc.
- If a script genuinely cannot avoid a bash 4+ feature, it must fail fast
  with a clear error naming the requirement, rather than fail deep inside
  the script with a cryptic syntax error. See `tools/generate-catalog.sh`'s
  `[ -z "${BASH_VERSION:-}" ]` guard for the "requires bash at all" pattern;
  the same style (check and exit with a clear message) applies to a bash
  4+ requirement, e.g. checking `${BASH_VERSINFO[0]}`.
- Prefer the portable option instead of the version-guard option whenever
  the portable form isn't meaningfully more complex - see
  `tools/generate-catalog.sh`'s comment on deliberately not using an
  associative array for exactly this reason.

### 2. Coreutils/userland differences
- macOS ships BSD userland tools; Linux typically ships GNU coreutils.
  Common utilities take different flags between the two, including but not
  limited to `date`, `sed -i`, `grep`, `stat`, `readlink -f`, and `mktemp`.
- A script using any of these must handle both flavors: either restrict to
  flags/behavior common to both, or explicitly try the GNU form and fall
  back to the BSD form (or vice versa). See `container-upgrade.sh`'s
  `parse_to_epoch()` for the reference pattern: it tries GNU `date -d`
  first, then falls back to BSD/macOS `date -j -f` syntax.

## Rationale
Scripts in this repository are run across a mix of Linux and macOS
machines. A script that only works on one silently fails or misbehaves on
the other - the goal is for that to be caught (and designed around) up
front rather than discovered at 2am on whichever platform wasn't tested.
