# Proactive Messaging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `wabox-bot send <slug> [text]` (raw delivery) and `wabox-bot prompt <slug> <text>` (agent turn + delivery with `NOOP` suppression), plus shipped heartbeat examples — outbound-initiated messaging with no scheduler and no daemon changes.

**Design:** [2026-07-06-proactive-messaging-design.md](../specs/2026-07-06-proactive-messaging-design.md) — decisions there are binding (two verbs, sentinel suppression, exit codes 0/1/3/5/124, examples-not-features for scheduling).

**Depends on:** rich-replies plan (in flight) for `write_outbox` extras + `lib/senddir.sh`. Tasks 1–2 (minus `--file`) work without it; Task 3's senddir steps and Task 2's `--file` flag need it landed.

**Tech Stack:** Pure bash 4+; `jq`; bats; `shellcheck -x`.

---

## File Structure

- **Create** `lib/send.sh` — `send_main()`.
- **Create** `lib/prompt.sh` — `prompt_main()`.
- **Modify** `bin/wabox-bot` — `send` / `prompt` subcommands + `usage()`.
- **Create** `lib/lastmsg.sh` — tiny shared writer for `last_message.json` (inbox.sh currently inlines it; extract so send/prompt reuse it).
- **Create** `examples/heartbeat/` — `crontab.example`, `wabox-heartbeat.timer` + `.service`, `standing-prompt.txt`.
- **Create** `test/bats/send.bats`, `test/bats/prompt.bats`.
- **Modify** `README.md`, `CHANGELOG.md`.

Order: Task 1 → 2 → 3 → 4 → 5. Task 3 needs rich-replies' senddir; if it hasn't merged, implement Task 3 behind its absence (skip attach steps, leave checkboxes open) and finish after rebase.

---

## Task 1: Extract `lastmsg.sh` shared writer

**Files:** Create `lib/lastmsg.sh`; modify `lib/inbox.sh`; bats.

- [ ] `lastmsg_write <slug> <direction> <preview-text>`: `jq -n` the `{at, direction, text_preview}` record (120-char truncation, media placeholders stay caller-side); atomic write (tmp + mv) since three writers can now race.
- [ ] `lib/inbox.sh` switches to it; behavior identical.
- [ ] bats: direction in/out records; truncation; atomicity smoke (no partial JSON under concurrent writes).

## Task 2: `send` verb (`lib/send.sh`)

- [ ] `bin/wabox-bot`: `send` subcommand; usage errors exit 1.
- [ ] Parse: `wabox-bot send <slug> [text|-]` · `--to <jid|number>` (mutually exclusive with slug) · `--file <path>` repeatable (validate file exists+readable; **requires extras — gate on rich-replies**). Text omitted or `-` ⇒ read stdin.
- [ ] Slug path: resolve `conv_key` from `$SESSIONS_DIR/$slug/conv_key` (unknown ⇒ exit 1, same message style as `answer`); `to="${conv_key%%|*}"`. `--to` path: pass through verbatim (core normalizes bare numbers).
- [ ] Write job via `write_outbox "$to" "$text" "" "send-<epoch>-$$" [extras with files]`; empty text + no files ⇒ usage error (exit 1).
- [ ] Slug path only: `lastmsg_write <slug> out <text>`.
- [ ] bats: slug happy path writes job + last_message out-record; stdin body; `--to` bypasses slug and writes no last_message; `--file` builds files extras; missing file ⇒ exit 1; empty everything ⇒ exit 1.

## Task 3: `prompt` verb (`lib/prompt.sh`)

- [ ] `bin/wabox-bot`: `prompt` subcommand; usage errors exit 1.
- [ ] `prompt_main <slug> <text|->`: conv_key resolution (exit 1 unknown); `flock -w "${ANSWER_LOCK_WAIT:-5}"` on `$LOCKS_DIR/$slug.lock` (busy ⇒ 3); resolve workdir via `conversation_workdir`.
- [ ] Turn: `senddir_prepare` + `senddir_prune`; pipe text into `backend_reply "$slug" "$conv_key" "prompt-<epoch>-$$" "" "" ""`; propagate 124; other non-zero ⇒ stderr notice, same rc.
- [ ] Sentinel: trim reply; empty or `== "${WABOX_PROMPT_NOOP:-NOOP}"` ⇒ log, exit 5, deliver nothing (leftover senddir files stay for next turn's archive).
- [ ] Deliver: `senddir_collect` ⇒ files extras; `write_outbox` to `conv_key%%|*`; `lastmsg_write <slug> out <reply>`.
- [ ] bats (echo backend + stubbed claude-code): happy path delivers and session continuity holds (claude-code stub asserts `--resume` on second prompt); NOOP ⇒ exit 5, no job; lock held ⇒ exit 3; timeout stub ⇒ 124; turn-dropped file attaches; parked-permission reply (stub emits permission_denials) delivers the question text and leaves `pending_permission` fresh.

## Task 4: Heartbeat examples (`examples/heartbeat/`)

- [ ] `standing-prompt.txt`: commented template — check tasks/calendar/folder, reply `NOOP` unless something needs attention, keep replies WhatsApp-short, may drop files in the send folder.
- [ ] `crontab.example`: one line, `*/30 8-22 * * *` style, `wabox-bot prompt <slug> "$(cat …/standing-prompt.txt)"` with `|| [ $? -eq 5 ]` so suppression isn't a cron error.
- [ ] `wabox-heartbeat.service` + `.timer` (systemd user units, `OnCalendar`), mirroring the cron semantics; `SuccessExitStatus=5`.
- [ ] `examples/heartbeat/README.md`: find your slug via `wabox-bot state --json | jq …`; install steps for both schedulers; the delay-inbound-turn caveat from the design.

## Task 5: Docs

- [ ] `README.md`: `send`/`prompt` in usage; "Proactive messaging" section (verbs, NOOP sentinel, exit codes, heartbeat walkthrough link); note session-visibility of prompt turns and `/clear`.
- [ ] `CHANGELOG.md`: Unreleased → Added (`send`, `prompt`, heartbeat examples, `direction:"out"` in `last_message.json`).
- [ ] `shellcheck -x` clean; full bats suite green.
