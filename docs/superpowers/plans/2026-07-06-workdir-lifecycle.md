# Workdir Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Consolidate bot plumbing under `<workdir>/.wabox/` (with one-release migration symlinks), add per-conversation size visibility (`state --json --sizes`, `/status`), and ship the `gc` (age-based pruning, dry-run default) and `rm` (full conversation deletion) verbs.

**Design:** [2026-07-06-workdir-lifecycle-design.md](../specs/2026-07-06-workdir-lifecycle-design.md) — decisions there are binding (`.wabox/` layout, move+symlink migration, opt-in sizes, gc skips busy conversations, rm never deletes `/cwd` targets).

**Coordination:** proactive-messaging is in flight and `lib/prompt.sh` calls the senddir helpers — land this *after* it merges, then the path change is one place (`workdir_botdir`).

**Tech Stack:** Pure bash 4+; `jq`; `du -sb`; bats; `shellcheck -x`.

---

## File Structure

- **Modify** `lib/workdir.sh` — `workdir_botdir()` + one-time legacy migration.
- **Modify** `lib/senddir.sh`, `lib/media.sh` — resolve paths through `workdir_botdir`.
- **Modify** `lib/backends/claude-code.sh` — advert sentence prints the resolved send path.
- **Modify** `lib/state.sh` — `--sizes`.
- **Modify** `lib/commands.sh` — `/status` size line.
- **Create** `lib/gc.sh`, `lib/rm.sh`.
- **Modify** `bin/wabox-bot` — `gc` / `rm` subcommands, `state --sizes` passthrough, `usage()`.
- **Modify** `lib/config.sh`, `config.example` — new vars + `WABOX_SEND_DIR` re-homing.
- **Create** `test/bats/botdir.bats`, `test/bats/gc.bats`, `test/bats/rm.bats`.
- **Modify** `README.md`, `CHANGELOG.md`.

Order: Task 1 → 2 → 3 → 4 → 5 → 6. Everything depends on Task 1.

---

## Task 1: `workdir_botdir` + migration (`lib/workdir.sh`)

- [ ] `workdir_botdir <workdir>`: echo `<workdir>/.wabox`, `mkdir -p` it.
- [ ] One-time migration inside it: for each of `wabox-send`→`send`, `wabox-media`→`media`: legacy dir exists (and is not already a symlink) + new path absent ⇒ `mv` into `.wabox/`, create relative symlink at the legacy name; any other combination ⇒ leave untouched.
- [ ] `lib/senddir.sh` and `lib/media.sh` build paths as `$(workdir_botdir …)/${WABOX_SEND_DIR:-send}` / `…/${WABOX_MEDIA_DIR:-media}`; no other logic changes. `.sent` stays nested under the send dir.
- [ ] `lib/config.sh` + `config.example`: `WABOX_MEDIA_DIR` (default `media`); `WABOX_SEND_DIR` default becomes `send` with a comment that it is now relative to `.wabox/`.
- [ ] Verify the claude-code advert sentence prints the resolved absolute path (it interpolates the var — update the interpolation).
- [ ] bats (`botdir.bats`): fresh workdir gets `.wabox/`; legacy dirs migrate once with working symlinks; staged media lands in `.wabox/media`; senddir collect works through the new path; re-resolution is idempotent.

## Task 2: Sizes (`lib/state.sh`, `lib/commands.sh`)

- [ ] `state --json --sizes`: per conversation add `workdir_bytes` and `botdir_bytes` (`du -sb`, `0` when the dir doesn't exist); without the flag, fields are `null` (schema-stable, still `version: 1`).
- [ ] `/status`: append a human-readable line (`pasta: 1,2 GB (bot: 800 MB)`) computed for that conversation only.
- [ ] bats: flag populates both fields; no flag ⇒ nulls; `/status` line present.

## Task 3: `gc` verb (`lib/gc.sh`)

- [ ] `gc [slug] [--yes]`: no slug ⇒ all conversations from `$SESSIONS_DIR`; unknown slug ⇒ exit 1.
- [ ] Per conversation: `flock -n` on the conversation lock; busy ⇒ print skip notice, continue (exit stays 0).
- [ ] Prune by mtime (`find -mtime`): `.wabox/media/` > `WABOX_MEDIA_KEEP_DAYS` (30) · `.wabox/send/.sent/` > `WABOX_SEND_KEEP_DAYS` (7) · `processed/` envelope+media pairs > `WABOX_PROCESSED_KEEP_DAYS` (90; `0` disables) · legacy compat symlinks (`wabox-send`, `wabox-media`) when dangling.
- [ ] Safety rails: `find -P` (never follow symlinks); paths anchored under `.wabox/` and `$PROCESSED_DIR` only; a `0`-days var disables that category.
- [ ] Dry-run default: list relative paths + total bytes reclaimable, exit 0 with "run with --yes to apply"; `--yes` deletes and reports the freed total.
- [ ] bats: dry-run deletes nothing; `--yes` respects each cutoff; busy conversation skipped; agent files at workdir root untouched; `0` disables a category; processed envelope+media removed as a pair.

## Task 4: `rm` verb (`lib/rm.sh`)

- [ ] `rm <slug> [--yes]`: unknown slug ⇒ 1; conversation lock via `flock -w "${ANSWER_LOCK_WAIT:-5}"`, busy ⇒ 3.
- [ ] Interactive confirm (prints conv_key, workdir path, sizes) unless `--yes`; non-TTY without `--yes` ⇒ abort 1.
- [ ] Delete `$SESSIONS_DIR/<slug>` and — only when the effective workdir is the default `$STATE_DIR/work/<slug>` — that workdir. A `/cwd` override target is never touched: remove the pointer (already inside the session dir) and print the preserved path.
- [ ] bats: full deletion for default workdir; `/cwd` target preserved and reported; busy ⇒ 3; non-TTY guard; next inbound message for the same JID recreates a clean conversation.

## Task 5: Wire-up (`bin/wabox-bot`)

- [ ] `gc` / `rm` subcommands (load config + backend first, same pattern as `answer`); `state` passes `--sizes` through; `usage()` updated.
- [ ] bats: subcommand dispatch + usage errors.

## Task 6: Docs

- [ ] `README.md`: "Workdir lifecycle" section — the `.wabox/` layout, migration note, `gc` (with a crontab example next to the heartbeat one), `rm` semantics, sizes.
- [ ] `CHANGELOG.md`: Added (`gc`, `rm`, `--sizes`, `.wabox/`) + **Changed** (`WABOX_SEND_DIR` now relative to `.wabox/`; `processed/` pruned by default after 90 days — `WABOX_PROCESSED_KEEP_DAYS=0` restores keep-forever).
- [ ] Note in `docs/backends.md` if the advert interpolation changed shape.
- [ ] `shellcheck -x` clean; full bats suite green.
