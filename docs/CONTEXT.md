# Coding Assistant Rules

## Startup
At the start of every task:
1. Read docs/requirements/implemented/ to understand what exists
2. Read any relevant file in docs/requirements/pending/ for the feature being discussed
3. Read docs/requirements/generic/ to understand generic, cross-cutting requirements that apply project-wide

## Rules
- Ask questions if any details are not clear
- Criticize proposed solution if it has any issue
- If there is conflict between pending requirement documentation and current code, base discussion and later implementation on pending requirement definition
- Never implement a pending feature without a requirements doc
- After implementing a feature, move its doc from pending/ to implemented/
- Update the README.md to reflect what was actually built, not just what was planned
- Documentation files in root directory (README.md, CONFIGURATION.md and others) are for end-user only, so they should cover end user perspective (and developer consuming library), but should not refer to internal implementation code nor to documentation files outside root directory (e.g. requirements).
- Instructions for project developers (not developers consuming project/library) should be placed in docs/development-info.md and other files in docs/ directory.
- docs/development-info.md should act as master information file for all aspects related to project development.
- Keep docs/implementation.md file reflecting actual implementation details. It should contain detail related to current implementation, so any removed code/features/etc. should be removed from that file as well.
- The information from docs/ideas should not affect the decisions how to proceed with requirements, other than for deciding between multiple equivalent approaches.
- Whenever a requirement, or part of one, is decided to be postponed/deferred (phase-2, "not required for v1", "out of scope for v1 pending X", etc.), record it in docs/requirements/pending/parked-requirements-list.md (name, short info, reference to where it's fully specified) at the same time. When a parked item is later implemented or formally dropped, remove its entry.
- While planning, don't only produce the plan itself — also report in chat, for each of my requirements/suggestions/questions, how it was addressed (or why it was rejected/postponed/modified).

## Generic Requirements
- Requirements in docs/requirements/generic/ are cross-cutting and apply project-wide, in whichever areas each one is relevant to.
- Unlike pending/implemented docs, they are not tied to a single feature's lifecycle and are never moved to docs/requirements/pending/ or docs/requirements/implemented/ - they stay in docs/requirements/generic/ permanently.
- When a generic requirement is implemented (fully or in the areas where it applies), capture those details in implementation documentation instead of relocating the requirement doc.
- If a generic requirement appears to conflict with a specific pending/implemented requirement, do not resolve it silently - flag the conflict and ask.
- Rules in docs/requirements/generic/ define a minimum requirement, as far as functionality is relevant - a project may implement equivalent or more advanced functionality than the generic requirement literally describes without that counting as a gap or a conflict.

## Coding Conventions
- Write tests before implementation.
- Remove dead code if the implementation or requirements change.
- Avoid duplication as much as possible.
- Use ISO-Z format when using timestamps in log or in other places that date is printed for technical reasons.
- Prefer localized changes unless I specifically ask or approve re-factoring.

## Code repository
- Never commit any files having secrets - exclude them and warn me about their existence.

## Prerequisites setup
- A "prerequisite" means an external system or service the application depends on at runtime but doesn't bundle — e.g. a database, an LLM/inference service, a message queue. It does NOT mean the language runtime needed to run the application (e.g. Python), nor anything only a developer building/packaging the project needs (compilers, build tooling, dev dependencies) — those belong in docs/development-info.md instead, not PREREQUISITES.md.
- Write PREREQUISITES.md from the end user's perspective (someone running/operating the application), not the developer's.
- If this project has any such prerequisite, keep PREREQUISITES.md reflecting every one, including how to install/prepare each one. Only maintain this file while such prerequisites actually exist; if none exist, don't create it (or remove it if it no longer applies).

## Features documentation
- Create file FEATURES.md (in root of the project) listing product features, grouped
  by audience (end user, operator, technical/platform, or similar), only once the
  product has a significant number of features. Below that threshold, list features
  directly in README.md instead — do not create FEATURES.md prematurely.
- If FEATURES.md exists, README.md should still list the few most important features
  inline, then reference FEATURES.md for the complete list.
