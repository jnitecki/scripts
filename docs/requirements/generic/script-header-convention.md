# Requirement: Script Header Convention

## Scope
Applies to every script in this repository, regardless of scripting/programming
language or the platform/category directory it lives under. See also
[[script-versioning-changelog-help-convention]] for the version-bumping,
in-script changelog, `--help`, exit-code, and startup-banner rules that build
on this header, and [[script-upgrade-convention]] for the optional
`Upgrade-Source:` header line used by scripts that support self-upgrade.

## Requirement
Every script file must begin with a header containing, expressed using that
language's native comment syntax:

1. **Shebang/interpreter line** — when the language and execution context uses
   one (e.g. `#!/usr/bin/env bash`, `#!/usr/bin/env python3`). Omit for
   languages/platforms that have no shebang concept (e.g. PowerShell `.ps1`,
   Windows Batch `.bat`/`.cmd`); the header then starts at the first line.
2. **Version** — `Version: <X.Y.Z>`, a semantic version for the script,
   bumped at least at the patch level on every functional change.
3. **Category** — `Category: <category>[, <category>...]`, one or more short
   lowercase identifiers for the script's functional area(s)
   (e.g. `containers`, `backup`, `networking`), comma-separated on the single
   `Category:` line when a script belongs to more than one. There is no
   fixed/enumerated list of categories — see "Choosing a category" below.
4. **Description** — `Description: <one-line summary>`, a concise statement
   of what the script does.

These four elements must appear as the first lines of the file (immediately
after the shebang, if present), each on its own comment line, in the order
above, before any other header content the script may additionally include
(detailed usage docs, version history, license, etc.).

### Example (Bash)
```bash
#!/usr/bin/env bash
# Version: 1.0.6
# Category: containers
# Description: Docker image upgrade automation with rollback support
```

### Example (Python)
```python
#!/usr/bin/env python3
# Version: 1.0.0
# Category: backup
# Description: Nightly backup verification and report generation
```

### Example (PowerShell — no shebang)
```powershell
# Version: 1.0.0
# Category: networking
# Description: Bulk DNS record validation against a reference zone file
```

### Example (multiple categories)
```bash
#!/usr/bin/env bash
# Version: 1.0.0
# Category: containers, maintenance
# Description: Prunes unused Docker images and volumes on a schedule
```

## Choosing a category
There is no fixed list of allowed categories. When adding `Category:` to a
script, first check the categories already in use (e.g. via `CATALOG.md`'s
category files, or `grep` across existing script headers) and reuse a
matching one. Only introduce a new category value when none of the existing
ones fit — this keeps the category set naturally small without requiring a
maintained enumeration.

## Rationale
Lets a script's purpose, version, and category be identified at a glance —
by a human or by tooling (e.g. a future script index/catalog) — without
parsing the rest of the file.
