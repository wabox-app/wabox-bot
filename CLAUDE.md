# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

wabox-bot is a pure-bash daemon that bridges [wabox](https://github.com/rodgco/wabox)'s
WhatsApp inbox/outbox folders to a pluggable agent backend. The data flow is:

```
inbox/<id>.json  →  wabox-bot  →  per-conversation agent session  →  outbox/<id>.json
```

No build step, no runtime deps beyond `inotify-tools`, `jq`, `flock`, `timeout`,
and whatever CLI the active backend drives (`claude` by default). bash 4+.

## Commands

```bash
# Lint (CI runs exactly these — note -x for the sourced core)
shellcheck -x bin/wabox-bot
shellcheck lib/backends/*.sh install.sh examples/aider.sh

# Tests
bats test/bats/                       # whole suite
bats test/bats/routing.bats           # one file
bats test/bats/routing.bats -f "slug" # one test by name filter

# Run the daemon (needs a live wabox instance, or set the paths manually)
export WABOX_INBOX=~/.local/share/wabox/inbox
export WABOX_OUTBOX=~/.local/share/wabox/outbox
bin/wabox-bot                         # default backend: claude-code
bin/wabox-bot --backend echo          # smoke-test the loop without an LLM
```

`lib/*.sh` core files are checked transitively by `shellcheck -x bin/wabox-bot`
because the entrypoint sources them in order — don't shellcheck them individually.
Backend files and the installer load dynamically/standalone, so CI checks them separately.

## Architecture

`bin/wabox-bot` is a thin entrypoint: it parses `--backend`, then **sources `lib/*.sh`
in a deliberate order** (config → log → locks → routing → outbox → backend → migrate →
commands → inbox → loop) and calls `run_main_loop`. There is no autoloader and no
framework. Each `lib/*.sh` is one named seam. The source order is load-bearing —
e.g. `config.sh` is sourced *before* `log.sh`, so it cannot call `log_*` at source
time (only `check_dependencies()`, invoked later by the entrypoint, may).

Module map:

- **config.sh** — path/env resolution + dependency check. Auto-migrates the legacy
  `~/.local/state/wabox-claude` STATE_DIR to `wabox-bot` *before* `mkdir`, so the new
  dir is populated by the move, not created empty. Reads wabox's real paths from
  `wabox status --json` when available.
- **log.sh** — `log_info/warn/error/debug` to both LOG_FILE and stderr. `log_debug` is
  a no-op unless `DEBUG=1`.
- **locks.sh** — single-instance flock on fd 9; shutdown/child-reaping. `CHILDREN`
  associative array tracks handler PIDs; `shutdown()` drains them with a deadline
  before escalating to SIGTERM/SIGKILL.
- **routing.sh** — `conversation_key()` maps an envelope to a logical thread (DM/group
  JID, or `from|participant` when `GROUP_PER_PARTICIPANT=1`); `key_slug()` sha1-hashes
  it to a safe filename.
- **inbox.sh** — the per-envelope handler (see ordering invariant below).
- **outbox.sh** — atomic writer: write to a dot-prefixed temp (wabox ignores it by
  glob), then rename into place. wabox sends any `*.json` in outbox immediately, so a
  half-written file would be picked up.
- **backend.sh** — resolves the backend, sources `lib/backends/<name>.sh`, validates
  the contract, and provides `backend_state_dir`.
- **migrate.sh** — idempotent in-STATE_DIR migrations from the old flat layout.
- **commands.sh** — core slash-command dispatcher.
- **loop.sh** — catch-up of pre-existing inbox files + inotify-via-FIFO main loop.

## Critical invariants

**Read-receipt timing (inbox.sh).** The inbox file is `mv`'d to `PROCESSED_DIR`
*before* the backend is called. That move is what fires the WhatsApp blue ticks, so
the user sees "read" immediately, not after the agent finishes thinking. Don't reorder
this. Losing the race to move the file means another worker has it — return quietly.

**Reply on the inbound JID verbatim.** A 1:1 chat can arrive via `<number>@s.whatsapp.net`
*or* `<lid>@lid`, each with its own Signal session. inbox.sh sets `to="$from"` and never
"normalizes" it — replying on the wrong identity desyncs the session and the recipient
gets stuck on "Waiting for this message".

**Two-level locking.** Single-instance lock (fd 9, `$PID_LOCK`) stops two daemons
fighting over one inbox. Per-conversation lock (fd 8, `$LOCKS_DIR/<slug>.lock`)
serializes messages from the same sender while different senders run in parallel.
Backend state mutations from slash commands must also take the per-conversation flock.

**FIFO main loop (loop.sh).** inotifywait writes to a FIFO that this shell reads, so
inotifywait has a signalable PID *and* the `while` loop runs in the main shell (keeping
`CHILDREN` and traps live). A 1s read timeout lets signals break out within a second.

## Backends

A backend is one sourceable `lib/backends/<name>.sh`. Selection precedence:
`--backend` flag > `WABOX_BOT_BACKEND` env > `claude-code` default. Contract
(full details in `docs/backends.md`):

- Required: `backend_name` (echo the id, must match filename stem), `backend_reply`
  (stdin = user text, stdout = reply; exit `0` ok, `124` timeout, other = error).
- Optional: `backend_handle_command` (return `99` to pass an unknown command back to
  core), `backend_clear`, `backend_check_dependencies`, `backend_help`,
  `backend_status_lines`.

Per-conversation backend state lives under `backend_state_dir "$slug"` →
`$SESSIONS_DIR/<slug>/<backend>/`, so switching backends never smushes state together.
The `claude-code` backend stores `session`/`model`/`mode`/`system` files there and
sanitizes `/model` and `/mode` values with a regex before passing them to `claude`
(they go straight to `--model` / `--permission-mode`).

Core owns `/clear`, `/reset`, `/ping`, `/status`, `/help`; `/help` and `/status`
aggregate backend-supplied lines, and `/clear` also calls `backend_clear`.

## Conventions

- **Comments explain *why*, not *what*** — WhatsApp/Signal gotchas and bash edge cases,
  not bash semantics. Match the existing dense comment style.
- Keep modules small and dumb. If a refactor makes the dispatcher cleverer than what it
  dispatches to, reconsider.
- [Conventional Commits](https://www.conventionalcommits.org/) (`fix`, `feat`, `docs`,
  `refactor`, `test`, …). Changelog entries go under `[Unreleased]` in `CHANGELOG.md`
  ([Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/)).
- Tests isolate via tempdirs (`test/bats/test_helper.bash`): `setup_lib`/`teardown_lib`
  for paths, `load_core` to source the production core without installing signal
  handlers or the single-instance lock. Tests needing the real `run_main_loop` invoke
  `bin/wabox-bot` as a subprocess instead.
