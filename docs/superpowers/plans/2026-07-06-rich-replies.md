# Rich Replies Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ack reaction on agent-turn start, outgoing-file attachments via the `<workdir>/wabox-send/` convention, and quote-replies in groups / under backlog — all loop-level, no backend-contract change.

**Design:** [2026-07-06-rich-replies-design.md](../specs/2026-07-06-rich-replies-design.md) — decisions there are binding (extras arg on `write_outbox`, ack at handoff not pickup, archive-at-next-turn-start, loop-owned job fields).

**Tech Stack:** Pure bash 4+; `jq -n --argjson`; bats; `shellcheck -x`.

---

## File Structure

- **Modify** `lib/outbox.sh` — optional 5th arg `extras` (JSON merged into the job).
- **Create** `lib/senddir.sh` — `senddir_prepare` / `senddir_collect` / `senddir_prune`.
- **Modify** `lib/inbox.sh` — `participant` extraction; ack-react job; send-dir lifecycle; quote decision; files-only replies.
- **Modify** `lib/backends/claude-code.sh` — `CC_ADVERTISE_SEND_DIR` system-prompt sentence.
- **Modify** `lib/config.sh`, `config.example` — new vars with defaults.
- **Create** `test/bats/senddir.bats`; extend `test/bats/` outbox/inbox tests.
- **Modify** `README.md`, `docs/backends.md`, `CHANGELOG.md`.

Order: Task 1 → 2 → 3 → 4 → 5 → 6. Tasks 3–5 all depend on 1; Task 4 depends on 2.

---

## Task 1: `write_outbox` extras (`lib/outbox.sh`)

- [ ] Accept optional `$5` (`extras`, a JSON object; default `{}`); validate with `jq -e 'type=="object"'`, log + ignore invalid extras rather than failing delivery.
- [ ] Merge via `jq -n --argjson extras`: `{to,text} + replyTo-from-$rid + $extras`; `extras.replyTo` wins over the `$rid` arg (richer object with participant).
- [ ] Files-only support: when `text` is empty **and** extras has `files`, omit `text` from the job.
- [ ] bats: 4-arg callers byte-identical output; react-only job; files+text job; replyTo-with-participant override; invalid extras ignored.

## Task 2: `lib/senddir.sh`

- [ ] `senddir_prepare <workdir> <stem>`: mkdir -p `$workdir/$WABOX_SEND_DIR`; move any existing non-hidden entries into `…/.sent/<stem>/`.
- [ ] `senddir_collect <workdir>`: print absolute paths of non-hidden regular files, sorted by name; empty output when none.
- [ ] `senddir_prune <workdir>`: delete `.sent/*` dirs older than `WABOX_SEND_KEEP_DAYS` days (mtime); never touches anything outside `.sent/`.
- [ ] bats: prepare archives leftovers and is idempotent; collect skips dot-files/dirs and `.sent`; prune respects the cutoff and non-`.sent` safety.

## Task 3: Ack reaction (`lib/inbox.sh`)

- [ ] Extract `participant` in Step 4 alongside `id`/`from`.
- [ ] Immediately before the Step-6 flock, when `WABOX_ACK_REACT` is non-empty and `id` is present: `write_outbox "$to" "" "" "${stem}-ack" '{"react":{"emoji":…,"messageId":…}}'` (+ `participant` for `*@g.us`).
- [ ] Confirm ordering: no ack for slash commands, fromMe skips, empty messages, unsupported media, or transcription failures.
- [ ] bats: ack job written with agent turns only; group ack carries participant; default (`WABOX_ACK_REACT=""`) produces no ack job.

## Task 4: Send-dir lifecycle in the turn (`lib/inbox.sh`)

- [ ] Inside the Step-6 flock, before `backend_reply`: resolve workdir, `senddir_prepare` + `senddir_prune`.
- [ ] After a successful `backend_reply`: `senddir_collect`; when non-empty, build `{"files":[…]}` extras (jq -R/-s from the path list — paths may contain spaces) for the reply job.
- [ ] Empty reply + collected files ⇒ still write the (files-only) job; empty reply + no files keeps today's "no reply" behavior.
- [ ] Timeout/error paths (`rc != 0`): plain text message, no attachments.
- [ ] bats: file dropped by a fake backend arrives in `files` as absolute path; caption = reply text; files-only case; error path attaches nothing; leftover archived on next turn.

## Task 5: Quote-reply policy (`lib/inbox.sh`)

- [ ] `WABOX_QUOTE_REPLY=auto|always|never` (default `auto`); validate at config load, warn + fall back to `auto` on junk.
- [ ] Decision helper: `always` ⇒ quote; `never` ⇒ don't; `auto` ⇒ quote when `to` matches `*@g.us` **or** a backlog probe finds another inbox envelope with the same `conversation_key` (ignore unreadable/vanished files).
- [ ] Quoting sets extras `replyTo: {id, participant?}` (participant in groups) instead of the bare `$rid` arg.
- [ ] bats: group reply quotes with participant; DM with staged backlog quotes; DM without backlog doesn't (auto); `always`/`never` override both.

## Task 6: claude-code advert, config, docs

- [ ] `claude-code.sh`: when `CC_ADVERTISE_SEND_DIR=1` (default) and turn workdir resolved, append one system-prompt sentence naming `<workdir>/$WABOX_SEND_DIR` for outgoing files.
- [ ] `lib/config.sh` + `config.example`: `WABOX_ACK_REACT` (default empty), `WABOX_SEND_DIR` (`wabox-send`), `WABOX_SEND_KEEP_DAYS` (`7`), `WABOX_QUOTE_REPLY` (`auto`), `CC_ADVERTISE_SEND_DIR` (`1`).
- [ ] `README.md`: config table rows + a short "Sending files back" section; note the agent-copies-readable-files caveat from the design.
- [ ] `docs/backends.md`: the send-dir convention for backend authors (agy via `AGY_REPLY_PREFIX`, bob via `BOB_ARGS`).
- [ ] `CHANGELOG.md`: Unreleased → Added (three features) + Changed (`write_outbox` extras arg).
- [ ] `shellcheck -x` clean; full bats suite green.
