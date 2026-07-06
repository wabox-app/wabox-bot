# wabox-bot

A bash bridge between [wabox](https://github.com/rodgco/wabox)'s WhatsApp
inbox/outbox folders and a pluggable agent backend — by default, the
[Claude Code CLI](https://docs.claude.com/en/docs/claude-code/overview).

```
inbox/<id>.json  →  wabox-bot  →  per-conversation agent session  →  outbox/<id>.json
```

Each WhatsApp conversation gets its own persistent agent session. wabox-bot
takes care of:

- Reading envelopes from `inbox/` and writing replies atomically to `outbox/`.
- **Firing the WhatsApp "read receipt" the moment a message is picked up**,
  not after the agent finishes thinking (the user sees blue ticks immediately).
- **Single-instance locking** so two daemons can't fight over the same inbox.
- **Per-conversation locking** so messages from one sender process in order
  while different senders run in parallel.
- **Slash commands** (`/clear`, `/status`, `/ping`, `/help`, `/cwd`, plus
  backend-owned ones like `/model`, `/mode`, `/system` for the Claude Code
  backend).
- **Per-conversation working folder** — each conversation's agent runs in its
  own directory (auto `$STATE_DIR/work/<slug>` by default), so file operations
  stay isolated. Redirect one with `/cwd <path>` (e.g. `/cwd ~/Valter`);
  `/cwd default` reverts. The Claude Code backend scopes its session to the
  working folder, so changing `/cwd` starts a fresh agent session in the new
  folder (Claude can't resume a session across directories).
- **Image & audio messages** — an image is handed to the agent to read; a voice
  note is transcribed to text first via a pluggable command (`WABOX_TRANSCRIBE_CMD`).
  Captions are included. Media is staged under `<working-folder>/wabox-media/`.
- **Per-conversation overrides** persisted to disk and surviving restarts.

## Install

### From source

```bash
git clone https://github.com/wabox-app/wabox-bot ~/wabox-bot
~/wabox-bot/bin/wabox-bot
```

### One-liner

```bash
curl -fsSL https://raw.githubusercontent.com/wabox-app/wabox-bot/main/install.sh | bash
```

This clones into `~/.local/share/wabox-bot` and symlinks `bin/wabox-bot` into
`~/.local/bin/`. Uninstall:

```bash
rm -rf ~/.local/share/wabox-bot ~/.local/bin/wabox-bot
```

## Requirements

- bash 4+
- [`inotify-tools`](https://github.com/inotify-tools/inotify-tools) (provides `inotifywait`)
- `jq`
- `flock`, `timeout` (from `util-linux` / `coreutils`)
- The agent CLI you're using as a backend (e.g. `claude` for the default backend)
- A running [wabox](https://github.com/rodgco/wabox) instance providing the
  inbox/outbox folders

## Quick start

```bash
# wabox is already running and printed these:
export WABOX_INBOX=~/.local/share/wabox/inbox
export WABOX_OUTBOX=~/.local/share/wabox/outbox

wabox-bot   # default backend: claude-code
```

Send a WhatsApp message to the number paired with wabox. wabox-bot will pick
it up, route it through `claude -p` with `--session-id` (resumed on each
subsequent turn), and write the reply back to `outbox/`.

## Configuration file

All settings are environment variables; rather than exporting them by hand, put
them in one file:

```bash
wabox-bot --init-config            # writes ~/.config/wabox-bot/config
$EDITOR ~/.config/wabox-bot/config # edit values; lines you don't need stay as defaults
wabox-bot                          # loads the file on startup
```

The file is sourced as bash and every value is exported, so the backend CLI and
the transcription plugins inherit it. A variable set in your environment still
wins over the file. Use `--config <path>` for an alternate file (or set
`WABOX_BOT_CONFIG`), and `--print-config` to see the effective values (secrets
masked). Check the installed release with `wabox-bot --version` (or `-v`). The
variables themselves are listed below.

## Configuration

| Env var | Default | Meaning |
| --- | --- | --- |
| `WABOX_BOT_BACKEND` | `claude-code` | Which backend to load from `lib/backends/`. |
| `WABOX_INBOX` | from `wabox status` | Folder wabox writes inbound envelopes to. |
| `WABOX_OUTBOX` | from `wabox status` | Folder wabox watches for outbound jobs. |
| `STATE_DIR` | `$XDG_STATE_HOME/wabox-bot` | Where sessions and locks live. |
| `PROCESSED_DIR` | `$WABOX_INBOX/processed` | Where envelopes are parked after pickup. |
| `LOG_FILE` | `$STATE_DIR/agent.log` | Path for the agent log. |
| `KEEP_PROCESSED` | `1` | Keep envelopes in `PROCESSED_DIR` for audit. |
| `IGNORE_FROM_ME` | `1` | Skip envelopes where `fromMe=true`. |
| `GROUP_PER_PARTICIPANT` | `0` | If `1`, each person in a group gets a separate thread. |
| `DEBUG` | `0` | Verbose logging. |
| `WABOX_TRANSCRIBE_CMD` | (empty) | Speech-to-text command for inbound audio; the audio path is appended as the last argument, transcript read from stdout. Empty ⇒ audio is ignored. |
| `WABOX_TRANSCRIBE_TIMEOUT` | `120` | Max seconds for the transcription command. |

Ready-made transcribers for `WABOX_TRANSCRIBE_CMD` (faster-whisper, whisper.cpp,
OpenAI Whisper, Vosk, and any OpenAI-compatible API such as Groq) live in
[`plugins/`](plugins/) — each with its own install and configuration README.

Backend-specific env vars (for example `CLAUDE_BIN`, `CLAUDE_ARGS`,
`CLAUDE_TIMEOUT`) are documented in `docs/backends.md`.

## Backends

| Name | Status | Notes |
| --- | --- | --- |
| `claude-code` | built-in | Drives the `claude` CLI with `-p`, `--resume`, `--session-id`. |
| `echo` | built-in | Echoes the user's text back. Useful for smoke-testing the loop. |

Adding your own backend is a single bash file. See `docs/backends.md`.

## External tooling

Two read-only / client verbs form a stable, versioned contract so tools (such
as a TUI) can observe and act on the daemon without parsing `$STATE_DIR`
internals:

```bash
wabox-bot state --json          # snapshot of the daemon + every conversation
wabox-bot answer <slug> <yes|no> # answer a conversation's parked permission
```

- `state --json` prints one JSON object: a top-level `"version": 1` (the schema
  version — bump on a breaking change; consumers should hard-fail on a higher
  major), a `daemon` block (`running`, `pid`, `wabox_bot_version`, `backend`,
  and the resolved paths), and a `conversations` array sorted by last activity
  (newest first). Each
  conversation carries its `slug`, `conv_key`, `workdir`, lock state, last
  message, and the backend's view (session id, overrides, and any parked
  permission request). It takes no locks a running daemon would contend for.
- `answer <slug> <yes|no>` answers a parked permission the same way replying
  `sim`/`não` over WhatsApp would, and the reply still lands in the chat. It
  takes the per-conversation lock (not the single-instance lock), so it
  serializes against an in-flight turn.

Exit codes: `0` ok · `2` no fresh pending permission · `3` conversation lock
busy · `4` backend doesn't support answering · `1` usage/other. Both verbs pick
their backend and config from `WABOX_BOT_BACKEND` / `WABOX_BOT_CONFIG` (env or
the default config file). The two backend hooks behind them
(`backend_state_json`, `backend_answer_permission`) are optional and documented
in `docs/backends.md`.

## Migrating from `wabox/examples/wabox-claude-code.sh`

If you've been running the in-tree example from the wabox repo, see
[`docs/migrating-from-wabox-claude-code.md`](docs/migrating-from-wabox-claude-code.md).
TL;DR: env vars, slash commands, and conversation history all carry over.

## License

[MIT](LICENSE)
