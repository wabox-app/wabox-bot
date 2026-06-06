# Migrating from `wabox/examples/wabox-claude-code.sh`

wabox-bot is the successor to the in-tree
[`examples/wabox-claude-code.sh`](https://github.com/rodgco/wabox/blob/v0.1.10/examples/wabox-claude-code.sh)
script. With the default `claude-code` backend, conversation history, slash
commands, and per-conversation preferences all carry over automatically.

## TL;DR

```bash
curl -fsSL https://raw.githubusercontent.com/wabox-app/wabox-bot/main/install.sh | bash
~/.local/bin/wabox-bot
```

Your existing Claude sessions resume on the same `session_id` as before.

## What carries over unchanged

- **All wabox-side env vars**: `WABOX_INBOX`, `WABOX_OUTBOX`, `STATE_DIR`,
  `PROCESSED_DIR`, `LOG_FILE`, `KEEP_PROCESSED`, `IGNORE_FROM_ME`,
  `GROUP_PER_PARTICIPANT`, `SYSTEM_PROMPT_FILE`.
- **All Claude-side env vars**: `CLAUDE_BIN`, `CLAUDE_ARGS`,
  `CLAUDE_TIMEOUT`.
- **Slash commands**: `/clear`, `/reset`, `/ping`, `/status`, `/model`,
  `/mode`, `/system`, `/help` — all behave identically. The reply text is
  byte-identical for everything except `/status` (see below).

## What changes

### `/status` now reports the active backend

The reply now includes an extra `backend: claude-code` line above the
`session: …` block. The other fields are unchanged.

### State directory default

| Old default | New default |
| --- | --- |
| `~/.local/state/wabox-claude/` | `~/.local/state/wabox-bot/` |

If you used the default and didn't set `STATE_DIR` explicitly, wabox-bot
**auto-renames the directory** on first start. The move happens before the
new daemon writes anything, so nothing is lost.

If you set `STATE_DIR` to a custom path, you don't need to do anything —
wabox-bot uses the same path.

### PID lock filename

| Old | New |
| --- | --- |
| `$STATE_DIR/agent.lock` | `$STATE_DIR/wabox-bot.lock` |

The stale `agent.lock` left behind by the old daemon name is removed on
first run. The new daemon takes its single-instance lock on
`wabox-bot.lock`.

### Per-conversation state layout

Per-conversation files are now namespaced by backend so switching backends
doesn't smush state together.

| Old (flat) | New (namespaced) |
| --- | --- |
| `$SESSIONS_DIR/<slug>.session` | `$SESSIONS_DIR/<slug>/claude-code/session` |
| `$SESSIONS_DIR/<slug>.model`   | `$SESSIONS_DIR/<slug>/claude-code/model` |
| `$SESSIONS_DIR/<slug>.mode`    | `$SESSIONS_DIR/<slug>/claude-code/mode` |
| `$SESSIONS_DIR/<slug>.system`  | `$SESSIONS_DIR/<slug>/claude-code/system` |

`lib/migrate.sh` runs at startup and **moves the flat files into the
namespaced layout when the default `claude-code` backend is active**. The
migration is idempotent — running wabox-bot a second time finds nothing to
do.

If you start wabox-bot with `--backend echo` (or any non-default backend)
on a state directory that still has flat files, the migration is skipped
and the flat files stay in place. The next run with `--backend claude-code`
picks them up.

## Verifying the migration

After the first start, you should see one or both of these log lines:

```
migrate: removed stale agent.lock
migrate: moved N legacy flat session files into <slug>/claude-code/
```

Then `/status` from an existing conversation should show your old
`session_id` and preferences:

```
Status:
conv:    5511999999999@s.whatsapp.net
backend: claude-code
session: <your existing session id>
model:   <your override, if any>
mode:    <your override, if any>
system:  <(none) or (set, N chars)>
```

If the session id is `(none)`, something went wrong — open an issue at
<https://github.com/wabox-app/wabox-bot/issues> with the contents of
`$STATE_DIR/agent.log`.

## Going back

If you need to roll back to the in-tree script, the state files still live
under the new namespaced layout. Move them back to flat:

```bash
cd "$HOME/.local/state/wabox-bot/sessions"
for slug in */; do
  slug="${slug%/}"
  [[ -d "$slug/claude-code" ]] || continue
  for f in "$slug/claude-code"/*; do
    suffix="$(basename "$f")"
    mv "$f" "$slug.$suffix"
  done
  rmdir "$slug/claude-code" "$slug" 2>/dev/null || true
done
```

Then point the old script at the same `STATE_DIR`. The `.lock` filename
difference is harmless — the old script writes its own `agent.lock`.
