# Development Info

Master reference for contributing to this repository. See also
`docs/requirements/` (generic conventions every script follows, plus
requirement docs for repo-wide tooling not specific to a single script) and
`docs/implementation.md` (how those requirements are actually implemented
in practice). Documentation and requirements specific to one script live
under that script's own `platforms/<platform>/<script>/docs/` instead — see
`docs/CONTEXT.md`'s "Per-script documentation" section.

## Git hooks

`tools/git-hooks/` holds this repo's git hooks, tracked in version control
(git itself only ever looks inside `.git/hooks/`, which isn't tracked, so
each hook needs a one-time local install — see README.md's "Repository
tooling" section for the exact commands).

- `post-commit.sh` — creates/updates release tags from a script's
  `Version:` header changes.
  Design: `docs/requirements/implemented/release-tag-hook.md`.
  Implementation notes: `docs/implementation.md`.
  Test: `tools/git-hooks/test-post-commit.sh`.
