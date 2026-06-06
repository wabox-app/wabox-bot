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
- **Per-conversation overrides** persisted to disk and surviving restarts.

## Install

### From source

```bash
git clone https://github.com/rodgco/wabox-bot ~/wabox-bot
~/wabox-bot/bin/wabox-bot
```

### One-liner

```bash
curl -fsSL https://raw.githubusercontent.com/rodgco/wabox-bot/main/install.sh | bash
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

Backend-specific env vars (for example `CLAUDE_BIN`, `CLAUDE_ARGS`,
`CLAUDE_TIMEOUT`) are documented in `docs/backends.md`.

## Backends

| Name | Status | Notes |
| --- | --- | --- |
| `claude-code` | built-in | Drives the `claude` CLI with `-p`, `--resume`, `--session-id`. |
| `echo` | built-in | Echoes the user's text back. Useful for smoke-testing the loop. |

Adding your own backend is a single bash file. See `docs/backends.md`.

## Migrating from `wabox/examples/wabox-claude-code.sh`

If you've been running the in-tree example from the wabox repo, see
[`docs/migrating-from-wabox-claude-code.md`](docs/migrating-from-wabox-claude-code.md).
TL;DR: env vars, slash commands, and conversation history all carry over.

## License

[MIT](LICENSE)
