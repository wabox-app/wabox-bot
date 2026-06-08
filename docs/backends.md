# Backends

A wabox-bot **backend** is the thing that turns a user's incoming text into a
reply. The bot loop handles WhatsApp plumbing (read-receipt timing, atomic
outbox writes, per-conversation locking, slash command routing); the backend
handles "what does this conversation actually say back."

A backend is a single bash file in `lib/backends/<name>.sh`. To select it,
either set `WABOX_BOT_BACKEND=<name>` in the environment or pass
`--backend <name>` on the command line.

## Built-in backends

| Name | Required env | What it does |
| --- | --- | --- |
| `claude-code` (default) | `CLAUDE_BIN` on `$PATH` (default: `claude`) | Drives `claude -p --output-format json` with `--session-id` / `--resume` so every WhatsApp conversation gets its own persistent Claude session. Owns the `/model`, `/mode`, `/system` slash commands. |
| `bob` | `BOB_BIN` on `$PATH` (default: `bob`), `jq`, `BOBSHELL_API_KEY` set | Drives IBM's Bob Shell with `bob -o json`. Each WhatsApp conversation gets its own thread via Bob's per-project `--resume latest` (sessions are keyed on the working folder, which wabox-bot already isolates per conversation). Defaults to `--yolo --chat-mode advanced` (override via `BOB_ARGS`); owns the `/model` and `/mode` slash commands. |
| `agy` | `AGY_BIN` on `$PATH` (default: `agy`), Antigravity logged in | Drives Google's Antigravity coding agent (`agy` print mode). An *autonomous* agent: with `--dangerously-skip-permissions` (the default `AGY_ARGS`) it reads files, runs commands, and edits code in the conversation's working folder. agy's `--continue` is global, so each conversation is pinned to an explicit id captured from agy's `--log-file` and resumed with `--conversation`. Prepends a concise-answer instruction (`AGY_REPLY_PREFIX`) since print mode otherwise narrates every step. Owns the `/model` slash command. |
| `echo` | none | Replies `echo: <text>` to every message. Useful for smoke-testing the loop without involving an LLM. |

## The contract

A backend file is `source`d into the bot's shell after `lib/log.sh` and
`lib/config.sh`. It must define two functions and may define five more.

### Required

```bash
backend_name() {
  # Echo the backend's short id. MUST match the filename stem.
  printf 'my-backend\n'
}

backend_reply() {
  # Args: slug, conv_key, stem
  #   slug     — sha1 of the conversation key (use as a filesystem-safe id)
  #   conv_key — the human-readable conversation key (mostly for logging)
  #   stem     — the inbox envelope basename without .json (for log lines)
  # stdin     — the user's text
  # stdout    — the reply text (no JSON envelope, just the body)
  # exit code:
  #   0    — success, reply on stdout
  #   124  — timed out (loop will substitute a "took too long" message)
  #   any  — error (loop will substitute a "hit an error" message)
  local slug="$1" conv_key="$2" stem="$3"
  local text
  text="$(cat)"
  ...
}
```

