# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.7.0] - 2026-07-06

### Added

- **Proactive messaging** — outbound-initiated messages, no scheduler and no
  daemon changes. Two client verbs in the `answer`/`cmd` family:
  - `wabox-bot send <slug> [text]` — dumb delivery of a message to a
    conversation (no agent turn, no lock; the outbox write is atomic). Text
    omitted or `-` reads stdin; `--file <path>` (repeatable) attaches files;
    `--to <jid|number>` targets a recipient with no prior conversation. The slug
    path records a `direction:"out"` entry in `last_message.json`.
  - `wabox-bot prompt <slug> <text>` — runs the canonical agent turn (same
    session, workdir, per-conversation lock, and send-folder lifecycle as an
    inbound message) and delivers the reply. Suppresses delivery — nothing sent,
    exit `5` — when the reply is empty or the `NOOP` sentinel (configurable via
    `WABOX_PROMPT_NOOP`). Exit codes: `0` delivered, `1` usage/unknown slug,
    `3` lock busy, `5` suppressed, `124` backend timeout.
  - `examples/heartbeat/` — a crontab line and a systemd user timer+service pair
    invoking `prompt` with a standing instruction, plus `standing-prompt.txt` and
    a README walkthrough. The heartbeat pattern: a scheduled `prompt` where the
    agent replies `NOOP` unless something needs attention, so it messages you
    only when it has something to say.
- `last_message.json` now carries `direction:"out"` for messages the `send`/
  `prompt` verbs deliver (previously only inbound `"in"` records existed).
- `lib/lastmsg.sh` — a shared `lastmsg_write` writer extracted from
  `lib/inbox.sh` so the three writers (inbound handler, `send`, `prompt`) share
  one atomic implementation.

## [0.6.0] - 2026-07-06

### Added

- Rich replies, all loop-level and off-by-default-safe (no backend-contract
  change; the reply contract stays "text on stdout"). Three features:
  - **Ack reactions.** Set `WABOX_ACK_REACT` (e.g. `👀`) and the bot reacts to a
    message the moment its agent turn starts — a "working on it" signal distinct
    from the blue-tick read receipt. React-only job carrying the inbound id (+
    `participant` in groups). Empty (the default) keeps outbox traffic
    byte-identical to prior releases; slash commands, skipped, and empty messages
    never trigger it.
  - **Outgoing files.** A file the agent writes into its conversation's send
    folder (`<workdir>/wabox-send/`, name via `WABOX_SEND_DIR`) is attached to
    the reply — sorted by name, reply text as the first file's caption, empty
    reply + files ⇒ a files-only delivery. The folder is cleared at the *next*
    turn's start (leftovers archived to `.sent/`, pruned after
    `WABOX_SEND_KEEP_DAYS`, default 7) so an in-flight send isn't raced; failed
    turns attach nothing. The `claude-code` backend advertises the folder to the
    agent (`CC_ADVERTISE_SEND_DIR`, default on). The loop — never the model —
    owns the recipient and the file list.
  - **Quote-replies.** `WABOX_QUOTE_REPLY=auto|always|never` (default `auto`).
    `auto` quotes in groups (with `participant`) or when a newer message for the
    same conversation is still queued in the inbox, so replies stay threaded
    under backlog.
- `lib/senddir.sh` — the send-folder lifecycle helpers (`senddir_prepare`,
  `senddir_collect`, `senddir_prune`), kept out of `lib/inbox.sh` for testability.

### Changed

- `write_outbox` takes an optional 5th argument, `extras` — a JSON object merged
  into the job (`react`, `files`, richer `replyTo` with `participant`). Existing
  four-arg callers are untouched and their output is byte-identical. Invalid or
  non-object extras are logged and ignored rather than blocking delivery; an
  empty `text` is now omitted from the job (enabling react-only / files-only
  jobs).

## [0.5.0] - 2026-07-06

### Added

- Self-update. `wabox-bot --check-update` reports whether a newer release is
  published (exit `0` up to date, `10` newer available, `1` undetermined);
  `wabox-bot --update` upgrades the install with the same `fetch` + `reset --hard`
  to `origin/main` that `install.sh` runs, prompting for confirmation on a
  terminal (skip with `WABOX_BOT_ASSUME_YES=1`). "Published" is the highest
  `vX.Y.Z` tag read via `git ls-remote` — no `curl`/`wget`, no GitHub API. On
  startup the daemon does a best-effort, backgrounded check and logs a notice
  when a newer version exists (disable with `WABOX_BOT_UPDATE_CHECK=0`), also
  surfaced in `/status`. A new core `/update` slash command checks over WhatsApp
  and applies on `/update now` (gated by `WABOX_BOT_ALLOW_REMOTE_UPDATE`, default
  on); an applied update takes effect only after the daemon restarts. `update_apply`
  refuses to clobber a checkout with local changes unless `WABOX_BOT_UPDATE_FORCE=1`.

