# Development Info

Master reference for contributing to this repository. See also
`docs/requirements/` (generic conventions every script follows, plus
per-feature requirement docs) and `docs/implementation.md` (how those
requirements are actually implemented in practice).

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
