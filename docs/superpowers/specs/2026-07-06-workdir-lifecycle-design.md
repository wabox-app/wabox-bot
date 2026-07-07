# Workdir lifecycle: `.wabox/` consolidation, sizes, `gc`, `rm`

**Date:** 2026-07-06
**Status:** Draft (design)
**Depends on:** rich replies (landed), proactive messaging (in flight — `lib/prompt.sh` shares the senddir path helpers).

## Problem

Workdirs are born managed (auto-create, seed) and then abandoned. Staged
inbound media (`wabox-media/`) is never pruned and every media file also lives
forever in `processed/` — two unbounded copies per voice note. Nothing reports
how big a conversation has grown. Nothing deletes a conversation end-to-end
(`/clear` resets the session but keeps workdir, memory, overrides). And the
bot's plumbing dirs (`wabox-media/`, `wabox-send/`) land bare in the workdir —
which, after `/cwd ~/Valter`, means bare in the *user's own folder*.

## Goal

- All bot-owned plumbing lives under one hidden dir: `<workdir>/.wabox/`.
- Operators can see per-conversation disk usage (`state --json --sizes`, `/status`).
- `wabox-bot gc` prunes staged media, send archives, and processed envelopes
  by age — dry-run by default.
- `wabox-bot rm <slug>` deletes a conversation completely and safely.

## Non-goals

- Daemon-side automatic deletion. The daemon never deletes user-visible data
  on its own; pruning is an explicit verb the operator runs (or crons).
- Quotas / size limits enforcement. Visibility first; limits are a P2 if ever.
- Moving `CLAUDE.md` / `AGENTS.md` / `MEMORY.md` into `.wabox/`. They are
  *meant* to be user-visible and agent-visible at the workdir root (`claude`
  only auto-loads `CLAUDE.md` from cwd root), and MEMORY.md's auditability is
  a design feature. Only plumbing moves.
- Pruning `MEMORY.md` or agent-created files. `gc` touches nothing the agent
  or user authored.

## Decisions

- **Layout: `.wabox/send/` and `.wabox/media/`** (send archives stay nested:
  `.wabox/send/.sent/<stem>/`). One `workdir_botdir <workdir>` helper in
  `lib/workdir.sh` returns `<workdir>/.wabox` and is the only place the name
  exists. `WABOX_SEND_DIR` / new `WABOX_MEDIA_DIR` become paths *relative to
  `.wabox/`* (defaults `send`, `media`).
- **Migration: move + compat symlink, one release.** First resolution per
  workdir: if legacy `wabox-send/` or `wabox-media/` exists and the new path
  doesn't, `mv` it into `.wabox/` and leave a relative symlink at the old
  name. The symlinks keep any in-flight outbox job (absolute paths through the
  old name) and user habit working; they stop being *created* now and get
  removed by `gc` after the next minor release. Rationale: the old names
  shipped only today — cheap to walk back, expensive later.
- **Sizes are opt-in: `state --json --sizes`.** Adds `workdir_bytes` and
  `botdir_bytes` (the `.wabox/` share — i.e. reclaimable-by-gc vs. agent
  content) per conversation via `du -sb`. Opt-in keeps the plain `state` call
  inside its <300 ms budget with many/large conversations. Additive fields ⇒
  contract stays `version: 1`. `/status` (single conversation, over WhatsApp)
  always includes a human-readable size line.
- **`gc [slug] [--yes]`.** Scope: one conversation or all. Prunes by mtime:
  `.wabox/media/` older than `WABOX_MEDIA_KEEP_DAYS` (default 30),
  `.wabox/send/.sent/` older than `WABOX_SEND_KEEP_DAYS` (existing, 7), and
  `processed/` envelopes + their media older than `WABOX_PROCESSED_KEEP_DAYS`
  (default 90; `0` = keep forever, preserving today's audit-everything
  behavior as the *only* changed default worth flagging in the CHANGELOG).
  Dry-run prints what would go and the byte total; `--yes` applies. Per
  conversation it takes the conversation lock non-blocking (`flock -n`) and
  *skips* busy conversations with a notice — gc never waits and never races a
  turn. Never crosses a symlink; never deletes outside `.wabox/` and
  `processed/`.
- **`rm <slug> [--yes]`.** Deletes the session dir (`$SESSIONS_DIR/<slug>` —
  session ids, overrides, pending permission, conv_key) and the **default**
  workdir (`$STATE_DIR/work/<slug>`). A `/cwd`-redirected folder is never
  deleted — `rm` only removes the pointer to it and prints the path it left
  behind ("your folder, your files"). Interactive confirm unless `--yes`.
  Busy lock ⇒ exit 3 (consistent with `answer`/`prompt`); unknown slug ⇒ 1.
  CLI-only, deliberately not a slash command — file deletion must not be
  promptable from the chat side (same reasoning as `send --to` gating).
- **Exit codes.** `gc`: `0` (dry-run or applied), `1` usage/unknown slug.
  `rm`: `0` ok, `1` usage/unknown slug, `3` conversation busy.

## Architecture

- **Modify `lib/workdir.sh`** — `workdir_botdir` + one-time migration.
- **Modify `lib/senddir.sh`, `lib/media.sh`** — resolve through
  `workdir_botdir`; no other logic changes.
- **Modify `lib/backends/claude-code.sh`** — send-dir advert sentence uses the
  resolved path (already parameterized; verify).
- **Modify `lib/state.sh`** — `--sizes` flag ⇒ `du -sb` fields.
- **Modify `lib/commands.sh`** — `/status` size line.
- **Create `lib/gc.sh`**, **`lib/rm.sh`** — the verbs.
- **Modify `bin/wabox-bot`** — subcommands + usage.
- **Modify `lib/config.sh`, `config.example`** — `WABOX_MEDIA_DIR`,
  `WABOX_MEDIA_KEEP_DAYS`, `WABOX_PROCESSED_KEEP_DAYS` (+ re-home
  `WABOX_SEND_DIR` semantics).

## Risks / notes

- The `WABOX_SEND_DIR` semantic change (now relative to `.wabox/`) breaks
  anyone who set it explicitly in the few hours it existed — CHANGELOG calls
  it out under Changed; `--print-config` shows the resolved absolute path.
- `processed/` pruning weakens the audit trail; default 90 days is generous
  and `0` opts out entirely. `transcript` output degrades gracefully for
  pruned ranges (already documented behavior).
- `du -sb` on a huge agent-built tree can be slow even opt-in; acceptable —
  the caller asked. The TUI should cache between refreshes.
- `rm` while the daemon is mid-`inotifywait` on that conversation is safe: the
  next envelope for the JID simply recreates a fresh slug dir (same slug,
  clean state) — worth a bats case, not a blocker.
