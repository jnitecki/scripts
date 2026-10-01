# Requirement: Script Settings File Convention

## Scope
Applies to every script in this repository that opts in to reading
persistent, per-machine settings from a settings file, regardless of
language. A script without a settings file is unaffected. Builds on
[[script-versioning-changelog-help-convention]] (startup banner, `--help`
content, unrecognized-option rejection) and interacts with
[[script-upgrade-convention]] (see section 8 below). Script-specific
details — which keys a given script accepts, its own negation flags, any
mode in which settings errors must stay silent — live in that script's own
`platforms/<lang>/<name>/docs/requirements/`.

## Requirement

### 1. Purpose
A settings file holds a machine's (or a user's) preferred values for a
script's options, so a recurring invocation (cron, a scheduler, a login
hook, or just habit) doesn't need to repeat them on every command line.
Every setting a file can hold is the persistent counterpart of a
command-line option; a settings file never introduces behavior that has no
command-line equivalent.

### 2. Locations and file name
A script looks for its settings file in three locations:

| Source | Path |
| --- | --- |
| User | `${XDG_CONFIG_HOME:-$HOME/.config}/scripts-config/<lang>_<name>.conf` |
| Script location | `<script-dir>/<name>.conf` |
| System | `/etc/scripts-config/<lang>_<name>.conf` |

- `<lang>`/`<name>` are the same identity values used for the self-upgrade
  cache and run-state paths (e.g. `bash_container-upgrader.conf`).
- `<script-dir>` is the directory of the script as it was invoked (`$0`'s
  directory), **not** a symlink-resolved target (`readlink -f` isn't
  portable — see [[cross-platform-shell-compatibility]]). For a self-upgrade
  trial run it is the *original* script's directory, not the temp/cache
  location the candidate runs from (see section 8).
- `$HOME`/`$XDG_CONFIG_HOME` are used as found in the environment; the
  script doesn't attempt to work out a "real" user behind `sudo`.
- A missing file is silently skipped. A file that exists but can't be read
  is skipped with a warning (it's an environment issue, e.g. a `0600`
  system file read by a non-root user, not a content error).

### 3. Precedence
Highest to lowest:

1. Command-line options
2. User file
3. Script-location file
4. System file
5. The script's built-in default

Each setting is resolved **independently**: for each key, the value from
the highest-precedence source that sets it wins. A higher-precedence
source that doesn't mention a key has no effect on that key. Files are
never merged or overridden as a whole.

### 4. Format (INI-style)
- One `key = value` per line. Whitespace around the key, the `=`, and the
  value is trimmed. A value may optionally be wrapped in matching single or
  double quotes, which are stripped. No escape sequences, no variable
  expansion.
- Blank lines are ignored. Comments are full lines whose first non-blank
  character is `#` or `;` (only spaces/tabs allowed in front of it).
  Inline (trailing) comments are not supported — `#` or `;` after a value
  is part of the value.
- No `[section]` headers: each file belongs to exactly one script, so
  sections have no meaning. A section header line is a content error.
- Keys are the script's long option names without the leading `--`
  (`--upgrade-level beta` → `upgrade-level = beta`).
- Boolean settings take `true` or `false` only.
- The file is **parsed, never sourced/executed** — the system-wide file
  may be read by a root-run invocation, and executing it would turn a
  settings file into arbitrary code execution.

### 5. Which options can be settings
- Only options that describe a persistent preference can be settings:
  tuning values, mode choices, `--skip-*`-style behavior toggles, and the
  self-upgrade preferences (section 8).
- One-shot actions and per-invocation choices are **command-line only**:
  dry-run, `--help`, early-exit modes (`--upgrade-check`, `--upgrade-only`,
  status/registration-style actions), positional arguments, and anything a
  script's own requirements mark as command-line only.
- **Aliases**: where several command-line forms set the same thing (e.g.
  `--no-autoupdate` = `--upgrade-type none`), only one canonical key exists
  in the file (here `upgrade-type`). The alias is command-line only.

### 6. Overriding a file value from the command line
The command line must always be able to restore any setting to any of its
values, including the built-in default:
- Every boolean option that can be a setting gets a negation flag,
  `--no-<flag>` (e.g. `--skip-crashing` / `--no-skip-crashing`). The
  negation flag is command-line only.
- Every value option whose default is "unset"/"auto-detect" must accept an
  explicit value meaning that default (e.g. `auto`, `none`), so a file's
  value can be cleared from the command line.
- If both a flag and its negation appear on the same command line, the
  last one wins (ordinary left-to-right option parsing).

### 7. Validation and errors
- Every value is validated exactly as its command-line equivalent is.
- An unknown key, a command-line-only key, an invalid value, a duplicate
  key within the same file, or any malformed line is a **fatal error**:
  exit `1` with a message naming the file, line number, and problem —
  before any real work starts. Silently ignoring a mistyped setting would
  hide a mistake the same way an ignored unknown option would.
- A script may define modes in which settings errors must not produce
  output (e.g. a status line run on every login). In those modes, the
  offending file is ignored as a whole, without output, and resolution
  falls back to the remaining sources.
- **Option-combination validation** (rules like "X cannot be combined with
  Y") applies to the **command line only**. A file value that would form a
  forbidden combination with a command-line option is simply not used for
  that run — the explicit command-line choice wins. Combinations formed
  purely between files are resolved by precedence (section 3), since each
  key has exactly one effective value.

### 8. Interaction with [[script-upgrade-convention]]
- Settings are loaded after command-line parsing and before the
  self-upgrade step, so `upgrade-type`/`upgrade-level` from a file take
  effect for that step.
- Only **command-line** upgrade flags make an invocation *explicit* in the
  sense of [[script-upgrade-convention]] section 2. Values coming from a
  settings file never bypass the cooldown cache — otherwise a machine with
  `upgrade-level` set in a file would check the network on every run.
- A self-upgrade trial run is a fresh process that reads the settings
  itself. Since it runs from a temp/scratch/cache file, the original
  script's directory is handed to it via an environment variable (set
  together with the existing re-entry guard variables), and the
  script-location file is looked up there.
- An explicit early-exit upgrade action wins over a file's
  `upgrade-type = none`: `--upgrade-only` still upgrades and
  `--upgrade-check` still checks. Any other file `upgrade-type` value still
  caps `--upgrade-only`'s apply mode, as a command-line one would.

### 9. Reporting
- On every invocation that prints the startup banner, if at least one
  settings file was loaded, one further line follows the banner:
  ```
  Using settings from: /home/u/.config/scripts-config/bash_container-upgrader.conf, /etc/scripts-config/bash_container-upgrader.conf
  ```
  listing loaded files in precedence order (highest first). No line is
  printed when none was loaded.
- Printed by whichever process prints the banner (for a self-upgrade
  trial run, the candidate).
- `--help` documents the settings file (locations, precedence, format),
  and each option's help entry says whether it can be set in the file.

## Rejected alternatives
- **Sourcing the file as shell** (`. file`): rejected — executes arbitrary
  code, including as root via the system file.
- **Script-location file above the user file**: rejected — the script
  usually lives in an admin-owned directory (`/usr/local/bin`), and its
  file would then override every user's own preferences. Script-location
  sits between user and system instead.
- **One shared file with a section per script**: rejected — one file per
  script keeps permissions and ownership per script, and keeps a parse
  error in one script's settings from breaking another script.

## Rationale
Lets a machine carry its own preferred behavior (e.g. pruning policy,
release channel) without wrapper scripts or long cron lines, while keeping
the command line in full control of any single run and keeping a settings
file inert data rather than code.
