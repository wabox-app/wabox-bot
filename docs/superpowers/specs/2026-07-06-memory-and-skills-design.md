# Per-conversation memory & skills conventions

**Date:** 2026-07-06
**Status:** Draft (design)

## Problem

Each conversation already has an isolated workdir and a persistent session,
but the agent starts every conversation ignorant of the medium and forgets
everything on `/clear`. Concretely: agents emit Markdown that WhatsApp renders
as literal `#` and `[]()` junk; nothing tells them replies should be
chat-sized; durable facts ("my wife is Ana", "the report goes out Fridays")
live only in session history, so `/clear` — the standard fix for a wedged or
bloated session — is a lobotomy. Meanwhile the agent CLIs already solve this:
`claude` auto-loads `CLAUDE.md` from cwd and `.claude/skills/`; agy and bob
read `AGENTS.md`. The bot just never puts anything there.

## Goal

- A new conversation's default workdir is seeded with an instructions file
  teaching WhatsApp etiquette, the send-folder, and a memory practice.
- Durable memory lives in `MEMORY.md` in the workdir — surviving `/clear`,
  visible to the operator, one file per conversation.
- Shared skills can be mounted into every new conversation via one config var.
- All of it is convention + a seeding hook — no new runtime machinery.

## Non-goals

- A memory *system* (indexing, recall tooling, size management). The file and
  the instruction are the feature; the agent maintains it. OpenClaw's
  MEMORY.md/SOUL.md persistence was also its malware-persistence vector — we
  keep memory a plain file the operator can `cat`.
- A skills marketplace or fetcher. `CC_SHARED_SKILLS_DIR` points at a folder
  the operator curates (git clone, whatever) — deliberately no registry.
- Seeding user-redirected workdirs. `/cwd ~/Valter` points at the user's own
  folder; writing boilerplate there is invasive. Redirected conversations can
  get the file manually.
- Migrating existing conversations. Seed-if-absent applies on their next turn
  anyway (default workdirs only).

## Decisions

- **Seeding lives in `conversation_workdir()`.** It's the single choke point —
  `lib/inbox.sh`, `lib/prompt.sh`, and all three real backends resolve through
  it. After `mkdir -p`, when the dir is the **auto default** (no `/cwd`
  override), call the optional backend hook `backend_seed_workdir <slug>
  <workdir>`. Core stays backend-agnostic; the hook decides file names.
- **Seed-if-absent, never overwrite.** The user's edits (or the agent's) win
  forever; seeding is idempotent and costs one `[[ -e ]]` per turn.
- **One shipped template, backend-appropriate filename.**
  `templates/workdir-instructions.md`, overridable via
  `WABOX_WORKDIR_TEMPLATE` (empty disables seeding). `claude-code` writes it
  as `CLAUDE.md`; `agy` and `bob` write it as `AGENTS.md`. Same content —
  it's medium etiquette, not backend configuration:
  - WhatsApp markup, not Markdown (`*bold*`, `_italic_`, no headings/links —
    mirrors wabox-core's INTEGRATION.md guidance).
  - Chat-sized replies; long content → a file in the send folder.
  - Match the user's language.
  - **Memory practice:** "Read `MEMORY.md` if present. When you learn a
    durable fact/preference/commitment, update it — short bullet lines,
    prune stale entries. Session resets don't touch it."
  - The send-folder line stays in the system-prompt advert
    (`CC_ADVERTISE_SEND_DIR`) — the template *reinforces* it, since template
    and advert can be independently disabled.
- **`/memory` core slash command.** Replies with the conversation's
  `MEMORY.md` (or "no memory yet"). Read-only, works for every backend (it's
  just a file in the workdir), and gives users visibility into what the agent
  retains — the transparency OpenClaw's incident showed matters. Editing stays
  in chat ("esqueça X") or `$EDITOR` on the file.
- **Shared skills: `CC_SHARED_SKILLS_DIR`.** When set and the workdir has no
  `.claude/skills`, the claude-code seed hook symlinks
  `<workdir>/.claude/skills → $CC_SHARED_SKILLS_DIR`. A symlink, not a copy:
  the operator updates one folder, every conversation follows. Conversations
  can break the link and go local by replacing it with a real dir.

## Architecture

- **Modify `lib/workdir.sh`** — default-dir detection + hook dispatch in
  `conversation_workdir()`.
- **Create `templates/workdir-instructions.md`** — the shipped template.
- **Modify `lib/backends/claude-code.sh`** — `backend_seed_workdir`
  (CLAUDE.md + skills symlink).
- **Modify `lib/backends/agy.sh`, `lib/backends/bob.sh`** —
  `backend_seed_workdir` (AGENTS.md).
- **Modify `lib/commands.sh`** — `/memory`.
- **Modify `lib/config.sh`, `config.example`** — `WABOX_WORKDIR_TEMPLATE`,
  `CC_SHARED_SKILLS_DIR`.
- **Modify `docs/backends.md`** — the hook, for backend authors.

## Risks / notes

- A hostile *user* can instruct the agent to poison its own MEMORY.md — same
  trust boundary as every agent action in that workdir today (per-conversation
  isolation is exactly why this stays contained). `/memory` makes it auditable.
- MEMORY.md can grow; the template's "keep it short, prune" instruction is the
  only limiter in v1. If it becomes a problem, size warnings in `/status` are
  the natural P2.
- Shared-skills symlink means every conversation trusts that folder — document
  that it's equivalent to granting those skills to all chats (ClawHavoc
  lesson: curate it like code you run).
- Template changes only affect *new* workdirs (seed-if-absent). Fine — it's
  guidance, not config.
