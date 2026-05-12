# Contributing

This project uses **Conventional Commits + Cocogitto** for versioning and changelog generation.

## Quick start

Install Cocogitto:

```bash
cargo install cocogitto
```

Install the repository hooks:

```bash
cog install-hook --all
```

You also need Zig **0.16.0** available on your PATH:

```bash
zig version
```

## Commit messages required

All commits must follow the Conventional Commits format:

```text
<type>: <short description>
```

### Allowed types

* `feat`: new functionality = **minor version bump**
* `fix`: bug fix = **patch version bump**
* `hotfix`: urgent fix = **patch version bump**

Examples:

```text
feat: add streaming parser
fix: handle empty input
hotfix: guard panic in release mode
```

Breaking changes use `!`:

```text
feat!: redesign public API
```

## Branch naming

Use these prefixes:

* `feat/<name>`
* `fix/<name>`
* `hotfix/<name>`

Branch names are for humans only. 

Versioning is based on commit messages, not branch names.

## Pull requests

* Use **squash merge**
* Final commit message must follow Conventional Commits
* CI must pass
* Run the local checks before opening a PR:

```bash
zig fmt .
zig build test
zig build -Doptimize=ReleaseSafe
```

## Releasing

Releases are created from `main`:

```bash
cog bump --auto
```

This will:

* determine the next version from commits
* update `build.zig.zon`
* update `CHANGELOG.md`
* create a release commit
* create a git tag such as `v0.1.0`
* push `main`
* push the new tag

## Notes

* Do not edit `CHANGELOG.md` manually
* Do not bump versions manually
* Do not create release tags manually unless recovering from a failed release
