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
| `claude-code` (default) | `CLAUDE_BIN` on `$PATH` (default: `claude`) | Drives `claude -p --output-format json` with `--session-id` / `--resume` so every WhatsApp conversation gets its own persistent Claude session. With its default `--permission-mode default`, any tool the agent isn't pre-allowed to run surfaces as a `permission_denials` entry instead of being silently auto-approved; the backend parks that turn, asks you over WhatsApp (`sim`/`não`), and on approval resumes the same session granting exactly the denied tools (parked state expires after `CC_PERMISSION_TIMEOUT`, default 600s). Owns the `/model`, `/mode`, `/system` slash commands. |
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

`backend_reply` may receive four optional trailing arguments —
`backend_reply <slug> <conv_key> <stem> [media_path] [media_type] [media_mime] [media_json]`.
When the inbound message carries stageable media, `media_path` is the file's
location **relative to the working folder** (the backend's cwd), `media_type` is
`image` or `document`, and `media_mime` is its MIME type. Audio is transcribed
upstream and arrives as plain text; video, stickers, and oversize documents
never reach the backend as media (a caption on them arrives as plain text with a
bracketed note). So backends see `image | document` here, and should read the
file at `media_path` — the MIME helps for the extension-less names common on
WhatsApp forwards. Backends that don't handle media simply ignore these arguments.

**One turn can carry several media.** Because the loop batches a burst (an image
with a caption, or several photos and a line of text — see `WABOX_BATCH_WINDOW`
and `lib/batch.sh`) into a single `backend_reply` call, `media_path`/`media_type`/
`media_mime` describe only the **first** item. The full set is `media_json`
(arg 7): a JSON array of `{path, type, mime}` objects in arrival order (`[]` when
there's no media). A backend that wants to show the agent *all* the files — like
`claude-code`, which composes one instruction line per item — should read
`media_json`; one that only handles a single file can keep using the first-item
positional args and gracefully see just the first of a burst.

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

backend_seed_workdir() {
  # Args: slug, workdir
  # Called by conversation_workdir() right after it creates a conversation's
  # *default* workdir — NEVER for a /cwd-redirected folder (that's the user's
  # own directory; core guarantees it won't call you there). Runs on EVERY turn,
  # so it must be cheap and strictly seed-if-absent (idempotent). It must emit
  # NOTHING on stdout — conversation_workdir's output is captured by callers.
  # A non-zero return is logged as a warning and never fails the turn.
  # Typical use: drop an instructions file the agent auto-loads from cwd
  # (CLAUDE.md for claude, AGENTS.md for agy/bob) from $WABOX_WORKDIR_TEMPLATE.
  local slug="$1" workdir="$2"
  [[ -n "${WABOX_WORKDIR_TEMPLATE:-}" && -r "$WABOX_WORKDIR_TEMPLATE" \
     && ! -e "$workdir/AGENTS.md" ]] &&
    cp -- "$WABOX_WORKDIR_TEMPLATE" "$workdir/AGENTS.md"
  return 0
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

backend_state_json() {
  # Args: slug
  # Echo a JSON object with your backend's view of a conversation, for
  # `wabox-bot state --json`. The shape is fixed:
  #   {
  #     "session_id": <string|null>,
  #     "overrides":  { "model": <string|null>,
  #                     "mode":  <string|null>,
  #                     "system":<string|null> },
  #     "pending_permission": <object|null>
  #   }
  # Return null for anything you don't track. If you never park a permission
  # request, always emit "pending_permission": null. When you do, use whatever
  # object shape your tooling needs (claude-code emits
  #   { asked_at, expires_at, tools: [..], question: ".." }).
  # Missing hook ⇒ core fills all of these with null. Assemble with `jq -n`;
  # invalid JSON is discarded and replaced with the null default.
  jq -n --arg sid "$(my_session_for "$1")" \
    '{session_id: (if $sid == "" then null else $sid end),
      overrides: {model: null, mode: null, system: null},
      pending_permission: null}'
}

backend_answer_permission() {
  # Args: slug, conv_key, decision ("yes" | "no")
  # Answer a parked permission request from the `wabox-bot answer` CLI verb,
  # through the same path a WhatsApp reply would take. Called under the
  # per-conversation flock (answer_main already holds it), so no extra locking.
  # Echo the reply text on stdout — the core delivers it to the chat.
  # Exit code:
  #   0    — answered (reply on stdout); may re-park if a new denial appears
  #   2    — nothing fresh to answer (no pending permission)
  #   any  — error
  # Missing hook ⇒ `answer` exits 4 (backend doesn't support it).
  cc_has_pending_permission "$1" || return 2
  ...
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

## Rich replies (loop-level, no contract change)

Reactions, outgoing files, and quote-replies are all handled by the loop, not
the backend — the reply contract stays "text on stdout". You get them for free:

- **Ack reaction** — when `WABOX_ACK_REACT` is set, the loop reacts to the
  inbound message the moment it hands off to your `backend_reply`. Nothing to do.
- **Quote-replies** — the loop decides whether to quote (see `WABOX_QUOTE_REPLY`)
  and computes `replyTo` itself. Nothing to do.
- **Outgoing files** — any file that exists in
  `<workdir>/.wabox/$WABOX_SEND_DIR/` (default `.wabox/send/`, under the hidden
  `.wabox/` plumbing dir of `conversation_workdir`) when your turn returns is attached to the reply,
  sorted by name, with the reply text as the first file's caption. The folder is
  cleared (leftovers archived to `.sent/`) at the *start* of each turn, so only
  files this turn produced are sent. Failed/timed-out turns attach nothing.

  Your backend doesn't need to touch this — but the *agent* it drives has to know
  the folder exists. The `claude-code` backend appends a one-sentence
  system-prompt hint when `CC_ADVERTISE_SEND_DIR=1` (default). For other
  backends, do the equivalent through whatever prompt-shaping knob you have:
  `agy` prepends `AGY_REPLY_PREFIX`; `bob` users can add the instruction via
  `BOB_ARGS`. The mechanism is the same — tell the agent to write files it wants
  delivered into `<workdir>/.wabox/send/`. The `claude-code` hint interpolates
  the resolved absolute path (via `senddir_path`), so it always names the real
  location even if `WABOX_SEND_DIR` is customized.

  Note: the loop attaches whatever readable files land in the folder — a
  compromised or careless agent could copy a file it shouldn't. That's the
  existing agent-permission boundary (the agent can already read those files),
  not a new one; the loop never lets the agent choose the *recipient*.

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
