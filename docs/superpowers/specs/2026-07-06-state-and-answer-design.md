# `state --json` and `answer` CLI verbs

**Date:** 2026-07-06
**Status:** Draft (design)
**Consumer:** [wabox-tui](../../../../wabox-tui/SPEC.md) — a local TUI that must observe and act on wabox-bot without parsing `$STATE_DIR` internals.

## Problem

External tooling (first consumer: wabox-tui) needs to list conversations, read
per-conversation status (overrides, session, parked permission requests), check
daemon health, and answer a parked permission from the local machine. Today all
of that lives in wabox-bot's private state layout, and a parked permission can
only be answered by messaging "sim"/"não" over WhatsApp. Exposing the state
layout directly would freeze internals we want to keep refactorable.

## Goal

Two additive CLI verbs forming a stable, versioned contract:

- `wabox-bot state --json` — read-only snapshot of daemon + all conversations.
- `wabox-bot answer <slug> <yes|no>` — answer a parked permission request
  through the same code path a WhatsApp reply takes.

## Non-goals

- A human-readable `state` output (JSON only in v1; pretty output can come later).
- A generic `wabox-bot cmd <slug> <slash-command>` verb (P1 in the TUI spec;
  needs its own design).
- Sending arbitrary messages from the CLI (the TUI's v2 "local chat").
- Exposing or documenting the `$STATE_DIR` layout — this design exists to avoid that.

## Decisions

- **Subcommands, not flags.** `bin/wabox-bot` gains positional subcommands
  (`state`, `answer`) beside the existing flag modes; no args still means "run
  the daemon", so nothing breaks.
- **The slug↔conv_key mapping must be persisted.** Slugs are `sha1(conv_key)`
  — one-way — so the loop starts writing `$SESSIONS_DIR/<slug>/conv_key`
  (idempotent, on every handled envelope). Same moment, it writes
  `$SESSIONS_DIR/<slug>/last_message.json`
  (`{at, direction:"in", text_preview}`) so `state` can sort conversations by
  activity without scanning `processed/`. v1 records inbound only; the
  `direction` field leaves room for outbound later.
- **Daemon liveness via the existing lock.** `state` probes `PID_LOCK` with
  `flock -n`: acquisition succeeding means no daemon. The daemon additionally
  writes `$$` into the lock file after acquiring, so `state` can report `pid`.
- **Backend-owned state stays backend-owned.** Two new *optional* backend
  hooks (documented in `docs/backends.md`):
  - `backend_state_json <slug>` — echo a JSON object with the backend's view:
    `{session_id, overrides:{model,mode,system}, pending_permission}`.
    Missing hook ⇒ core fills these with `null`.
  - `backend_answer_permission <slug> <conv_key> <yes|no>` — validate a fresh
    pending permission (exit 2 if none), run the approval/denial, echo the
    reply text for the user. Missing hook ⇒ `answer` exits 4 (unsupported).
  `claude-code` implements both by reusing `cc_load_pending_permission`,
  `cc_has_pending_permission`, and `cc_handle_permission_response` (called
  with synthetic text `sim`/`não`, a synthetic stem like `answer-<epoch>`, and
  the workdir resolved through `lib/workdir.sh`).
- **`answer` respects the daemon's locking.** It takes the same
  per-conversation lock (`$LOCKS_DIR/<slug>.lock`) with `flock -w
  $ANSWER_LOCK_WAIT` (default 5 s); busy ⇒ exit 3. It does **not** take the
  single-instance lock — it's not a second daemon, and the conversation lock
  is what serializes it against an in-flight turn for that conversation.
- **The reply still reaches WhatsApp.** `answer` writes the hook's reply text
  via `write_outbox`, targeting the chat JID (for `GROUP_PER_PARTICIPANT`
  keys of the form `from|participant`, the part before `|`). The user sees the
  outcome in the conversation exactly as if they had answered there.
- **`state` takes no locks.** Pure reads plus non-blocking `flock -n` *probes*
  (acquire-and-release on a private fd) for `daemon.running` and per-slug
  `locked`. A probe can hold a free lock for microseconds; the daemon's
  blocking `flock -x` tolerates that.
- **Versioned contract.** Top-level `"version": 1`; consumers hard-fail on a
  higher major. Exit codes: `0` ok · `2` no fresh pending permission ·
  `3` conversation lock busy · `4` backend lacks the hook · `1` usage/other.

## Output shape (`state --json`, version 1)

```jsonc
{
  "version": 1,
  "daemon": { "running": true, "pid": 12345, "backend": "claude-code",
              "inbox": "…", "outbox": "…", "state_dir": "…", "log_file": "…" },
  "conversations": [
    { "slug": "…", "conv_key": "…", "workdir": "…", "workdir_is_default": true,
      "locked": false,
      "session_id": "…",
      "overrides": { "model": null, "mode": null, "system": null },
      "last_message": { "at": 1751790000, "direction": "in", "text_preview": "…" },
      "pending_permission": { "asked_at": 1751790100, "expires_at": 1751790700,
                              "tools": ["Bash"], "question": "…" } }
  ]
}
```

`pending_permission` is `null` unless fresh (the `cc_has_pending_permission`
expiry rule); `expires_at = asked_at + CC_PERMISSION_TIMEOUT`. Conversations
are every directory under `$SESSIONS_DIR`; ones predating `conv_key`
persistence report `"conv_key": null` until their next inbound message.

## Architecture

- **Create `lib/state.sh`** — `state_json()`: daemon block from config +
  `PID_LOCK` probe; conversation list by iterating `$SESSIONS_DIR`, merging
  core fields (conv_key, workdir via `workdir.sh`, lock probe, last_message)
  with the `backend_state_json` fragment. Assembled with `jq -n` — no
  hand-concatenated JSON.
- **Create `lib/answer.sh`** — `answer_main <slug> <yes|no>`: validate args,
  take the conversation flock, dispatch `backend_answer_permission`, deliver
  the reply via `write_outbox`, map exit codes.
- **Modify `bin/wabox-bot`** — subcommand parsing before flag parsing;
  `state`/`answer` load config + backend then call the lib and exit.
- **Modify `lib/inbox.sh`** — persist `conv_key` + `last_message.json` (two
  writes next to the existing per-conversation locked section).
- **Modify `lib/locks.sh`** — write `$$` into `PID_LOCK` after acquisition.
- **Modify `lib/backends/claude-code.sh`** — implement both hooks.
- **Modify `docs/backends.md`** — document the optional hooks.

## Risks / notes

- `cc_handle_permission_response` today prints Portuguese user-facing strings;
  `answer` reuses them verbatim (they go to the WhatsApp user, which is
  correct). The TUI shows its own English labels and only relays exit codes.
- If wabox-core stops persisting outbox jobs after send, transcript rendering
  in the TUI degrades — out of scope here, tracked as wabox-tui open question #2.
- `state` performance target: <300 ms with 50 conversations ⇒ one `jq`
  invocation per backend fragment is acceptable; avoid per-envelope scans.
