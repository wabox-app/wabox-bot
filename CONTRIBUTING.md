# Contributing to wabox-bot

Thanks for your interest. This project is intentionally small — pure bash, no
build step, no runtime dependencies beyond `inotify-tools`, `jq`, `flock`, and
the agent CLI you're plugging in.

## Project layout

```
bin/wabox-bot           # entrypoint — argument parsing, sourcing, main loop
config.example          # template for ~/.config/wabox-bot/config (--init-config)
lib/                    # core modules, one named seam per file
lib/backends/           # one .sh per backend; see docs/backends.md for the contract
examples/               # systemd unit, stubs for additional backends
plugins/                # ready-made WABOX_TRANSCRIBE_CMD transcribers, one folder each
test/bats/              # bats tests; run with `bats test/bats/`
docs/                   # reference docs (backend contract, migration guide)
```

## Local development

- Lint with `shellcheck`: `shellcheck -x bin/wabox-bot lib/*.sh lib/backends/*.sh && shellcheck plugins/*/transcribe.sh`
- Run tests with `bats`: `bats test/bats/`
- The script is bash 4+ compatible; we test on bash 4.4, 5.0, 5.2 in CI.

## Style

- Comments explain **why**, not what. The original `examples/wabox-claude-code.sh`
  in the wabox repo is a good model — its long comment blocks document
  WhatsApp-specific gotchas and Signal-session edge cases, not bash semantics.
- Prefer small, dumb modules. `bin/wabox-bot` sources `lib/*.sh` in order; there
  is no autoloader and no "framework". If a refactor makes the dispatcher
  cleverer than the things it dispatches to, reconsider.

## Adding a backend

A backend is a single sourceable `.sh` file in `lib/backends/`. See
[`docs/backends.md`](docs/backends.md) for the contract — three required
functions, two optional ones.

## Commits

We follow [Conventional Commits](https://www.conventionalcommits.org/) (`fix`,
`feat`, `chore`, `docs`, `refactor`, `test`, etc.).

Changelog entries live in [`CHANGELOG.md`](CHANGELOG.md) under the
`[Unreleased]` section, following the
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/) format.

## Releasing

The version reported by `wabox-bot --version` (and the `daemon.wabox_bot_version`
field of `wabox-bot state --json`) comes from the `VERSION` file at the repo
root — that file is the single source of truth. `VERSION`, the CHANGELOG (both
its section headers **and** the compare-link footer), and the git tag must stay
in lockstep.

Cut a release with one command (bump per [SemVer](https://semver.org/): a new
feature ⇒ minor, a bug fix ⇒ patch):

```bash
make release VERSION=X.Y.Z
```

That runs `make check` (shellcheck + bats), then — atomically —
[`scripts/release.sh`](scripts/release.sh):

1. writes `X.Y.Z` into `VERSION`;
2. promotes `CHANGELOG.md` `[Unreleased]` to `[X.Y.Z] - <today>` (leaving a fresh
   empty `[Unreleased]`) and rewrites the compare-link footer;
3. commits (`chore(release): vX.Y.Z`) and creates the annotated tag `vX.Y.Z`.

It refuses to cut an empty release or a dirty tree, and it does **not** push —
it prints the exact `git push origin <branch> && git push origin vX.Y.Z` to run
once you're happy. So a feature PR lands its changelog entry under
`[Unreleased]`; the release is a separate, mechanical `make release`.

The `install.sh` one-liner pins clones to a branch/tag, so the `VERSION` file in
the checkout is exactly what `--version` reports on an installed copy; when run
from a git checkout, `--version` also appends the short commit for dev builds.
