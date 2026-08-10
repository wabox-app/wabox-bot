# Scheduled jobs: chat-registered periodic and one-shot turns

**Date:** 2026-08-09
**Status:** Draft (design)
**Supersedes:** the "no scheduler inside wabox-bot" non-goal in
[2026-07-06-proactive-messaging-design.md](2026-07-06-proactive-messaging-design.md).

## Problem

`wabox-bot prompt <slug> <text>` plus cron gives us proactive messages, but
every job costs a shell session, a `state --json | jq` slug lookup, and a
crontab edit. The operator is on WhatsApp, not at a terminal. "Remind me at 18h"
and "check my calendar every hour" are the two things a personal agent is *for*,
and today neither can be set up from the chat where the agent lives.

## Goal

Registering, listing, and cancelling scheduled turns from the conversation
itself:

```
/in 2h take the chicken out of the freezer
/at 18:00 call the dentist
/at 2026-08-12 09:00 renew the passport
/every 30m check my calendar, NOOP if nothing needs me
/daily 09:00 morning digest: calendar, todos, anything overdue
/jobs
/cancel 3
```

with no new CLI verb: because the commands are core, `wabox-bot cmd <slug>
"/daily 09:00 …"` already drives all of them through the same code path.

## Non-goals

- **Cron syntax (`/cron */30 8-22 * * *`).** Deferred: a 5-field matcher is
  ~60 lines of pure bash and nothing in the stated use cases needs it. The job
  record's `kind`/`rule` split leaves room to add it as a fourth kind.
- **Weekly rules (`/every mon 09:00`).** Deferred with `/cron`, same reasoning.
- **Cross-conversation jobs.** A job belongs to the conversation that created
  it; `/jobs` and `/cancel` only ever see that conversation's jobs.
- **A second delivery path.** Firing reuses `prompt_main` verbatim.

## Decisions

- **The daemon owns the clock.** `loop.sh` already wakes every second on its
  `read -t 1` timeout; a throttled `sched_tick` on that path costs one `jq`
  invocation per tick. The alternatives lose: having the bot rewrite the user's
  crontab makes a WhatsApp message a control plane over the user's cron (and
  makes `/jobs` a crontab-comment parse), and `systemd-run --on-calendar`
  splits job state across two systems and drags systemd into a project that
  otherwise needs only bash + inotify. In-daemon keeps everything in
  `$STATE_DIR`, so `rm <slug>` and backup/restore already cover jobs.
  The security posture that the superseded non-goal protected is preserved by
  scoping: a job is a *standing `prompt` turn in the conversation that asked for
  it* — strictly less power than the arbitrary tools that conversation's agent
  can already run.

- **One job = one file.** `$STATE_DIR/jobs/<slug>/<id>.json`. Per-conversation
  directories make `/jobs` scoping and `rm <slug>` cleanup a directory
  operation rather than a filter. `id` is a small per-conversation integer
  (max existing + 1) so `/cancel 3` is typeable on a phone.

  ```json
  {
    "id": 3, "kind": "daily", "rule": "09:00", "spec": "daily 09:00",
    "action": "prompt", "text": "morning digest…", "tz": "",
    "next_run": 1770000000, "created": 1769000000,
    "last_run": 0, "runs": 0, "deferred_since": 0
  }
  ```

  `kind` ∈ `once` · `interval` (rule = seconds) · `daily` (rule = `HH:MM`).
  `spec` is the human echo `/jobs` prints; it is never re-parsed.

- **`next_run` is an absolute epoch, recomputed after every fire.** Firing
  compares integers, so it is timezone-independent. A `daily` job's next run is
  recomputed as a wall-clock time under the job's zone rather than by adding
  86400, so "every day at 9am" stays 9am across a DST change instead of
  drifting an hour. `interval` jobs advance from the *scheduled* time, not the
  completion time, so a slow turn doesn't make an hourly job drift later.

- **Timezone: `WABOX_JOB_TZ`, resolved at creation, stored per job.** Empty
  (default) means the daemon's local time. Stored per job so changing the
  config doesn't silently move existing reminders. `/jobs` always prints the
  resolved local time and the zone, so a systemd unit started with a stripped
  `TZ` shows up as "09:00 UTC" in the listing instead of as a message at 6am.

- **Firing is `prompt_main`, unchanged.** Per-conversation flock, workdir,
  senddir lifecycle, `NOOP` suppression, `last_message.json` — all of it
  already exists and is already tested. The job runner only decides *when* and
  *what text*, then interprets the exit code.

- **The stored text is wrapped, and the wrapper differs by kind.** A recurring
  job gets the heartbeat preamble (nobody is waiting; reply exactly `NOOP` if
  nothing needs attention). A one-shot gets the opposite instruction — deliver
  this now, do **not** reply `NOOP` — because `NOOP` on a `once` job would eat
  the reminder silently.

- **No new CLI verb.** `lib/cmd.sh` already runs a conversation's slash commands
  from the shell and captures the reply, so making the commands core buys
  `wabox-bot cmd <slug> "/daily 09:00 …"` for free. A `job add` verb would have
  been a second parser for the same grammar.

- **Records carry `action` and `raw`, but chat only ever writes
  `action:"prompt"`, `raw` absent.** `sched_fire` honours `action:"send"` (dumb
  delivery via `send_main`, no agent turn, no tokens) and `raw:true` (skip the
  wrapper), because a `/remind`-style command and a byte-exact scripted job are
  the obvious next asks and the runner support is a handful of lines. Nothing
  in v1 produces them except a hand-written record.

