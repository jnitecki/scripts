# Requirement: Settings File

## Scope
Adopts [[script-settings-file-convention]] in `container-upgrader.sh`. That
convention defines the locations, precedence, format, validation,
self-upgrade interaction and reporting; this document only lists what is
specific to this script.

Settings files for this script:

| Source | Path |
| --- | --- |
| User | `${XDG_CONFIG_HOME:-$HOME/.config}/scripts-config/bash_container-upgrader.conf` |
| Script location | `<script-dir>/container-upgrader.conf` |
| System | `/etc/scripts-config/bash_container-upgrader.conf` |

Precedence: command line > user > script location > system > built-in
default, resolved per setting.

## Requirement

### 1. Keys allowed in a settings file

| Key | Values | Command-line equivalent |
| --- | --- | --- |
| `mode` | `simple` \| `safe` | `--mode` |
| `timeout` | seconds | `--timeout` |
| `precheck-seconds` | seconds | `--precheck-seconds` |
| `recent-restart-threshold` | seconds | `--recent-restart-threshold` |
| `external-restart-wait` | seconds | `--external-restart-wait` |
| `engine` | `docker` \| `podman` \| `auto` | `--engine` |
| `skip-quadlet-restart` | `true` \| `false` | `--skip-quadlet-restart` / `--no-skip-quadlet-restart` |
| `skip-manual-unit-restart` | `true` \| `false` | `--skip-manual-unit-restart` / `--no-skip-manual-unit-restart` |
| `skip-systemd-restart` | `true` \| `false` | `--skip-systemd-restart` / `--no-skip-systemd-restart` |
| `skip-crashing` | `true` \| `false` | `--skip-crashing` / `--no-skip-crashing` |
| `skip-config-check` | `true` \| `false` | `--skip-config-check` / `--no-skip-config-check` |
| `prune` | `none` \| `dangling` \| `all` | `--prune` (see [[image-prune]]) |
| `prune-until` | `<N>m` \| `<N>h` \| `<N>d` \| `none` | `--prune-until` (see [[image-prune]]) |
| `status-stale-days` | days | `--status-stale-days` |
| `upgrade-type` | `replacement` \| `overwrite` \| `link` \| `memory` \| `none` | `--upgrade-type` (and its alias `--no-autoupdate`) |
| `upgrade-level` | `dev` \| `alpha` \| `beta` \| `rc` \| `stable` \| `auto` | `--upgrade-level` |

Command-line only (a content error if present in a file): `restart-all`,
`dry-run`, `no-autoupdate` (use `upgrade-type = none`), `upgrade-check`,
`upgrade-only`, `status`, `register-banner`, `unregister-banner`, `help`,
every `no-skip-*` negation flag, and container names.

### 2. New command-line forms
Required by the convention's section 6 so any file value can be undone on
the command line:
- `--no-skip-quadlet-restart`, `--no-skip-manual-unit-restart`,
  `--no-skip-systemd-restart`, `--no-skip-crashing`,
  `--no-skip-config-check`.
- `--engine auto` — auto-detect (today's behavior when `--engine` is
  omitted).
- `--upgrade-level auto` — the running script's own level (today's
  behavior when `--upgrade-level` is omitted). As a command-line upgrade
  flag, it still makes the invocation explicit (forces a fresh check).
- `--upgrade-type` needs no new value: its default (full cascade from
  `replacement`) is identical to `--upgrade-type replacement`.
- `--prune none` / `--prune-until none` (defined in [[image-prune]]).

### 3. Script-specific combination rules
The existing command-line combination rules stay as they are and apply to
the command line only:
- `--upgrade-type` + `--no-autoupdate` on the command line is still an
  error. A file's `upgrade-type` combined with a command-line
  `--no-autoupdate` (or vice versa) is not — the command line wins.
- `--upgrade-check` + a file's `upgrade-type`: the file value is not used.
- `--status-stale-days` is still an error on the command line unless
  combined with `--status`/`--register-banner`. In a file it is always
  valid and is used by `--status`.
- `--register-banner` bakes `--status-stale-days` into the generated MOTD
  script only when it was given on the command line. A file value isn't
  baked in, because the banner's own `--status` run reads the settings
  files itself.

### 4. `--status`
`--status` must stay silent and must never fail (see
[[login-status-banner]]):
- It loads settings (it needs `status-stale-days`), but any settings error
  makes it ignore the offending file as a whole, without any output.
- It never prints the "Using settings from" line.

### 5. Other modes
- `--help`: settings are not loaded.
- `--upgrade-check`, `--upgrade-only`, `--register-banner`,
  `--unregister-banner`: settings are loaded and validated normally (a
  content error is fatal). Each uses only the keys relevant to it.
- Self-upgrade trial run: the original script directory is passed to the
  candidate as `CONTAINER_UPGRADE_ORIGINAL_DIR`, alongside
  `CONTAINER_UPGRADE_APPLIED_FROM`/`CONTAINER_UPGRADE_APPLIED_MODE`. The
  change to the self-upgrade block goes into `tools/blueprints/bash.sh`
  first ([[script-maintenance-convention]] section 1).

### 6. Example
```ini
# /etc/scripts-config/bash_container-upgrader.conf
prune = dangling
prune-until = 7d
upgrade-level = stable
skip-crashing = true
```

## Open items for implementation
- Tests first (`tests/test-container-upgrader.sh`): parser (comments,
  quotes, whitespace, sections, duplicates, unknown/CLI-only keys, invalid
  values with file:line in the error), per-key precedence across all three
  files and the command line, negation flags, `auto`/`none` values, the
  `--status` silent fallback, cooldown not bypassed by file values, and
  the script directory used during a trial run.
- Version bump and CHANGELOG entry per
  [[script-maintenance-convention]].
- `--help` (core options and a new "Settings file" section), README,
  `docs/implementation.md`.
