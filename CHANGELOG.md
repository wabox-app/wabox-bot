# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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

[Unreleased]: https://github.com/wabox-app/wabox-bot/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/wabox-app/wabox-bot/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/wabox-app/wabox-bot/releases/tag/v0.1.0