## [0.4.0] - 2026-07-06

### Added

- `wabox-bot cmd <slug> "<slash command>"` — run a conversation's slash command
  (`/cwd`, `/model`, `/mode`, `/system`, `/clear`, and any backend command) from
  the CLI, the write half of the `state`/`transcript`/`answer` contract (for
  wabox-tui). Reuses `handle_slash_command` verbatim — same validation, same
  per-conversation locking those commands already take — but captures the reply
  and prints it on stdout instead of delivering it over WhatsApp, so tooling can
  change a conversation's settings without messaging the user. Exit `0` when the
  command was handled (reply on stdout, possibly an "Unknown command" notice),
  `1` on usage / unknown slug / non-command input.

## [0.3.0] - 2026-07-06

### Added

- `wabox-bot transcript <slug> [--limit N]` — a read-only, versioned
  (`"version": 1`) JSON transcript of one conversation, extending the
  `state`/`answer` client contract (first consumer: wabox-tui). Merges inbound
  messages (from `PROCESSED_DIR` envelopes, needs `KEEP_PROCESSED=1`) with
  outbound replies (from wabox-core's `outbox/sent` archive) into one
  time-ordered `turns` array — each turn carrying `at`, `direction`, `text`, and
  a `media` marker — with `total`/`count` and a `keep_processed` hint. Does the
  slug→conversation routing itself (reading only the public envelope/outbox-job
  formats), so tools never scan wabox's private layout. Takes no locks.

## [0.2.0] - 2026-07-06

### Added

- `wabox-bot --version` (alias `-v`) prints the installed version, sourced from
  the new `VERSION` file at the repo root — the single source of truth for
  releases (kept in lockstep with the CHANGELOG and the git tag; see
  CONTRIBUTING.md → Releasing). When run from a git checkout, `--version` also
  appends the short commit for dev builds. The version is logged at daemon
  startup and exposed to tooling as `daemon.wabox_bot_version` in
  `wabox-bot state --json`.
- `wabox-bot state --json` — a read-only, versioned (`"version": 1`) JSON
  snapshot of the daemon and every conversation, as the stable contract for
  external tooling (first consumer: wabox-tui). Reports daemon liveness + PID
  (via a non-blocking probe of the single-instance lock), and per conversation
  its `conv_key`, working folder, lock state, last message, and the backend's
  view (session id, overrides, and any *fresh* parked permission with its
  tools, question, and expiry). Takes no locks a running daemon would contend
  for. Backed by an optional `backend_state_json` hook (claude-code implements
  it; missing hook ⇒ core fills those fields with `null`).
- `wabox-bot answer <slug> <yes|no>` — answer a conversation's parked
  permission request from the CLI, through the same path a WhatsApp `sim`/`não`
  reply takes; the reply still lands in the chat. Takes the per-conversation
  lock (not the single-instance lock). Exit codes: `0` ok · `2` nothing
  pending · `3` lock busy · `4` backend unsupported · `1` usage. Backed by an
  optional `backend_answer_permission` hook.
- The loop now persists `$SESSIONS_DIR/<slug>/conv_key` (the one-way
  slug↔conv_key mapping) and `last_message.json` (`{at, direction, text_preview}`,
  inbound only for now) on every handled envelope, so `state` can enumerate and
  sort conversations without scanning `processed/`.
- The daemon writes its PID into the single-instance lock file after acquiring
  it, so `state` can report it.

- Permission requests over WhatsApp (claude-code backend). Running in
  `--permission-mode default` (now the default `CLAUDE_ARGS`), any tool the
  agent isn't pre-allowed to run surfaces as a `permission_denials` entry in
  the turn's JSON instead of being silently auto-approved. The backend parks
  the turn, asks you over WhatsApp ("⚠️ Claude precisa de permissão… responda
  *sim*/*não*"), and on approval resumes the *same* session granting exactly
  the denied tools (`--allowedTools`) so the agent carries on from where it
  stopped — `não` cancels, an unrecognised reply re-asks, and a parked request
  expires after `CC_PERMISSION_TIMEOUT` (default 600s, after which the next
  message is treated as a fresh prompt). A resumed turn that hits a *new*
  denial parks again, so the flow chains. `/clear` drops any parked request and
  `/status` flags one. Fully contained in the backend — no core changes.

- `bob` backend, driving IBM's Bob Shell CLI (`bob -o json`). Each conversation
  gets its own thread via Bob's per-project `--resume latest` (which lines up
  with wabox-bot's per-conversation working folders). Defaults to `--yolo` and
  `--chat-mode advanced`; owns `/model` (→ `-m`) and `/mode` (→ `--chat-mode`,
  validated against `plan`/`code`/`advanced`/`ask`). Auth via `BOBSHELL_API_KEY`.
- `agy` backend, driving Google's Antigravity coding agent (`agy` print mode)
  as an autonomous agent over WhatsApp: with `--dangerously-skip-permissions`
  it reads files, runs commands, and edits code in the conversation's working
  folder. Because agy's `--continue` is global, each conversation is pinned to
  an explicit conversation id captured from agy's `--log-file` and resumed via
  `--conversation` (stale ids self-heal). Prepends a concise-answer instruction
  (`AGY_REPLY_PREFIX`) to suppress agy's step-by-step narration. Owns `/model`
  (validated against `agy models`). Tunables: `AGY_BIN`, `AGY_ARGS`,
  `AGY_TIMEOUT`.
- Per-conversation working folder: each conversation runs its agent in its own
  directory (auto `$STATE_DIR/work/<slug>` by default). New `/cwd <path>`
  command redirects a conversation to a chosen folder (e.g. `~/Valter`);
  `/cwd default` reverts. Shown in `/status`. The Claude Code backend records
  the working folder a session was created in and only resumes from that same
  folder — changing `/cwd` starts a fresh session, since Claude Code scopes
  sessions to the working directory and cannot resume one across directories.
- Image and audio message processing. Image messages are handed to the agent to
  read; audio (voice notes) are transcribed to text via a pluggable command
  (`WABOX_TRANSCRIBE_CMD`, `WABOX_TRANSCRIBE_TIMEOUT`). Captions are included and
  media is staged under `<working-folder>/wabox-media/`. The `backend_reply`
  contract gains three optional media arguments.
- Configuration file: all environment variables can live in one sourced file
  (`~/.config/wabox-bot/config`, override with `--config`/`WABOX_BOT_CONFIG`),
  exported to subprocesses. New flags `--init-config` (install the bundled
  `config.example` template) and `--print-config` (show effective values, with
  secrets masked). The environment still overrides file values.

### Changed

- Default `CLAUDE_ARGS` is now `--permission-mode default` (was
  `--permission-mode auto`), which activates the permission-over-WhatsApp flow
  above. Set `CLAUDE_ARGS=--permission-mode auto` (or `acceptEdits` /
  `bypassPermissions`, or `/mode auto` per conversation) to keep the agent
  running unattended; pre-allow routine tools in `~/.claude/settings.json` so
  `default` only asks for the genuinely sensitive ones.

## [0.1.1] - 2026-06-04

### Fixed

- CI: bats tests no longer require the `claude` binary on `PATH`. The
  claude-code backend's `backend_check_dependencies` ran at source time
  in v0.1.0, which made it impossible to source the backend purely for
  its function definitions (as bats does) without the backend's runtime
  binaries installed. The check is now deferred to a
  `run_backend_dependency_check` helper that the entrypoint invokes; the
  runtime behaviour is unchanged (`wabox-bot` still fails fast at startup
  when `CLAUDE_BIN` isn't on `PATH`).

## [0.1.0] - 2026-06-04

### Added

- Initial extraction from
  [`wabox/examples/wabox-claude-code.sh`](https://github.com/rodgco/wabox/blob/v0.1.10/examples/wabox-claude-code.sh)
  as a standalone project.
- Pluggable agent backends via `WABOX_BOT_BACKEND` env var / `--backend` flag.
- Built-in backends:
  - `claude-code` — drives the Claude Code CLI with per-conversation
    `--resume`/`--session-id`, plus slash commands `/model`, `/mode`,
    `/system`.
  - `echo` — echoes the user's text back; useful for smoke-testing.
- Core slash commands `/clear`, `/reset`, `/ping`, `/status`, `/help`.
- Single-instance flock, per-conversation flock, atomic outbox writes via
  dot-prefixed `tmp` + `rename`, configurable `PROCESSED_DIR` for audit.
- Migration shim: existing flat `$SESSIONS_DIR/*.session` files (and the old
  `$STATE_DIR/agent.lock` path) from `wabox-claude-code.sh` are migrated into
  the namespaced layout on first run, with byte-identical slash-command
  behavior for the default `claude-code` backend.
- `install.sh` one-liner: clones to `~/.local/share/wabox-bot`, symlinks
  `bin/wabox-bot` into `~/.local/bin/`.

[Unreleased]: https://github.com/wabox-app/wabox-bot/compare/v0.7.0...HEAD
[0.7.0]: https://github.com/wabox-app/wabox-bot/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/wabox-app/wabox-bot/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/wabox-app/wabox-bot/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/wabox-app/wabox-bot/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/wabox-app/wabox-bot/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/wabox-app/wabox-bot/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/wabox-app/wabox-bot/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/wabox-app/wabox-bot/releases/tag/v0.1.0