`backend_reply` may receive three optional trailing arguments —
`backend_reply <slug> <conv_key> <stem> [media_path] [media_type] [media_mime]`.
When the inbound message carries an image, `media_path` is the file's location
**relative to the working folder** (the backend's cwd), `media_type` is
`image`, and `media_mime` is its MIME type. Audio is transcribed upstream and
arrives as plain text, so backends only ever see `image` here. Backends that
don't handle media simply ignore these arguments.

### Optional

```bash
backend_check_dependencies() {
  # Called at startup, after lib/log.sh is sourced. Use need() (from
  # lib/config.sh) to verify any binaries your backend requires.
  need my-cli
}

backend_handle_command() {
  # Args: cmd_word, cmd_args, slug, conv_key, to, id, stem
  # Return 0 if you handled the command (and wrote the reply via
  # write_outbox), 99 to indicate "not mine — let the dispatcher fall
  # through to its 'Unknown command' reply."
  case "$1" in
    /my-cmd) ... ; return 0 ;;
    *)       return 99 ;;
  esac
}

backend_clear() {
  # Args: slug
  # Called by the core /clear handler under the per-conversation flock.
  # Delete whatever per-slug state your backend persisted.
  rm -f -- "$(backend_state_dir "$1")/session"
}

backend_help() {
  # Echo additional lines for /help, sandwiched between the core
  # "/clear /status /ping" block and the trailing "/help" line.
  cat <<'EOF'
/my-cmd <arg>    description here
EOF
}

backend_status_lines() {
  # Args: slug
  # Echo additional lines for /status, appended after "conv:" and
  # "backend:". The core dispatcher already prints both.
  printf 'session: %s\n' "$(my_session_for "$1")"
}
```

## What you can rely on

When your backend is sourced, the following are already in scope:

### Variables

| Name | What |
| --- | --- |
| `STATE_DIR`, `SESSIONS_DIR`, `LOCKS_DIR`, `LOG_FILE`, `WABOX_OUTBOX` | The standard paths set by `lib/config.sh`. |
| `SHUTDOWN_DRAIN_TIMEOUT` | Seconds the bot waits for in-flight backend calls on SIGTERM. Backends with longer replies should bump this. |

These backend variables can also be set in the wabox-bot config file
(`~/.config/wabox-bot/config`); it is sourced and exported before the backend
loads, so values there reach the backend and any subprocess it spawns.

### Functions

| Name | What |
| --- | --- |
| `log_info`, `log_warn`, `log_error`, `log_debug` | Timestamped + level-prefixed logging to both `LOG_FILE` and stderr. |
| `need <binary>` | Inside `backend_check_dependencies` — die early with a clear error if a binary isn't on `$PATH`. |
| `write_outbox <to> <text> <reply_to_id> <stem>` | Atomically write a wabox outbox envelope. Used by `backend_handle_command` when the backend has its own commands. |
| `backend_state_dir <slug>` | Returns (and `mkdir -p`'s) `$SESSIONS_DIR/<slug>/<backend>`. Always use this rather than computing the path yourself — keeps state per-backend so `/clear` doesn't wipe other backends' history. |
| `conversation_workdir <slug>` | Returns (and `mkdir -p`'s) the conversation's working folder — the auto default `$STATE_DIR/work/<slug>`, or the path the user set with `/cwd`. Backends that run an agent in a directory should `cd` into this before invoking it, so file operations stay isolated per conversation. Do the `cd` inside a subshell so it doesn't leak across turns; `backend_reply` already runs inside one (it's called from a command substitution in `lib/inbox.sh`). |

## A minimal backend

```bash
# shellcheck shell=bash
# lib/backends/uppercase.sh — replies with the user's text shouted back.

backend_name() {
  printf 'uppercase\n'
}

backend_reply() {
  local _slug="$1" _conv_key="$2" stem="$3"
  local text upper
  text="$(cat)"
  upper="${text^^}"
  log_info "[$stem] uppercase (${#text} chars)"
  printf '%s' "$upper"
}
```

That's it. `WABOX_BOT_BACKEND=uppercase wabox-bot` and you're done.

## Tips

- **Comments document the why.** The original `lib/backends/claude-code.sh`
  is a good model: long comment blocks explain Claude-specific quirks (why
  we pass `--session-id` on first run and `--resume` afterward, why
  `model_arg` is regex-validated before being passed to `claude --model`,
  why `/system` keeps newlines verbatim), not bash semantics.
- **Don't hold the per-conv flock yourself.** The bot already serializes
  same-sender calls into `backend_reply` via `$LOCKS_DIR/<slug>.lock`. If
  your `backend_handle_command` needs to mutate the same state, take the
  same flock — see how `claude-code.sh` does it for `/model` / `/mode` /
  `/system`.
- **Stdout is the reply body.** Don't print anything else to stdout from
  `backend_reply`. Logs go through `log_*` (which writes to `LOG_FILE` +
  stderr). Anything you `echo`/`printf` becomes the message your user
  receives on WhatsApp.
