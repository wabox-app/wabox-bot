# `config` verb: list/get/set/unset from the CLI

**Date:** 2026-07-06
**Status:** Draft (design)
**Consumer driving this:** wabox-tui v2 Config screen — a form over the bot's configuration needs a safe, structured read/write path.

## Problem

The config file is sourced bash. External tooling that wants to change a value
has two bad options: rewrite the file heuristically (fragile against comments,
`${VAR:-default}` template forms, and quoting) or ask the user to open
`$EDITOR`. Reading is only half-solved: `--print-config` is human-formatted and
unparseable. The knowledge of which vars exist, which are secrets, and how the
file is shaped lives in wabox-bot — the verb belongs here.

## Goal

```
wabox-bot config list --json   # all known vars, structured, secrets masked
wabox-bot config get <VAR>     # effective value, raw, exit 0
wabox-bot config set <VAR> <value>
wabox-bot config unset <VAR>   # remove the file override → back to default
```

## Non-goals

- Live reload (SIGHUP). The daemon reads config at startup; `set`/`unset`
  print a "restart the daemon to apply" notice and the TUI surfaces it.
  Reload semantics are a separate future design if labeling proves annoying.
- Editing arbitrary/unknown vars. The verb refuses names outside the known
  registry — the config file remains hand-editable for exotic needs.
- Editing wabox-core's config. Different repo, different format (JSON),
  different verb (`wabox`).
- Schema validation of values (enum checking `WABOX_QUOTE_REPLY`, etc.) in v1.
  The registry carries the value as a string; per-var validators are P1.

## Decisions

- **A single canonical registry.** `--print-config` already holds the
  known-var list inline; extract it to a `CONFIG_VARS` array in `lib/config.sh`
  (name only), the one source of truth for `--print-config`, `list`, and the
  `set`/`unset` guard. Backend-specific vars (`CLAUDE_*`, `CC_*`, `BOB_*`,
  `AGY_*`, transcription `WABOX_FW_*`…) are included — the registry is "what
  the config template documents", not "what the core loop uses".
- **`list --json` shape:**
  `[{ "var": "...", "value": "...", "secret": false, "set_in_file": true }]`
  - `value` is the *effective* value; vars matching the existing secret
    heuristic (`*KEY*|*TOKEN*|*SECRET*`) are masked (`"••••"`) with
    `"secret": true` — same rule as `--print-config`, one shared helper.
  - `set_in_file`: whether the config file carries a non-comment assignment
    for the var (an explicit override vs. inherited default) — what the TUI
    renders as "modified" and what `unset` removes. No `default` field in v1:
    computing it would mean re-sourcing config in a scrubbed environment;
    `unset` + re-`get` answers the same question operationally.
- **`get` prints raw, including secrets.** It's the operator's own machine and
  the value is one `grep` away regardless; `list` (the bulk/display surface)
  masks. Documented explicitly.
- **`set` rewrites atomically and simply.** Value written as
  `VAR=<printf %q value>` (never inside `${VAR:-…}` template forms — a `set`
  *replaces* the var's line(s) with a plain assignment; the template form is
  for defaults, an explicit set is an explicit set). Missing file ⇒ created
  via the `--init-config` template first, then edited. tmp + `mv` write; the
  file's comments and unrelated lines are preserved (line-targeted edit, not
  regeneration).
- **`unset` deletes the var's assignment line(s)**, restoring template/default
  behavior. Idempotent: unsetting a var not in the file exits 0 quietly.
- **Environment-override warning.** Env beats file (existing precedence), so
  `set`/`unset` check whether the var is currently exported in the calling
  environment with a *different* value and print a warning ("env var overrides
  the file — the daemon may not see this change") — mirroring the pattern
  wabox-core's `allow` uses. Exit still 0; it's a warning, not an error.
- **Exit codes:** `0` ok · `1` usage / unknown var. (No lock needed — config
  writes are whole-file atomic and the daemon only reads at startup.)

## Architecture

- **Modify `lib/config.sh`** — extract `CONFIG_VARS` registry + shared
  mask helper; `--print-config` consumes them (behavior unchanged).
- **Create `lib/configverb.sh`** — `configverb_main list|get|set|unset …`.
- **Modify `bin/wabox-bot`** — `config` subcommand (careful: `--init-config` /
  `--print-config` flags already exist and stay; `config` as a *subcommand*
  must not collide with the config-*path* resolution order).
- **Modify `README.md`, `CHANGELOG.md`;** `docs/backends.md` untouched.

## Risks / notes

- A user's hand-written config line with side effects (e.g. sourcing another
  file, computed values) — `set` on that var replaces the computed line with a
  literal. Acceptable and predictable, but the docs say so: `config set` is
  for values, hand-edit for cleverness.
- Multi-line or exotic values survive via `printf %q`, but become ugly in the
  file. Fine — correctness over beauty; the TUI reads them back through `get`.
- The registry drifting from `config.example` is the real maintenance risk:
  a bats test asserts every var in `config.example` is in `CONFIG_VARS` and
  vice versa, so CI catches drift.
