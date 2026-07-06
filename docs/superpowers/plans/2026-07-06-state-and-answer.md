# `state --json` and `answer` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two additive CLI verbs — `wabox-bot state --json` (read-only, versioned snapshot of daemon + conversations) and `wabox-bot answer <slug> <yes|no>` (answer a parked permission through the same path a WhatsApp reply takes) — as the stable contract for external tooling (first consumer: wabox-tui).

**Design:** [2026-07-06-state-and-answer-design.md](../specs/2026-07-06-state-and-answer-design.md) — read it first; decisions there are binding (optional backend hooks, no-locks reads, exit codes 0/2/3/4).

**Tech Stack:** Pure bash 4+; `jq -n` for JSON assembly; bats; `shellcheck -x`.

---

## File Structure

- **Modify** `lib/inbox.sh` — persist `conv_key` + `last_message.json` per slug.
- **Modify** `lib/locks.sh` — write daemon PID into `PID_LOCK` after acquisition.
- **Create** `lib/state.sh` — `state_json()`.
- **Create** `lib/answer.sh` — `answer_main()`.
- **Modify** `bin/wabox-bot` — subcommand parsing (`state`, `answer`) + `usage()`.
- **Modify** `lib/backends/claude-code.sh` — `backend_state_json`, `backend_answer_permission`.
- **Create** `test/bats/state.bats`, `test/bats/answer.bats`.
- **Modify** `docs/backends.md`, `README.md`, `CHANGELOG.md`.

Order: Task 1 → 2 → 3 → 4 → 5. Task 3 depends on 1+2 (state reads what they persist); Task 4 depends on 3 (answer reuses subcommand plumbing and hook dispatch).

---

## Task 1: Persist `conv_key` and `last_message.json` (`lib/inbox.sh`)

**Files:** Modify `lib/inbox.sh`; extend `test/bats/` inbox tests.

Inside the per-conversation flock section (after `slug`/`conv_key` are known):

- [x] Write `$SESSIONS_DIR/$slug/conv_key` (mkdir -p the slug dir; plain overwrite, idempotent).
- [x] Write `$SESSIONS_DIR/$slug/last_message.json` via `jq -n` with `{at: now-epoch, direction: "in", text_preview: first 120 chars of $text}`.
- [x] Media-only messages (empty text): preview `"[image]"` / `"[audio]"` by media type.
- [x] bats: both files exist after a handled envelope; conv_key matches; preview truncated at 120 chars.

## Task 2: Daemon PID in the lock (`lib/locks.sh`)

**Files:** Modify `lib/locks.sh`; bats.

- [x] In `acquire_single_instance_lock`, after `flock -n 9` succeeds: truncate + `printf '%s\n' "$$" >&9`.
- [x] bats: lock file contains the daemon PID while held.

## Task 3: `lib/state.sh` + `state` subcommand

**Files:** Create `lib/state.sh`, `test/bats/state.bats`; modify `bin/wabox-bot`, `lib/backends/claude-code.sh`.

- [x] `bin/wabox-bot`: recognize `state` as `$1` before flag parsing; require `--json`; load config + backend; `source lib/state.sh`; run and exit.
- [x] `state_json()` daemon block: `flock -n` probe on `PID_LOCK` (private fd, acquire→release) ⇒ `running`; `pid` from lock file content (null when not running); backend/inbox/outbox/state_dir/log_file from config.
- [x] Conversation list: iterate `$SESSIONS_DIR/*/`; core fields: `conv_key` (file or null), workdir + `workdir_is_default` (via `lib/workdir.sh`), `locked` (probe `$LOCKS_DIR/$slug.lock`), `last_message` (file or null).
- [x] Backend fragment: if `declare -F backend_state_json`, merge its object; else `{session_id:null, overrides:{model:null,mode:null,system:null}, pending_permission:null}`.
- [x] `claude-code.sh` `backend_state_json`: session via `cc_*` readers; overrides from `model`/`mode`/`system` files; `pending_permission` only when `cc_has_pending_permission` (fresh) — emit `{asked_at, expires_at: asked_at+CC_PERMISSION_TIMEOUT, tools: [.denials[].tool_name], question: cc_format_permission_message output}`.
- [x] Top level: `{"version": 1, daemon, conversations}` sorted by `last_message.at` desc, nulls last. Assemble everything with `jq -n --slurpfile`/`--argjson`; no string-built JSON.
- [x] bats: schema keys present; daemon running/stopped both probed correctly; conversation with parked permission reports it; legacy slug dir without `conv_key` file yields `conv_key: null`; expired pending ⇒ `null`.

## Task 4: `lib/answer.sh` + `answer` subcommand + claude-code hook

**Files:** Create `lib/answer.sh`, `test/bats/answer.bats`; modify `bin/wabox-bot`, `lib/backends/claude-code.sh`.

- [x] `bin/wabox-bot`: `answer <slug> <yes|no>` subcommand; usage errors exit 1.
- [x] `answer_main`: `declare -F backend_answer_permission` or exit 4 · `flock -w "${ANSWER_LOCK_WAIT:-5}"` on `$LOCKS_DIR/$slug.lock` or exit 3 · dispatch hook · on success, `write_outbox` the echoed reply to the chat JID (`conv_key%%|*`) · propagate exit 2.
- [x] `claude-code.sh` `backend_answer_permission <slug> <conv_key> <yes|no>`: `cc_has_pending_permission` or exit 2; resolve workdir via `lib/workdir.sh`; call `cc_handle_permission_response` with synthetic text (`yes`→`sim`, `no`→`não`) and stem `answer-$(date +%s)`; echo its reply.
- [x] Update `last_message.json`? No — direction "out" is out of scope (design); leave as-is.
- [x] bats (echo-backend double implementing fake hooks + claude-code with stubbed `claude`): exit 0 happy path writes an outbox job; exit 2 when nothing pending; exit 3 when lock held by another process; exit 4 on echo backend without hook; chained denial (approval turn parks again) leaves a fresh `pending_permission`.

## Task 5: Docs

- [x] `docs/backends.md`: document `backend_state_json` and `backend_answer_permission` under "Optional", with the JSON fragment shape and exit-code contract.
- [x] `README.md`: `state` / `answer` in usage + a "External tooling" paragraph pointing at the contract (version field, exit codes).
- [x] `CHANGELOG.md`: Unreleased → Added entries for both verbs, the persisted `conv_key`/`last_message.json`, and the PID-in-lock change.
- [x] `shellcheck -x` clean; full bats suite green.
