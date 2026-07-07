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
- **Slash commands** (`/clear`, `/status`, `/ping`, `/help`, `/cwd`, `/memory`,
  `/update`, plus backend-owned ones like `/model`, `/mode`, `/system` for the
  Claude Code backend).
- **Per-conversation working folder** — each conversation's agent runs in its
  own directory (auto `$STATE_DIR/work/<slug>` by default), so file operations
  stay isolated. Redirect one with `/cwd <path>` (e.g. `/cwd ~/Valter`);
  `/cwd default` reverts. The Claude Code backend scopes its session to the
  working folder, so changing `/cwd` starts a fresh agent session in the new
  folder (Claude can't resume a session across directories).
- **Image & audio messages** — an image is handed to the agent to read; a voice
  note is transcribed to text first via a pluggable command (`WABOX_TRANSCRIBE_CMD`).
  Captions are included. Media is staged under `<working-folder>/.wabox/media/`.
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

### Updating

```bash
wabox-bot --check-update   # is a newer release published? (exit 0/10/1)
wabox-bot --update         # upgrade in place (git reset --hard to origin/main)
```

`--update` is the same `fetch` + `reset --hard` `install.sh` runs, so re-running
the one-liner works too. It prompts for confirmation on a terminal
(`WABOX_BOT_ASSUME_YES=1` to skip) and refuses to discard local changes in a dev
checkout unless `WABOX_BOT_UPDATE_FORCE=1`. The running daemon also checks on
startup and logs a notice (and shows it in `/status`) when a newer release
exists; disable with `WABOX_BOT_UPDATE_CHECK=0`. Over WhatsApp, `/update` checks
and `/update now` applies (gated by `WABOX_BOT_ALLOW_REMOTE_UPDATE`, default on) —
restart the daemon afterward for the new code to take effect.

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
| `WABOX_ACK_REACT` | (empty) | Emoji reacted to a message when its agent turn *starts* (a "working on it" signal). Empty ⇒ off. |
| `WABOX_SEND_DIR` | `send` | Folder (under each conversation's `.wabox/` plumbing dir) an agent drops files into to have them attached to its reply. |
| `WABOX_SEND_KEEP_DAYS` | `7` | How long archived (`.sent/`) copies of sent files are kept before `gc` prunes them. |
| `WABOX_MEDIA_DIR` | `media` | Folder (under `.wabox/`) inbound media is staged into. |
| `WABOX_MEDIA_KEEP_DAYS` | `30` | Age past which `gc` prunes staged inbound media. `0` ⇒ keep forever. |
| `WABOX_PROCESSED_KEEP_DAYS` | `90` | Age past which `gc` prunes `PROCESSED_DIR` envelopes (+ their media). `0` ⇒ keep forever. |
| `WABOX_QUOTE_REPLY` | `auto` | Quote-reply policy: `auto` (groups, or when a backlog is queued), `always`, or `never`. |
| `WABOX_WORKDIR_TEMPLATE` | shipped template | Instructions file seeded into a new default workdir (WhatsApp etiquette + memory practice). Empty ⇒ seeding off. |
| `CC_SHARED_SKILLS_DIR` | (empty) | Folder of shared agent skills symlinked into every new `claude-code` workdir as `.claude/skills`. Empty ⇒ off. |

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

## Sending files back

An agent can deliver files over WhatsApp — a generated PDF, a chart, an edited
image — by writing them into its conversation's send folder
(`<workdir>/.wabox/send/`, name via `WABOX_SEND_DIR`). Whatever files are in that
folder when the turn ends are attached to the reply (sorted by name; the reply
text becomes the first file's caption; core sends multiple files as separate
messages). An empty reply with files present becomes a files-only delivery.

The `claude-code` backend tells the agent about the folder automatically (turn
off with `CC_ADVERTISE_SEND_DIR=0`). The folder is cleared at the *start* of the
next turn — leftovers are archived to `.wabox/send/.sent/<id>/`, not deleted, so a
send that core is still reading isn't yanked out from under it; archives older
than `WABOX_SEND_KEEP_DAYS` are pruned. Failed or timed-out turns attach nothing
(their partial output waits in the folder and is archived next turn).

The loop — never the agent — chooses the recipient and builds the file list, so a
prompt-injected "send this to …" has no channel to act through. A compromised
agent can still copy files *it can already read* into the folder; that's the
existing agent-permission boundary, so run the agent with a working directory and
permissions you trust.

## Memory & skills

A new conversation's default workdir is seeded (on its first agent turn) with an
instructions file teaching the agent how to behave over WhatsApp: use WhatsApp
markup instead of Markdown (`*bold*`, `_italic_`, no headings or `[]()` links),
keep replies chat-sized, push long output to the send folder, and match the
user's language. The `claude-code` backend writes it as `CLAUDE.md`; `agy` and
`bob` as `AGENTS.md` (both CLIs auto-load their file from the working folder). It
is seed-if-absent — your edits, or the agent's, always win. Point
`WABOX_WORKDIR_TEMPLATE` at your own file to customize it, or set it empty to
seed nothing. Only *default* workdirs are seeded; a `/cwd`-redirected folder (the
user's own directory) is left untouched.

Durable memory lives in `<workdir>/MEMORY.md` — one plain file per conversation.
The seeded instructions tell the agent to read it and to append short bullets for
facts worth keeping ("my wife is Ana", "reports go out Fridays") and prune stale
ones. Unlike session history, it **survives `/clear`**, so resetting a wedged or
bloated session doesn't wipe what the agent knows about you. `/memory` shows the
current file over WhatsApp; edit it in chat ("esqueça X") or with `$EDITOR`. It's
a file you can `cat` and audit — deliberately not a hidden memory system.

Shared skills: set `CC_SHARED_SKILLS_DIR` to a folder you curate (a git clone,
whatever) and the `claude-code` backend symlinks it into every new workdir as
`.claude/skills` — one folder, every conversation follows. Treat it like code you
run: every chat gets those skills. A conversation can go local by replacing the
symlink with a real directory.

## Workdir lifecycle

All bot-owned plumbing lives under one hidden dir per conversation,
`<workdir>/.wabox/` — staged inbound media (`.wabox/media/`) and the
outgoing-file staging folder with its archives (`.wabox/send/`, `.wabox/send/.sent/`).
Keeping it hidden and consolidated matters most after `/cwd`: your own folder
stays clean instead of sprouting bare `wabox-media/` / `wabox-send/` dirs.

> **Migration:** the earlier flat `wabox-send/` / `wabox-media/` folders (which
> shipped only briefly) are moved into `.wabox/` the first time a conversation is
> touched, leaving a relative compat symlink at the old name so in-flight jobs and
> muscle memory keep working. `gc` removes those symlinks once they go dangling.

**Sizes.** `wabox-bot state --json --sizes` adds `workdir_bytes` (the whole
conversation folder) and `botdir_bytes` (the reclaimable `.wabox/` share) per
conversation — it's opt-in because it runs `du`. `/status` shows a
human-readable `pasta:` line over WhatsApp.

**`gc [slug] [--yes]`** prunes reclaimable plumbing by age — dry-run by default
(it prints what would go and the byte total), applying only with `--yes`. It
touches nothing you or the agent authored: only staged media past
`WABOX_MEDIA_KEEP_DAYS` (30), send archives past `WABOX_SEND_KEEP_DAYS` (7), and
`PROCESSED_DIR` envelopes past `WABOX_PROCESSED_KEEP_DAYS` (90; `0` any of these
⇒ keep forever). No slug ⇒ all conversations; a busy conversation is skipped, not
waited on. Run it from cron next to the heartbeat:

```cron
# prune reclaimable plumbing nightly at 04:00
0 4 * * * /path/to/wabox-bot gc --yes >/dev/null 2>&1
```

**`rm <slug> [--yes]`** deletes a conversation completely — its session state and,
when the workdir is the auto default, that folder too. A `/cwd`-redirected folder
is *your* folder: `rm` removes the pointer to it and prints the path it left
behind, never the contents. It prompts unless `--yes`, takes the conversation lock
(busy ⇒ exit `3`), and is CLI-only — deletion is deliberately not promptable from
chat. The next message from that contact starts a fresh conversation.

## External tooling

A small set of client verbs forms a stable, versioned contract so tools (such as
a TUI) can observe and act on the daemon without parsing `$STATE_DIR` internals:

```bash
wabox-bot state --json                   # snapshot of the daemon + every conversation
wabox-bot transcript <slug> [--limit N]  # one conversation's message history
wabox-bot cmd <slug> "<slash command>"   # run /cwd, /model, /mode, /system, /clear …
wabox-bot answer <slug> <yes|no>         # answer a conversation's parked permission
wabox-bot send <slug> [text]             # deliver a message (no agent turn)
wabox-bot prompt <slug> <text>           # run an agent turn and deliver its reply
```

- `state --json` prints one JSON object: a top-level `"version": 1` (the schema
  version — bump on a breaking change; consumers should hard-fail on a higher
  major), a `daemon` block (`running`, `pid`, `wabox_bot_version`, `backend`,
  and the resolved paths), and a `conversations` array sorted by last activity
  (newest first). Each
  conversation carries its `slug`, `conv_key`, `workdir`, lock state, last
  message, and the backend's view (session id, overrides, and any parked
  permission request). It takes no locks a running daemon would contend for.
- `transcript <slug> [--limit N]` prints one JSON object (`"version": 1`) with
  the conversation's `turns` — inbound messages (from processed envelopes) and
  outbound replies (from wabox-core's `outbox/sent` archive) merged and ordered
  oldest-first, each with `at`, `direction`, `text`, and a `media` marker.
  `total` is the full history size, `count` the number returned (last `--limit`,
  default 200). Needs `KEEP_PROCESSED=1` for inbound history; `keep_processed`
  reflects that. Like the other verbs it does the slug→conversation routing so
  consumers never scan wabox's directories themselves.
- `cmd <slug> "<slash command>"` runs a conversation's slash command through the
  exact same path a WhatsApp message would (same validation, same per-conversation
  locking the commands take themselves), but **captures the reply to stdout
  instead of sending it over WhatsApp** — so a tool can change a conversation's
  working folder, model, mode, system prompt, or clear its session without
  messaging the user. Exit `0` when handled (reply on stdout), `1` on usage /
  unknown slug / non-command input. This is the write half of the contract;
  `state --json` reads the same settings back.
- `answer <slug> <yes|no>` answers a parked permission the same way replying
  `sim`/`não` over WhatsApp would, and the reply still lands in the chat. It
  takes the per-conversation lock (not the single-instance lock), so it
  serializes against an in-flight turn.
- `send <slug> [text]` / `prompt <slug> <text>` are the outbound-initiated
  verbs — see **Proactive messaging** below.

Exit codes: `0` ok · `2` no fresh pending permission · `3` conversation lock
busy · `4` backend doesn't support answering · `1` usage/other. Both verbs pick
their backend and config from `WABOX_BOT_BACKEND` / `WABOX_BOT_CONFIG` (env or
the default config file). The two backend hooks behind them
(`backend_state_json`, `backend_answer_permission`) are optional and documented
in `docs/backends.md`.

## Proactive messaging

Everything above is reactive — the bot only speaks when a message arrives. Two
verbs let *you* (or a scheduler acting for you) start the conversation:

```bash
wabox-bot send <slug> [text]            # dumb delivery — no agent involved
wabox-bot send --to <jid|number> [text] # to a recipient with no prior chat
wabox-bot prompt <slug> <text>          # a real agent turn, reply delivered
```

- **`send`** writes a single outbox job and returns. No daemon is required
  (wabox sends any job that lands in the outbox) and no lock is taken — the write
  is atomic. Text omitted or `-` reads stdin (multi-line friendly); `--file
  <path>` (repeatable) attaches files. `<slug>` targets an existing conversation
  and records a `direction:"out"` entry in its `last_message.json`; `--to` sends
  to any JID or bare number (wabox normalizes it) with no conversation state —
  operator-only power, identical to typing into the app.
- **`prompt`** runs the canonical turn: it takes the per-conversation lock,
  resolves the working directory, and feeds the text to the same `backend_reply`
  an inbound message would, then delivers the reply and records it. Because it's
  a real turn, **the session learns what was said** — a later "what did you
  remind me about?" works — and the turn can attach files it writes into the send
  folder. The flip side: prompt turns are visible to the agent as prior history
  and grow the session's context; `/clear` resets it as usual.

**NOOP suppression.** If a `prompt` reply is empty or exactly `NOOP` (after
trimming; the token is configurable via `WABOX_PROMPT_NOOP`), nothing is
delivered and `prompt` exits `5`. This is what makes a *heartbeat* work: a
scheduled prompt with a standing instruction that tells the agent to answer
`NOOP` unless something needs you, so it speaks only when it has something to
say.

Exit codes — `send`: `0` sent · `1` usage / unknown slug / unreadable file.
`prompt`: `0` delivered · `1` usage / unknown slug · `3` lock busy · `5`
suppressed (NOOP — success for cron, but distinguishable) · `124` backend
timeout.

See [`examples/heartbeat/`](examples/heartbeat/) for a complete cron and systemd
walkthrough of a morning-digest / reminder heartbeat.

## Migrating from `wabox/examples/wabox-claude-code.sh`

If you've been running the in-tree example from the wabox repo, see
[`docs/migrating-from-wabox-claude-code.md`](docs/migrating-from-wabox-claude-code.md).
TL;DR: env vars, slash commands, and conversation history all carry over.

## License

[MIT](LICENSE)
