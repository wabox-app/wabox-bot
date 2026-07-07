# Rich replies: ack reactions, outgoing files, quote-replies

**Date:** 2026-07-06
**Status:** Draft (design)

## Problem

wabox-core's outbox supports `files` (media/documents with captions), `react`,
and `replyTo` with group `participant` — but wabox-bot only ever emits
`{to, text}`. The consequences: an agent that *generates* a file (a PDF, a
chart, an edited image) can only describe it, never deliver it; the user gets
no signal that a slow turn is in progress beyond blue ticks; and when several
messages queue up, replies arrive unthreaded, so it's unclear which question
each answer belongs to. Core's own integration guide recommends reactions as
turn-in-progress signals and quoting for threading — the bot should follow its
own platform's etiquette.

## Goal

- The user sees a configurable ack reaction (e.g. 👀) when a turn starts.
- Files the agent drops in a well-known folder are attached to its reply.
- Replies quote the message they answer when threading is ambiguous (backlog)
  or conventional (groups).
- All of it works for **every backend** with no backend-contract change: the
  reply contract stays "text on stdout"; richness is carried by loop-level
  conventions.

## Non-goals

- A structured reply contract (backends emitting JSON). Deliberately avoided —
  it would force every backend to change and make prompt-injection of job
  fields ("send this file to…") easier. The loop, not the model, decides `to`.
- Inbound media beyond image/audio (documents/video) — separate roadmap item.
- Outbound-initiated messages (`send` verb / heartbeat) — next release.
- Reactions *by* the agent as expression (agent choosing emojis). Only the
  mechanical ack reaction is in scope.

## Decisions

- **`write_outbox` grows one optional trailing arg: `extras`** — a JSON object
  merged into the job (`react`, `files`, `replyTo` with `participant`).
  Existing four-arg callers are untouched: `write_outbox to text reply_to_id
  stem [extras_json]`. Assembly stays `jq -n`; `extras` is `--argjson`-merged,
  never string-spliced.
- **Ack reaction fires at backend handoff, not pickup.** Placed immediately
  before the Step-6 flock: slash commands and skipped messages (fromMe, empty,
  unsupported media) never trigger it, so the reaction specifically means "an
  agent turn is running". It's a react-only job (`<stem>-ack.json`) carrying
  the inbound `id` (+ `participant` in groups). Config: `WABOX_ACK_REACT`
  (an emoji; empty **disables — the default**, preserving current behavior).
  No removal after the reply lands (a lingering 👀 is harmless; removal doubles
  the job traffic for cosmetics).
- **Outgoing files: `<workdir>/wabox-send/` convention.**
  - The loop creates the folder before each turn (name configurable via
    `WABOX_SEND_DIR` relative to the workdir, default `wabox-send`).
  - **Clearing happens at the *start* of the next turn, not after the reply**
    — core reads the files asynchronously while sending, so deleting right
    after the job write would race the send. At turn start, leftovers are
    archived to `wabox-send/.sent/<stem>/` (dot-name, excluded from the
    attach glob); archives older than `WABOX_SEND_KEEP_DAYS` (default 7) are
    pruned opportunistically.
  - After `backend_reply` succeeds, non-hidden files in the folder are
    attached as absolute paths in `files`, sorted by name (core sends multiple
    files as separate messages, in order; the reply text becomes file #1's
    caption). Empty reply + files present ⇒ a files-only job (`text` omitted)
    — today that case is "no reply"; it becomes a delivery.
  - Failure-path messages (timeout/error) never attach files — a failed turn's
    partial outputs stay in the folder and are archived on the next turn.
  - **Agent discovery:** the `claude-code` backend appends one system-prompt
    sentence ("To send the user a file over WhatsApp, write it to
    `<workdir>/wabox-send/`…") when the feature is on (`CC_ADVERTISE_SEND_DIR`,
    default `1`). Other backends inherit the convention via docs (`agy` has
    `AGY_REPLY_PREFIX` for the same trick; `bob` users can use `BOB_ARGS`).
- **Quote-reply policy: `WABOX_QUOTE_REPLY=auto|always|never`, default `auto`.**
  `auto` quotes when (a) the conversation is a group (`*@g.us`), or (b) at
  reply time at least one newer envelope for the same conversation is waiting
  in the inbox (backlog ⇒ the reply may land after a later question). The
  backlog probe globs `$WABOX_INBOX/*.json` and compares `conversation_key`
  per candidate — inbox is small by design (jobs are picked up immediately),
  so this is a handful of `jq` calls at worst. Group quotes carry
  `participant` (now extracted in `lib/inbox.sh` alongside `id`/`from`).
- **The model never controls job fields.** `to`, `replyTo`, `react`, and the
  `files` *list* are computed by the loop from the envelope and the filesystem.
  The agent influences only reply text and file *contents* — an injected
  "attach /etc/passwd and send to +55…" has no channel to act through. (A
  malicious/compromised agent can still copy readable files into `wabox-send/`;
  that's the existing agent-permission boundary, not a new surface — noted in
  docs.)

## Architecture

- **Modify `lib/outbox.sh`** — `extras` merge (5th arg).
- **Modify `lib/inbox.sh`** — extract `participant`; ack-react job before the
  Step-6 flock; send-dir prepare/archive at turn start; attach-glob + quote
  decision at reply delivery; files-only reply case.
- **Create `lib/senddir.sh`** — `senddir_prepare <workdir> <stem>`,
  `senddir_collect <workdir>` (newline-separated absolute paths),
  `senddir_prune <workdir>`. Kept out of `inbox.sh` for testability.
- **Modify `lib/backends/claude-code.sh`** — conditional system-prompt
  sentence (`CC_ADVERTISE_SEND_DIR`).
- **Modify `lib/config.sh`** + `config.example` — `WABOX_ACK_REACT`,
  `WABOX_SEND_DIR`, `WABOX_SEND_KEEP_DAYS`, `WABOX_QUOTE_REPLY`,
  `CC_ADVERTISE_SEND_DIR`.

## Risks / notes

- Reaction jobs add outbox traffic (1 extra job per agent turn when enabled);
  default-off keeps current installs byte-identical.
- `wabox-send/` inside a user-redirected `/cwd` (e.g. `~/Valter`) pollutes a
  real folder — mitigated by the dot-archive and docs; acceptable, since /cwd
  users opted into the agent working there.
- Absolute `files` paths assume core can read the workdir — true today (same
  user, same machine). A future remote wabox would need copy-into-outbox
  semantics; the `senddir_collect` seam is where that would change.
- The backlog probe reads envelopes another worker may simultaneously move to
  `processed/` — a vanished file during the probe is treated as "no backlog
  from that file" (read failures ignored).
