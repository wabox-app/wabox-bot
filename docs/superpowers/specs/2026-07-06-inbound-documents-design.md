# Inbound documents

**Date:** 2026-07-06
**Status:** Draft (design)

## Problem

wabox-core delivers five media types (`image`, `video`, `audio`, `document`,
`sticker`); wabox-bot handles two. A user who WhatsApps a PDF ("resume isso
pra mim") gets silence — the envelope is skipped with a log line, and the
*caption is lost with it*. Documents are the highest-value untapped type:
agents read PDFs, spreadsheets, and text files natively, and "mande o
contrato aí" is a core personal-agent flow.

## Goal

- `document` media is staged into the workdir and handed to the backend, like
  images are today.
- Unsupported media with a caption no longer swallows the caption.
- An oversize guard keeps a 2 GB WhatsApp document from being blindly copied.

## Non-goals

- `video` — agents can't watch video; stays unsupported (but captions now
  survive, see below).
- `sticker` — technically a webp image; near-zero task value. P2 at most.
- Document *generation* improvements (that's the send folder, already shipped).
- OCR/scan preprocessing — the agent's own tooling decides how to read the
  file; the bot only stages bytes.

## Decisions

- **`document` joins `image` in the staging path.** Same `media_stage` call,
  same relative-path handoff, `media_type="document"`. The backend contract's
  media values become `image | document` (docs updated; backends that ignore
  media keep ignoring it).
- **Prompt composition per backend, same sentence shape.** claude-code's
  `cc_compose_prompt` gains: "The user sent a file at %s (%s) — read it and
  respond." (path, MIME). agy and bob mirror it in their composers. MIME is
  included because extension-less names are common on WhatsApp forwards.
- **Oversize guard: `WABOX_DOC_MAX_MB`, default 100.** Larger ⇒ not staged;
  the user gets a short reply ("Arquivo muito grande (%(size)s) — consigo ler
  até %(max)s MB.") instead of silence, and the caption still goes through as
  text when present. Applies to documents only (images/audio already have
  WhatsApp's own ~16 MB ceiling).
- **Captions survive unsupported media.** For `video`, `sticker`, and any
  future unknown type: when the envelope has caption text, process it as a
  plain text turn with a bracketed note prepended for the agent's context
  (`[o usuário enviou um vídeo, que não consigo processar]`); only a *bare*
  unsupported media is skipped as today. This fixes real message loss, not
  just the document case.
- **No retention special-casing.** Staged documents live in the media dir and
  age out via `gc` like any staged media (workdir-lifecycle release).

## Architecture

- **Modify `lib/inbox.sh`** — `document` case (stage + size guard + notice);
  caption-passthrough for unsupported types.
- **Modify `lib/media.sh`** — `media_size_mb` helper (stat-based; no `du`).
- **Modify `lib/backends/claude-code.sh`, `agy.sh`, `bob.sh`** — composer
  sentence for `document`.
- **Modify `lib/config.sh`, `config.example`** — `WABOX_DOC_MAX_MB`.
- **Modify `docs/backends.md`** — media contract now `image | document`.

## Risks / notes

- Coordination: the workdir-lifecycle release moves the media dir under
  `.wabox/`; this design doesn't care (it goes through `media_stage`), so the
  two land in either order.
- A malicious document is inert bytes until the agent opens it with its own
  tools — the existing agent permission boundary; nothing new is executed by
  the bot. Prompt-injection *inside* documents ("ignore your instructions…")
  is the same exposure images already have; the CLAUDE.md template's etiquette
  section is the mitigation layer we own.
- `processed/` keeps its audit copy of every document — large inboxes grow
  faster; `WABOX_PROCESSED_KEEP_DAYS` (lifecycle release) is the answer.
