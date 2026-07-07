# Inbound Documents Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stage inbound `document` media into the workdir and hand it to the backend (like images), guard against oversize files with a user-facing notice, and stop losing captions on unsupported media types.

**Design:** [2026-07-06-inbound-documents-design.md](../specs/2026-07-06-inbound-documents-design.md) — decisions there are binding (100 MB default guard, caption passthrough with bracketed note, video/sticker stay unsupported).

**Tech Stack:** Pure bash 4+; bats; `shellcheck -x`.

---

## File Structure

- **Modify** `lib/inbox.sh` — `document` case; caption passthrough for unsupported types.
- **Modify** `lib/media.sh` — `media_size_mb` helper.
- **Modify** `lib/backends/claude-code.sh`, `lib/backends/agy.sh`, `lib/backends/bob.sh` — composer sentence.
- **Modify** `lib/config.sh`, `config.example` — `WABOX_DOC_MAX_MB` (default 100).
- **Extend** `test/bats/` inbox/media tests.
- **Modify** `docs/backends.md`, `README.md`, `CHANGELOG.md`.

Order: Task 1 → 2 → 3 → 4. Task 2 depends on 1.

---

## Task 1: Size helper (`lib/media.sh`)

- [ ] `media_size_mb <path>`: `stat -c %s` (fallback `stat -f %z` is NOT needed — Linux-only daemon per README requirements; keep it simple), integer MB rounded up.
- [ ] bats: exact-boundary and rounding cases.

## Task 2: `document` case + guard (`lib/inbox.sh`)

- [ ] In the media `case`: `document)` — size ≤ `WABOX_DOC_MAX_MB` ⇒ keep `media_rel`/`media_type`/`media_mime` and fall through to the backend (mirror the `image)` branch).
- [ ] Oversize ⇒ do not stage; `write_outbox` the short notice (size + limit); when a caption exists, continue the turn with the caption as plain text; else return.
- [ ] `last_message.json` preview for documents: `"[document]"` (matches the existing media-placeholder pattern).
- [ ] bats: staged document reaches the backend with type/mime; oversize sends notice and doesn't stage; oversize with caption still runs a text turn.

## Task 3: Caption passthrough for unsupported types (`lib/inbox.sh`)

- [ ] `video`/`sticker`/`*)` with non-empty `text`: prepend `[o usuário enviou um vídeo/figurinha/arquivo não suportado — não consigo processá-lo]` to the text and continue as a plain text turn (no staging, media args empty).
- [ ] Bare unsupported media (no caption): skip + log, exactly as today.
- [ ] bats: video with caption processed with the note; bare video skipped; unknown future type follows the same path.

## Task 4: Backend composers + config + docs

- [ ] `cc_compose_prompt`: `document` branch — "The user sent a file at %s (%s) — read it and respond." (+ caption when present); agy and bob composers get the equivalent line.
- [ ] `lib/config.sh` + `config.example`: `WABOX_DOC_MAX_MB=100` with a comment.
- [ ] `docs/backends.md`: media contract `image | document` (drop the "only ever image" sentence).
- [ ] `README.md`: media support matrix (image ✓, audio → transcript, document ✓ ≤ limit, video/sticker caption-only).
- [ ] `CHANGELOG.md`: Added (document support, `WABOX_DOC_MAX_MB`) + Fixed (captions on unsupported media no longer lost).
- [ ] bats per backend composer (stubbed CLI asserting the prompt); `shellcheck -x` clean; suite green.
