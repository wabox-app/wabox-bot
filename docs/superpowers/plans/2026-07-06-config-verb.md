# `config` Verb Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `wabox-bot config list --json | get <VAR> | set <VAR> <value> | unset <VAR>` — structured, registry-guarded read/write access to the config file, so tooling (wabox-tui Config screen) never rewrites sourced bash heuristically.

**Design:** [2026-07-06-config-verb-design.md](../specs/2026-07-06-config-verb-design.md) — decisions there are binding (single `CONFIG_VARS` registry, masked `list` / raw `get`, plain-assignment rewrites via `printf %q`, env-override warning, no reload semantics).

**Tech Stack:** Pure bash 4+; `jq -n`; bats; `shellcheck -x`.

---

## File Structure

- **Modify** `lib/config.sh` — `CONFIG_VARS` registry + shared `config_is_secret` / mask helper; `print_config` consumes them.
- **Create** `lib/configverb.sh` — `configverb_main`.
- **Modify** `bin/wabox-bot` — `config` subcommand + `usage()`.
- **Create** `test/bats/configverb.bats`.
- **Modify** `README.md`, `CHANGELOG.md`.

Order: Task 1 → 2 → 3 → 4. Task 2 depends on 1.

---

## Task 1: Registry extraction (`lib/config.sh`)

- [ ] `CONFIG_VARS=(…)` — every var `--print-config` lists today plus any documented in `config.example` (core loop, backend `CLAUDE_*`/`CC_*`/`BOB_*`/`AGY_*`, transcription, rich-reply, proactive, seeding vars).
- [ ] `config_is_secret <var>` (the `*KEY*|*TOKEN*|*SECRET*` heuristic) and `config_mask <value>` extracted; `print_config` refactored onto both — output byte-identical (bats golden test).
- [ ] bats: registry ⊇ and ⊆ the assignments in `config.example` (drift guard both directions).

## Task 2: `lib/configverb.sh`

- [ ] `list --json`: iterate `CONFIG_VARS`; effective value via indirect expansion (`${!var-}`); mask secrets; `set_in_file` by scanning the config file for a non-comment `^\s*VAR=` line. Assemble with `jq -n` — no string-built JSON.
- [ ] `get <VAR>`: registry guard (unknown ⇒ exit 1, list-style error naming the flag to see all vars); print raw effective value; distinguish empty-set from unset in a trailing stderr note only when stderr is a TTY.
- [ ] `set <VAR> <value>`: registry guard; ensure config file exists (create from template via the `--init-config` path); replace all non-comment assignment lines for VAR with one `VAR=$(printf %q)` line in place (first occurrence position), or append under a `# managed by wabox-bot config` marker when absent; tmp + `mv`.
- [ ] `unset <VAR>`: registry guard; delete non-comment assignment lines; idempotent exit 0.
- [ ] Env-override warning on `set`/`unset` when the var is exported in the current environment with a different value.
- [ ] bats: list shape + masking + `set_in_file`; get raw secret; set on fresh file (created), on template-form line (replaced with plain assignment, comments preserved), value with spaces/quotes/newline round-trips through `get`; unset restores default and is idempotent; unknown var ⇒ 1 for all four; env-override warning fires.

## Task 3: Wire-up (`bin/wabox-bot`)

- [ ] `config` subcommand dispatch — verify no collision with the existing `--config <path>` flag and `--init-config`/`--print-config` modes (subcommand check happens where `state`/`answer`/`cmd` already dispatch, before flag parsing; `--config <path>` continues to select the file the verb operates on).
- [ ] `usage()` updated; unknown subaction ⇒ usage + exit 1.
- [ ] bats: `wabox-bot --config <alt> config set …` writes the alternate file.

## Task 4: Docs

- [ ] `README.md`: `config` in usage; "External tooling" section gains the verb (get is raw / list is masked, restart-required note, hand-edit escape hatch for computed values).
- [ ] `CHANGELOG.md`: Unreleased → Added.
- [ ] `shellcheck -x` clean; full bats suite green (including the `--print-config` golden).
