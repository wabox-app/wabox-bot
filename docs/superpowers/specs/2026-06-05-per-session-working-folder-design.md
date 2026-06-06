# Per-session working folder

**Date:** 2026-06-05
**Status:** Approved (design)

## Problem

The `claude-code` backend runs the `claude` CLI from wherever the daemon was
launched. Every WhatsApp conversation shares that one working directory, so the
agent's file reads/writes/creates from different conversations collide.

Each conversation (session) must instead get its own working folder, so an
agent turn's file operations stay isolated to that conversation. The owner must
also be able to point a specific conversation at a chosen directory — e.g. their
chat with Valter at `~/Valter` — rather than only an opaque auto-generated path.

## Goal

- Every conversation has a working folder; the agent `cd`s into it before each turn.
- Unset conversations default to an auto, per-conversation folder (full isolation
  out of the box).
- A `/cwd <path>` slash command lets the user redirect a conversation to a chosen
  directory, persisted across restarts like the other per-conversation overrides.

## Non-goals

- **Per-sender authorization.** In a group, any participant's message is processed
  as that conversation, so a group member can run `/cwd` (just as they can already
  run `/model` / `/mode` today). Restricting commands by sender is out of scope for
  this change. The trust surface is unchanged.
- Sandboxing or restricting what the agent can do *within* its working folder —
  that remains governed by `CLAUDE_ARGS` / `--permission-mode`.
- Cleaning up or deleting working-folder contents (they belong to the user).

## Architecture

A new single-purpose module `lib/workdir.sh` owns working-folder resolution.
**Core owns this, not the `claude-code` backend** — "each session must have a
working folder" is a conversation-level invariant and the default folder is keyed
by the conversation `slug`, not by backend. This mirrors how core owns `/clear`
and `/status` while delegating only the backend-specific bit. A backend's only job
is to `cd` into the resolved path.

### `lib/workdir.sh`

- `conversation_dir <slug>` → `$SESSIONS_DIR/<slug>` — the per-conversation root,
  a sibling of the existing per-backend state subdirs (`<slug>/<backend>/`).
- `conversation_workdir <slug>` → resolves the *effective* working dir:
  - if `$SESSIONS_DIR/<slug>/workdir` exists and is non-empty, read it as the
    override path;
  - otherwise use the auto default `$STATE_DIR/work/<slug>`;
  - `mkdir -p` the resulting path and print its absolute form.

The override file stores the already-expanded absolute path (set by `/cwd`), so
resolution does no re-expansion. The auto default is created on demand; it
materializes on a conversation's first real agent turn, not eagerly for every
conversation.

### Source order

`bin/wabox-bot` sources `lib/workdir.sh` after `outbox` and before `backend`, so
`backend_reply` can call `conversation_workdir`. `workdir.sh` depends only on
`STATE_DIR` / `SESSIONS_DIR` from `config.sh`.

## The `/cwd` command (core, `lib/commands.sh`)

A new case in `handle_slash_command`, alongside `/clear`, `/ping`, `/status`,
`/help`:

- **`/cwd`** (no arg) — show the effective working folder and whether it is the
  auto default or an explicit override.
- **`/cwd <path>`** — set the override for this conversation:
  - A leading `~` or `~/` is expanded to `$HOME` manually (bash does not expand
    `~` inside a variable).
  - The path **must be absolute or `~`-prefixed**; relative paths are rejected
    (no ambiguous base directory).
  - The path **must already exist and be a directory**; otherwise an error reply
    is sent. A typo must not silently create a junk folder. (Only the *auto
    default* is created on demand — explicit overrides must pre-exist.)
  - The expanded absolute path is persisted to `$SESSIONS_DIR/<slug>/workdir`,
    written under the per-conversation flock (fd 8), the same pattern as `/model`.
- **`/cwd default`** (or `/cwd clear`) — remove the override file; revert to the
  auto per-slug folder.

`/cwd` is added to the core `/help` text. A `workdir:` line is added to the core
`/status` block showing the resolved path plus `(default)` or `(override)`.

`/clear` does **not** touch the workdir — it forgets the agent session, not the
workspace mapping, and never deletes folder contents.

## Backend integration (`lib/backends/claude-code.sh`)

In `backend_reply`, before building the `claude` command:

```sh
local workdir
workdir="$(conversation_workdir "$slug")"
cd "$workdir" || { log_error "[$stem] cannot cd to workdir $workdir"; return 1; }
```

This is safe because the turn already runs inside a command-substitution subshell
(`reply="$(... backend_reply ...)"` under the fd-8 flock in `inbox.sh`), so the
`cd` is scoped to that one envelope — no global CWD pollution and no races between
concurrent conversations. `claude` then runs with the conversation's folder as its
working directory.

The `echo` backend is untouched; it never calls `conversation_workdir`, so no
folders are created for echo-only use.

## Error handling

- **Invalid `/cwd` path** (relative, nonexistent, not a directory) → error reply
  to the user; no override is persisted; the existing working folder is unchanged.
- **Stale override** (folder deleted after being set) → the `cd` in `backend_reply`
  fails, `backend_reply` returns non-zero, and `inbox.sh` substitutes its existing
  "I hit an error processing that message" reply. The user can run `/cwd default`
  or recreate the folder.
- **Path injection** is not a concern: the path is only ever used as `cd "$path"`
  (quoted), never `eval`'d or word-split. The validation regex exists to catch
  typos and enforce the absolute/`~` form, not for shell safety.

## Testing (bats)

- `test/bats/workdir.bats`:
  - `conversation_workdir` returns the auto default `$STATE_DIR/work/<slug>` when
    no override is set, and creates it on demand.
  - returns the override path when `$SESSIONS_DIR/<slug>/workdir` is set.
  - expands a leading `~` to `$HOME`.
- `test/bats/commands.bats` additions:
  - `/cwd` with no override reports the auto default.
  - `/cwd ~/existing-dir` persists the expanded absolute path and replies success.
  - `/cwd default` removes the override and reverts to the auto folder.
  - `/cwd <relative>`, `/cwd <nonexistent>`, and `/cwd <file-not-dir>` are rejected
    with an error reply and persist nothing.

The `cd`-in-`backend_reply` path is not unit-testable without `claude`, so it is
covered indirectly by the resolver and command tests — consistent with how the
repo already tests backends.
