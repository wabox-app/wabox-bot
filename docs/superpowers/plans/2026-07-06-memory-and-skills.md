# Memory & Skills Conventions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Seed new default workdirs with a WhatsApp-etiquette + memory-practice instructions file (`CLAUDE.md` / `AGENTS.md` per backend), give every conversation durable `MEMORY.md` memory that survives `/clear`, add a read-only `/memory` command, and mount shared skills via one symlink.

**Design:** [2026-07-06-memory-and-skills-design.md](../specs/2026-07-06-memory-and-skills-design.md) — decisions there are binding (seed in `conversation_workdir`, default workdirs only, seed-if-absent, one template with per-backend filename, symlink not copy).

**Tech Stack:** Pure bash 4+; bats; `shellcheck -x`.

---

## File Structure

- **Modify** `lib/workdir.sh` — hook dispatch in `conversation_workdir()`.
- **Create** `templates/workdir-instructions.md` — shipped template.
- **Modify** `lib/backends/claude-code.sh` — `backend_seed_workdir` (CLAUDE.md + skills symlink).
- **Modify** `lib/backends/agy.sh`, `lib/backends/bob.sh` — `backend_seed_workdir` (AGENTS.md).
- **Modify** `lib/commands.sh` — `/memory`.
- **Modify** `lib/config.sh`, `config.example` — `WABOX_WORKDIR_TEMPLATE`, `CC_SHARED_SKILLS_DIR`.
- **Create** `test/bats/seed.bats`; extend commands bats.
- **Modify** `README.md`, `docs/backends.md`, `CHANGELOG.md`.

Order: Task 1 → 2 → 3 → 4 → 5 → 6. Tasks 3–4 depend on 1+2.

---

## Task 1: Hook dispatch in `conversation_workdir()` (`lib/workdir.sh`)

- [ ] After `mkdir -p`: when no `/cwd` override is in effect (the resolved dir is `$STATE_DIR/work/$slug`) and `declare -F backend_seed_workdir`, call `backend_seed_workdir "$slug" "$dir"`; hook failures log a warning, never fail the turn.
- [ ] Guard against recursion/noise: hook runs every resolution; implementations must be cheap-idempotent (documented in `docs/backends.md`).
- [ ] bats: hook called for default dir; NOT called for `/cwd`-overridden dir; absent hook is a no-op; failing hook doesn't break resolution.

## Task 2: The template (`templates/workdir-instructions.md`)

- [ ] Write the shipped template per the design: WhatsApp markup cheatsheet (no headings/links, `*bold*`/`_italic_`/monospace), chat-sized replies with "long content → file in the send folder", match the user's language, and the memory practice block ("read `MEMORY.md` if present; append/prune short durable facts; survives session resets").
- [ ] Keep it under ~40 lines — it's loaded into every turn's context.
- [ ] `lib/config.sh` + `config.example`: `WABOX_WORKDIR_TEMPLATE` (default `$ROOT/templates/workdir-instructions.md`; empty string disables seeding), `CC_SHARED_SKILLS_DIR` (default empty).

## Task 3: claude-code seed hook

- [ ] `backend_seed_workdir <slug> <workdir>`: template resolvable + `CLAUDE.md` absent ⇒ copy template as `CLAUDE.md`.
- [ ] Skills: `CC_SHARED_SKILLS_DIR` set + readable + `<workdir>/.claude/skills` absent ⇒ `mkdir -p <workdir>/.claude` and symlink. Existing dir or link (even broken) is never touched.
- [ ] bats: fresh workdir gets both; existing `CLAUDE.md` untouched on re-seed; `WABOX_WORKDIR_TEMPLATE=""` seeds nothing; local skills dir wins over symlink; broken existing link left alone.

## Task 4: agy + bob seed hooks

- [ ] Both: same template written as `AGENTS.md` (absent ⇒ copy; else no-op). No skills symlink (claude-specific).
- [ ] bats: parametrized over the two backends — seed, idempotence, disable via empty template var.

## Task 5: `/memory` command (`lib/commands.sh`)

- [ ] `/memory`: resolve workdir (without creating it — use the non-creating resolver in `workdir.sh`); reply with `MEMORY.md` content (WhatsApp-monospace-wrapped) or "Sem memória ainda." when absent/empty; oversize (>3000 chars) ⇒ head + "… (arquivo completo em <path>)".
- [ ] Register in `/help`; works via `wabox-bot cmd <slug> /memory` for free.
- [ ] bats: content reply; empty reply; truncation; cmd-verb path.

## Task 6: Docs

- [ ] `README.md`: "Memory & skills" section — the seeded file per backend, MEMORY.md lifecycle (`/clear` keeps it, `/memory` shows it, `$EDITOR` edits it), `CC_SHARED_SKILLS_DIR` with the curate-like-code warning; config table rows.
- [ ] `docs/backends.md`: `backend_seed_workdir` under "Optional" (args, cheap-idempotent requirement, default-workdir-only guarantee from core).
- [ ] `CHANGELOG.md`: Unreleased → Added (seeding, template, `/memory`, shared skills).
- [ ] `shellcheck -x` clean; full bats suite green.
