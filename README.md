# Scripts

A collection of standalone operations scripts, organized by platform under
`platforms/<lang>/<script-name>/`. Each script carries its own version,
category, and description in its header, and is runnable on its own — copy
the single file to wherever you need it.

## Using a script

Browse [CATALOG.md](CATALOG.md) for the full list, or a `<CATEGORY>.md`
file (e.g. [CONTAINERS.md](CONTAINERS.md)) for scripts in a specific
category, each entry linking to its implementation with its current
version.

## Repository tooling

### Release tags

Every commit that changes a script's `Version:` header creates (or, on an
exact-name collision such as an amend, replaces) an annotated git tag
named `<lang>/<script-name>/v<X.Y.Z>` pointing at that commit, via a
`post-commit` hook.

To enable it in a local clone (one-time setup):
```
ln -sf ../../tools/git-hooks/post-commit.sh .git/hooks/post-commit
git config --local push.followTags true
```
The first command installs the hook. The second makes a plain `git push`
automatically carry any new release tags along with it — git's own
tag-following push, so no separate `git push --tags` step is needed.

The hook itself never pushes anything. If a tag ever needs re-pushing
after it was replaced locally (an amend on a commit whose tag was already
pushed), that's a manual step:
```
git push --force origin refs/tags/<lang>/<script-name>/v<X.Y.Z>
```

To verify the hook works as expected, run:
```
tools/git-hooks/test-post-commit.sh
```
