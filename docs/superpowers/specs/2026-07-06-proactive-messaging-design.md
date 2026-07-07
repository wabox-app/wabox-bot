# Proactive messaging: `send`, `prompt`, and the heartbeat pattern

**Date:** 2026-07-06
**Status:** Draft (design)
**Depends on:** rich replies (`write_outbox` extras arg, `lib/senddir.sh`) — in flight; only the `--file` flag and prompt-turn attachments block on it.

## Problem

wabox-bot is purely reactive: nothing goes out unless a message came in.
Reminders, digests, and alerts — the highest-value personal-agent features —
are impossible. There is also no way for the operator (or a cron job acting
for them) to run an agent turn and deliver its result to a conversation.

## Goal

Two client verbs in the `answer`/`cmd` family, plus a documented pattern:

- `wabox-bot send <slug> [text]` — deliver a message to a conversation, no
  agent involved.
- `wabox-bot prompt <slug> <text>` — run an agent turn (same session, workdir,
  and lock as an inbound message) and deliver the reply.
- **Heartbeat**: cron/systemd-timer + `prompt` with a standing instruction and
  a suppression sentinel — the agent speaks only when it has something to say.

## Non-goals

- A scheduler inside wabox-bot. cron/systemd own time; we ship examples, not a
  daemon feature. (Keeps the "no control plane" security story intact.)
- A `/remind`-style slash command (the agent itself can be asked in-chat to
  set up crontab entries in its workdir if the operator allows it — that's an
  agent capability, not bot plumbing).
- Broadcast / multi-recipient sends. One conversation per invocation.
- Exposing `prompt` over WhatsApp. Users already message the agent normally.

## Decisions

- **Two verbs, not one.** `send` is dumb delivery (writes an outbox job,
  daemon not required, no locks — the write is atomic). `prompt` is a real
  turn: the session learns what was said, so a later "what did you remind me
  about?" works. Collapsing them ("send with optional agent") muddles exit
  codes and locking; the split mirrors `state` (read) vs `cmd` (write).
- **`send` interface.** `wabox-bot send <slug> [text]`; text omitted or `-`
  reads stdin (multi-line friendly). `--to <jid|number>` replaces the slug for
  recipients with no prior conversation (operator-only power; documented as
  such). `--file <path>` (repeatable) attaches files via the extras arg —
  lands only after rich replies. Writes `last_message.json` with
  `direction: "out"` (additive to the state contract; consumers already
  tolerate the field).
- **`prompt` runs the canonical turn.** Takes the per-conversation flock
  (`flock -w`, busy ⇒ exit 3, mirroring `answer`); resolves workdir; feeds the
  text to `backend_reply` with a synthetic stem `prompt-<epoch>-<pid>`; wraps
  with `senddir_prepare`/`senddir_collect` so a heartbeat turn can attach
  files (e.g. "send me the weekly report PDF"); delivers via `write_outbox` to
  `conv_key%%|*`; updates `last_message.json` (`direction: "out"`). Media args
  stay empty — prompts are text-only.
- **Suppression sentinel: `NOOP`.** If the reply, after trimming whitespace,
  is exactly `NOOP` (or empty), nothing is delivered and `prompt` exits `5`.
  The heartbeat standing prompt instructs the agent to answer `NOOP` when
  there's nothing worth saying. Sentinel chosen over "empty means skip" alone
  because agents reliably *say* something; an explicit token is promptable and
  greppable in cron logs. Configurable via `WABOX_PROMPT_NOOP` (default
  `NOOP`) for prompt-language freedom.
- **Permission parking degrades gracefully.** If a `prompt` turn parks a
  permission request (claude-code default mode), the question text *is* the
  reply — it's delivered to the chat and the user answers there or via
  `wabox-bot answer`. No special casing; the existing flow already chains.
  Heartbeat prompts should be written to avoid gated tools, or the
  conversation can be switched to a pre-allowed toolset via `/mode`.
- **Exit codes (stable contract):** `0` delivered · `1` usage / unknown slug ·
  `3` lock busy (`prompt` only) · `5` suppressed (NOOP — success for cron, but
  distinguishable) · `124` backend timeout passthrough (`prompt` only).
- **Heartbeat ships as examples, not features.** `examples/heartbeat/`:
  a crontab line and a systemd user timer+service pair invoking
  `wabox-bot prompt <slug> "$(cat standing-prompt.txt)"`, plus a commented
  `standing-prompt.txt` (check X/Y; reply `NOOP` unless action needed; keep it
  short; you may drop files in wabox-send/). README section "Proactive
  messaging" walks through a morning-digest setup end to end.

## Architecture

- **Create `lib/send.sh`** — `send_main`: arg parsing (`--to`, `--file`,
  stdin), slug→conv_key resolution (same pattern as `answer.sh`), extras
  assembly, `write_outbox`, `last_message.json` update.
- **Create `lib/prompt.sh`** — `prompt_main`: flock, workdir, senddir
  lifecycle, `backend_reply`, sentinel check, delivery, `last_message.json`.
- **Modify `bin/wabox-bot`** — `send` / `prompt` subcommands + `usage()`.
- **Create `examples/heartbeat/`** — crontab snippet, systemd timer+service,
  `standing-prompt.txt`.
- **Modify `lib/state.sh`** — none expected (`last_message` passes through);
  verify `direction:"out"` renders unmodified.
- **Docs** — README "Proactive messaging" section; CHANGELOG.

## Risks / notes

- `prompt` and the daemon can both run turns; the shared flock serializes
  them, but a long heartbeat turn delays inbound replies for that conversation
  (visible as a longer wait — same as any busy turn today). Heartbeat prompts
  should stay small; noted in the example.
- A `prompt` turn extends the same session the user chats in: session history
  gains operator-injected turns. That's the point (context continuity), but
  docs must say heartbeats are visible to the agent as prior turns and count
  toward session growth — `/clear` resets as usual.
- `send --to` can message any JID. It's the operator's own WhatsApp and
  identical power to typing in the app; no gate. Remote surfaces (slash
  commands) deliberately get no equivalent.
- wabox-tui gains "local chat" (its v2 flagship) nearly for free: `send` is
  the write primitive it was waiting for.
