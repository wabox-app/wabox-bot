# Configuration file for all env vars

**Date:** 2026-06-06
**Status:** Approved (design)

## Problem

wabox-bot is configured entirely through environment variables, now spread
across the core (`WABOX_INBOX`, `STATE_DIR`, `KEEP_PROCESSED`, …), the
`claude-code` backend (`CLAUDE_BIN`, `CLAUDE_ARGS`, …), and the transcription
plugins (`WABOX_TRANSCRIBE_CMD`, `WABOX_FW_*`, `WABOX_STT_*`, …). Managing that
many vars by exporting them in a shell profile is unwieldy. We want a single
config file that holds all of them.

## Goal

- One file holds every wabox-bot environment variable.
- The bot loads it at startup and **exports** the values, so subprocesses (the
  `claude` CLI, the `plugins/*/transcribe.sh` scripts) inherit them.
- A shipped, commented template lists **all** variables.
- Helper flags to scaffold (`--init-config`) and inspect (`--print-config`).

## Non-goals

- A non-shell format (YAML/TOML/INI). The config is sourced bash — it already
  matches the env-var model and supports comments and cross-references.
- A config-file migration of plugin defaults: plugin scripts keep their own
  `${VAR:-default}` fallbacks; the file just centralizes overrides.
- Per-conversation config (that stays in the slug state dir, unchanged).

## Decisions (from brainstorming)

- **Location:** default `${XDG_CONFIG_HOME:-$HOME/.config}/wabox-bot/config`,
  overridable by the `WABOX_BOT_CONFIG` env var or the `--config <path>` flag
  (flag > env > default).
- **Precedence:** the **environment overrides the file**. The shipped template
  uses the `WABOX_X="${WABOX_X:-value}"` form so an already-set env var wins; a
  user may write a bare `WABOX_X=value` to force a value from the file.
- **Format:** a bash file, sourced.
- **Helpers:** `--init-config` (install the template) and `--print-config`
  (dump effective values, secrets masked).

## Architecture

### Loading (`lib/config.sh`)

At the very top of `config.sh`, before any variable resolution:

```bash
WABOX_BOT_CONFIG="${WABOX_BOT_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/wabox-bot/config}"
if [[ -f "$WABOX_BOT_CONFIG" ]]; then
  set -a            # allexport: everything the file sets is exported,
  # shellcheck disable=SC1090
  source "$WABOX_BOT_CONFIG"
  set +a
fi
```

`set -a` means subprocesses inherit the values regardless of whether the user
wrote `export`. The existing `${VAR:-default}` lines further down still apply as
the final fallback for anything the file didn't set. Because the template uses
`${VAR:-value}`, a var already present in the environment is preserved
(environment wins).

`config.sh` is sourced first by both `bin/wabox-bot` and the test `load_core`,
so the file is loaded in tests too.

### CLI (`bin/wabox-bot`)

The entrypoint's argument parser gains three options, two of which are
early-exit modes handled **before** the dependency check and main loop:

- **`--config <path>` / `--config=<path>`**: set `WABOX_BOT_CONFIG` before
  `config.sh` is sourced. If the path does not exist, fail with a clear error
  and non-zero exit (an explicitly named config that is missing is an error,
  unlike the default path which is silently optional).
- **`--init-config`**: copy the repo's `config.example` to `$WABOX_BOT_CONFIG`
  (creating its parent directory) and exit 0. If the destination already
  exists, refuse with a message (do not overwrite) and exit non-zero. Sources
  nothing, needs no runtime dependencies.
- **`--print-config`**: source `config.sh` and the selected backend file (to
  pick up backend defaults like `CLAUDE_*`), then print effective values and
  exit 0 — **without** running `check_dependencies`, the single-instance lock,
  or the main loop (so it works in CI without `claude`/`inotifywait`).

`usage()` is updated to document all three.

### `print_config` (`lib/config.sh`)

A `print_config()` function prints the resolved core variables as `NAME=value`
(showing `(unset)` for empties), then dumps every environment variable whose
name starts with `WABOX_`, `CLAUDE_`, or equals `SYSTEM_PROMPT_FILE` (catch-all
that covers backend and plugin vars). Values of variables whose name matches
`*KEY*`, `*TOKEN*`, or `*SECRET*` are masked: printed as `(set)` when non-empty,
`(unset)` when empty — never the literal secret. The entrypoint calls this for
`--print-config`.

## The template: `config.example` (repo root)

Single source of truth for the template; `--init-config` installs it verbatim.
Grouped and commented: Core, Backend: claude-code, Transcription (core),
Transcription plugins. Variables with a sensible built-in default are **active**
in the `${VAR:-default}` form (copying and running changes nothing — the
defaults equal the built-ins). Variables with no default (API keys, required
model paths) are left **commented out** with an example value, so they are
discoverable without injecting an empty value. A header explains it is sourced
as bash and that the environment overrides it.

The example must pass `shellcheck` (it is valid shell).

## Documentation

- **README:** add a "Configuration file" section — recommend
  `wabox-bot --init-config` then editing `~/.config/wabox-bot/config`; document
  `--config`/`--print-config` and the environment-wins precedence. Keep the env
  var reference table, noting these can all live in the file.
- **docs/backends.md:** note that backend env vars also belong in the config
  file (sourced and exported before the backend loads).
- **CONTRIBUTING.md / `usage()`:** reflect the new flags.
- **CHANGELOG.md:** `[Unreleased]` → Added.
- **CI:** add `config.example` to the shellcheck set.

## Testing (bats)

- **Loading & precedence** (`test/bats/config.bats`):
  - With `WABOX_BOT_CONFIG` pointing at a temp file that sets `KEEP_PROCESSED=0`
    and `CLAUDE_TIMEOUT=42`, sourcing the core applies those values.
  - With the same var also set in the environment, the environment value wins
    (template `${VAR:-…}` form) — assert via a temp file using that form.
  - A value set by the file is exported (visible to a child process / `export -p`).
  - A missing default config path is silently ignored (no error).
- **`--init-config`** (subprocess): with `WABOX_BOT_CONFIG` at a temp path,
  `bin/wabox-bot --init-config` creates a file byte-identical to `config.example`;
  a second run refuses (exit non-zero, file unchanged).
- **`--print-config`** (subprocess): prints `NAME=value` lines for set vars; a
  set `WABOX_STT_API_KEY` is shown as `(set)`, never its value; exits 0 without
  requiring `claude` on PATH.
- **`--config <missing>`** (subprocess): exits non-zero with a clear error.

## Error handling

- Default config path absent → ignored; built-in defaults apply.
- `--config <path>` naming a non-existent file → error + non-zero exit.
- `--init-config` with an existing destination → refuse, do not overwrite, exit
  non-zero.
- Config file is sourced as bash (user-owned, under their config dir) — a syntax
  error aborts startup with bash's own message; documented and acceptable.
- `--print-config` masks `*KEY*`/`*TOKEN*`/`*SECRET*` so output is shareable.