- **Missed runs: one-shots always fire, recurring ones skip.** After downtime,
  a `once` job fires however late it is (a late reminder beats a lost one) and
  the preamble notes the delay so the agent can say so. A recurring job whose
  slot is older than `WABOX_JOB_CATCHUP` (default 3600s) is skipped — its
  `next_run` is recomputed and nothing is sent, so a laptop asleep overnight
  doesn't wake to eight backed-up hourly checks.

- **Lock-busy defers, it does not drop.** `prompt_main` exits 3 when the
  conversation is mid-turn. The runner then leaves `next_run` alone and stamps
  `deferred_since`, so the next tick retries — a reminder must not vanish
  because the user happened to be chatting. Once the deferral exceeds
  `WABOX_JOB_CATCHUP` the occurrence is abandoned (logged, `next_run`
  advanced) rather than retried forever.

- **A per-job flock, in addition to the conversation flock.**
  `$LOCKS_DIR/job-<slug>-<id>.lock`, taken `flock -n`. The conversation lock
  serializes *turns*; this one stops a tick from launching a second copy of a
  job whose previous run is still going.

- **Guardrails, because the agent can create jobs too.** `WABOX_JOB_MAX`
  (default 50) caps jobs per conversation; `WABOX_JOB_MIN_INTERVAL` (default
  60s) is the floor for `/every`, so `/every 1s` can't hammer the backend.
  Both refuse with a chat reply rather than failing silently.

- **Slash commands are core, not backend.** Nothing about them is
  backend-specific, and `lib/cmd.sh` gets them for free (so wabox-tui can drive
  scheduling through the existing `cmd` verb). The dispatcher in `commands.sh`
  delegates to `lib/schedule.sh`; `/help` grows the new lines.

- **Time parsing is forgiving about phone typing.** `/at` accepts `9`, `9:00`,
  `09:00`, `9h`, `9h30`, `9am`, `21:30`, and `YYYY-MM-DD HH:MM`. Durations are
  `90s`, `30m`, `2h`, `1d`, `1w`, and concatenations like `1h30m`. A bare
  `HH:MM` in the past resolves to tomorrow.

- **GNU `date -d` is fair game.** The daemon already requires `inotifywait`,
  which is Linux-only, so coreutils `date` is a safe dependency for wall-clock
  arithmetic under an explicit `TZ`.

## Architecture

- **Create `lib/schedule.sh`** — the whole feature:
  - `sched_parse_dur`, `sched_parse_time`, `sched_next_daily` — parsing;
  - `sched_add`, `sched_list`, `sched_cancel`, `sched_render` — job CRUD;
  - `sched_handle_command` — `/in /at /every /daily /jobs /cancel`;
  - `sched_tick`, `sched_fire`, `sched_advance` — the runner.
- **Modify `lib/config.sh`** — `JOBS_DIR`, `mkdir`, five `WABOX_JOB_*` vars,
  `CONFIG_VARS` registry entries.
- **Modify `lib/loop.sh`** — throttled `sched_tick` on both loop paths
  (a busy inbox must not starve the scheduler), children tracked in `CHILDREN`
  so shutdown drains a firing job.
- **Modify `lib/commands.sh`** — dispatch the six commands, extend `/help`.
- **Modify `bin/wabox-bot`** — source `schedule.sh` (plus `send.sh`/`prompt.sh`,
  which the daemon didn't previously load) in the daemon, and `schedule.sh` in
  the `cmd` subcommand path.
- **Modify `lib/rm.sh`** — drop `$JOBS_DIR/<slug>` with the session.
- **Create `test/bats/schedule.bats`**; **modify** `config.example`,
  `README.md`, `CHANGELOG.md`, `examples/heartbeat/README.md` (point at
  `/every` as the now-preferred path, keep cron for machine-level jobs).

## Implementation notes worth keeping

- **Never join record fields with a tab.** bash counts tab as IFS *whitespace*,
  so `IFS=$'\t' read` collapses runs of them: one empty field (a one-shot's
  `rule`, or `tz` whenever `WABOX_JOB_TZ` is unset — the default) shifts every
  field after it, and `next_run` reads as empty. The symptom is a fire that
  believes it is ~20000 days late. Records are read via `sched_fields`, which
  joins with an ASCII unit separator (`\x1f`) instead. Covered by a regression test.
- **`date -d "$day $hhmm +1 day"` is not "the next day".** GNU date parses the
  `+1` in `09:00 +1 day` as a UTC offset and shifts by an hour. The date has to
  be advanced on its own (`date -d "$day +1 day" +%F`) and the wall-clock time
  re-resolved against it.

## Risks / notes

- **Tick cost.** One `jq` over `$JOBS_DIR/*/*.json` every `WABOX_JOB_TICK`
  (default 20s), using `input_filename` to recover paths. At the expected
  scale (tens of jobs) this is noise; at thousands it would want an index, and
  the tick is throttled independently so that knob exists.
- **A firing job delays inbound replies for its conversation**, exactly as a
  cron heartbeat does today — the shared conversation flock is the point. The
  `/every` minimum interval and short standing prompts are the mitigation.
- **Scheduled turns grow the session.** Each fire is real conversation history,
  visible to later turns (that's what makes "what did you remind me about?"
  work) and counted toward context. `/clear` resets the session but
  deliberately does **not** cancel jobs — clearing context is not cancelling a
  reminder. `/cancel` is the only way to drop one.
- **A permission-gated tool in a scheduled turn parks a question**, which is
  delivered to the chat as the reply. Unchanged from the heartbeat pattern;
  answer in chat or with `wabox-bot answer`.
