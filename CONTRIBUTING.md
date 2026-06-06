# Contributing to wabox-bot

Thanks for your interest. This project is intentionally small — pure bash, no
build step, no runtime dependencies beyond `inotify-tools`, `jq`, `flock`, and
the agent CLI you're plugging in.

## Project layout

```
bin/wabox-bot           # entrypoint — argument parsing, sourcing, main loop
lib/                    # core modules, one named seam per file
lib/backends/           # one .sh per backend; see docs/backends.md for the contract
examples/               # systemd unit, stubs for additional backends
plugins/                # ready-made WABOX_TRANSCRIBE_CMD transcribers, one folder each
test/bats/              # bats tests; run with `bats test/bats/`
docs/                   # reference docs (backend contract, migration guide)
```

## Local development

- Lint with `shellcheck`: `shellcheck -x bin/wabox-bot lib/*.sh lib/backends/*.sh`
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
