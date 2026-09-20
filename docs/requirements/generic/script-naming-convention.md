# Requirement: Script Naming Convention

## Scope
Applies to every script's **deployable identity** in this repository —
its directory under `platforms/<lang>/<script-name>/` and the script file
itself (`<script-name>.<ext>`) — regardless of scripting/programming
language. This is distinct from, and does not override,
[[script-header-convention]]'s `Category:` field (which groups scripts by
subject, not by name) or any language-native naming idiom for things
*inside* a script (e.g. PowerShell's Verb-Noun convention for an
**exported function/cmdlet name**, governed by PowerShell's own approved-
verb tooling — a script that happens to also export a reusable function
still names that function per PowerShell's own rules; only the script's
own file/directory identity is what this document governs).

## Requirement
A script's name is `<object>-<agent-noun>`:
- **`<object>`** — the noun the script acts on or is about (`container`,
  `interface`, `duplicate`), stated first. This keeps scripts that share a
  subject sorted/grouped together in a directory listing, `CATALOG.md`, or
  a category file (e.g. `CONTAINERS.md`), independent of what each one
  individually does to that subject.
- **`<agent-noun>`** — a noun describing *what kind of tool this is*
  (`upgrader`, `configurator`, `manager`), not a bare verb stem. A name
  reads as an actual noun phrase ("the container upgrader") rather than an
  ambiguous imperative fragment.

Both parts follow [[script-header-convention]]'s `Category:` character
restriction for consistency, even though this identity isn't itself
validated by the catalog generator: lowercase, words separated by a single
hyphen (`^[a-z0-9]+(-[a-z0-9]+)*$`).

### Example
```
platforms/bash/interface-configurator/interface-configurator.sh
```
`interface` (object) + `configurator` (agent noun for "configure").

## Choosing the agent noun
Prefer the natural single-word agent noun for the script's core action
(`upgrade` → `upgrader`, `configure` → `configurator`, `manage` →
`manager`, `restart` → `restarter`, `clean up` → `cleaner`). Not every verb
forms one idiomatically or accurately, though — check both:

1. **Does a natural `-er`/`-or` form exist at all?** `backup` → `backuper`
   does not read as a real English word; forcing the suffix on produces
   something awkward rather than clear.
2. **Does the natural form still mean the right thing?** Even when a
   natural form exists, it can misstate what the tool actually does. A
   script that makes rotating recovery copies (originals stay in place,
   meant to restore *current* state) is a **backup** tool; calling it
   `-archiver` instead implies long-term/cold-storage retention with
   different semantics (often: originals moved or deleted, compliance-
   driven retention) — a real reader could reasonably draw the wrong
   conclusion about what's safe to prune or how long a copy is kept.

When either check fails, pick a word that accurately describes the tool's
actual behavior over one that's merely mechanically derived from the verb
— including falling back to a generic agent noun (`-manager`, `-runner`)
rather than coining an inaccurate or unnatural one:

| Action | Natural `-er`/`-or`? | Accurate? | Chosen agent noun |
| --- | --- | --- | --- |
| upgrade | yes (`upgrader`) | yes | `upgrader` |
| configure | yes (`configurator`) | yes | `configurator` |
| clean up (prune old data) | yes (`cleaner`) | yes | `cleaner` |
| back up (rotating recovery copies) | no (`backuper` isn't real) | `archiver` exists but is inaccurate (implies cold-storage/retention semantics) | `backup-manager` (or a word for what it's *actually* doing, e.g. `snapshotter`, if that's more precise) |
| deduplicate | no clean single-word form | — | `duplicate-manager` |

This is a judgment call per script, not a mechanical transform — when in
doubt, check what the script actually does before picking the word.

## Scripts under this convention
Every script in this repository is named under this scheme:
`container-upgrader` (bash) and `interface-configurator` (bash, pending
implementation).

## Rejected alternatives
- **Verb-noun (e.g. `upgrade-container`), mirroring PowerShell cmdlet
  syntax**: rejected — this repo mixes languages, and PowerShell's own
  Verb-Noun idiom (with its approved-verb list) doesn't map onto
  non-PowerShell scripts at all; adopting it repo-wide would mean picking
  names for bash/Python scripts that satisfy a convention that isn't even
  theirs.
- **Bare object-verb (an object noun immediately followed by a bare verb
  stem, e.g. `subject-verb`)**: rejected — a bare verb stem glued after a
  noun doesn't read as a grammatical phrase in English (unclear whether
  it's a command name or a malformed noun phrase); the object+agent-noun
  form resolves that while keeping the same object-first ordering.
- **Mechanically appending `-er`/`-or` to every verb with no accuracy
  check**: rejected per "Choosing the agent noun" above — `backup` →
  `archiver` is the concrete case that surfaced this: grammatically clean,
  but describes a different tool than the one being named.

## Rationale
An object+agent-noun name is unambiguous as English (it's a real noun
phrase), keeps the object-first ordering this repo's catalog/category
grouping already depends on, and is independent of any single language's
own naming idioms — important given this repo already spans (or plans to
span) bash, PowerShell, and Python.
