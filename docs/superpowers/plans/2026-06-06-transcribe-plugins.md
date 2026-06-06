# Transcription Plugins Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a top-level `plugins/` folder with five ready-made `WABOX_TRANSCRIBE_CMD` transcribers, each a `transcribe.sh` entrypoint plus an install/config README.

**Architecture:** Each plugin is a self-contained `plugins/<name>/transcribe.sh` conforming to the contract (audio path as last arg, transcript to stdout, non-zero/empty on failure), plus `plugins/<name>/README.md`. A `test/bats/plugins.bats` structure test guards each plugin (executable script, shebang, `bash -n`, README present). CI shellchecks the scripts. No functional STT runs in CI.

**Tech Stack:** Bash 4+ wrappers (some embedding a `python3` heredoc), `ffmpeg`, `curl`; bats for the structure test; `shellcheck -x`.

---

## File Structure

```
plugins/
  README.md                          # index + contract + WABOX_TRANSCRIBE_LANG
  faster-whisper/    { transcribe.sh, README.md }
  whisper-cpp/       { transcribe.sh, README.md }
  openai-whisper/    { transcribe.sh, README.md }
  vosk/              { transcribe.sh, README.md }
  openai-compatible/ { transcribe.sh, README.md }
test/bats/plugins.bats               # structure guard (one @test per plugin)
```

- **Modify** `.github/workflows/ci.yml` — add `shellcheck plugins/*/transcribe.sh`.
- **Modify** `README.md` — pointer to `plugins/` near the transcribe config rows.
- **Modify** `CONTRIBUTING.md` — add `plugins/` to Project layout.

Tasks 1–5 each add one plugin and its `plugins.bats` test (red→green within the task). Task 6 adds the index README and the cross-cutting wiring (CI + root docs).

Every `transcribe.sh` is `chmod +x` before commit (the executable bit is tracked by git and asserted by the structure test).

---

## Task 1: faster-whisper plugin

**Files:**
- Create: `test/bats/plugins.bats`
- Create: `plugins/faster-whisper/transcribe.sh`
- Create: `plugins/faster-whisper/README.md`

- [ ] **Step 1: Write the failing test** — create `test/bats/plugins.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

# A plugin must be a self-contained, runnable entrypoint plus a README.
assert_plugin() {
  local dir="$REPO_ROOT/plugins/$1"
  [ -f "$dir/transcribe.sh" ]
  [ -x "$dir/transcribe.sh" ]
  head -1 "$dir/transcribe.sh" | grep -q '^#!'
  bash -n "$dir/transcribe.sh"
  [ -f "$dir/README.md" ]
}

@test "plugin faster-whisper has a runnable transcribe.sh and a README" {
  assert_plugin faster-whisper
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats test/bats/plugins.bats`
Expected: FAIL (the `plugins/faster-whisper` directory does not exist yet).

- [ ] **Step 3: Create `plugins/faster-whisper/transcribe.sh`**

```bash
#!/usr/bin/env bash
# faster-whisper transcription plugin for wabox-bot.
#
# Contract: the audio file path is the last argument; the transcript is printed
# to stdout. faster-whisper decodes OGG/Opus directly, so no conversion is
# needed. Args are passed to the embedded Python via argv to avoid quoting
# pitfalls.
set -euo pipefail

audio="${1:?usage: transcribe.sh <audio-file>}"
model="${WABOX_FW_MODEL:-base}"
device="${WABOX_FW_DEVICE:-cpu}"
compute="${WABOX_FW_COMPUTE:-int8}"
lang="${WABOX_TRANSCRIBE_LANG:-}"

exec python3 - "$audio" "$model" "$device" "$compute" "$lang" <<'PY'
import sys
from faster_whisper import WhisperModel

audio, model, device, compute, lang = sys.argv[1:6]
m = WhisperModel(model, device=device, compute_type=compute)
segments, _ = m.transcribe(audio, language=(lang or None))
print("".join(seg.text for seg in segments).strip())
PY
```

Then: `chmod +x plugins/faster-whisper/transcribe.sh`

- [ ] **Step 4: Create `plugins/faster-whisper/README.md`**

```markdown
# faster-whisper plugin

[faster-whisper](https://github.com/SYSTRAN/faster-whisper) is a fast CTranslate2
reimplementation of Whisper. Good accuracy, runs well on CPU with `int8`, and
decodes OGG/Opus directly (no manual conversion).

## Install

    pipx install faster-whisper      # or: pip install --user faster-whisper

Arch: `python` ships in the base system; `pipx` is `sudo pacman -S python-pipx`.
The model downloads automatically on first run.

## Configure

| Env var | Default | Meaning |
| --- | --- | --- |
| `WABOX_FW_MODEL` | `base` | Model size (`tiny`/`base`/`small`/`medium`/`large-v3`) or a path. |
| `WABOX_FW_DEVICE` | `cpu` | `cpu` or `cuda`. |
| `WABOX_FW_COMPUTE` | `int8` | Compute type (`int8`, `int8_float16`, `float16`, …). |
| `WABOX_TRANSCRIBE_LANG` | (auto) | Force a language, e.g. `pt`. |

    export WABOX_TRANSCRIBE_CMD=/abs/path/to/wabox-bot/plugins/faster-whisper/transcribe.sh
    export WABOX_TRANSCRIBE_LANG=pt   # optional

## Smoke test

    ./transcribe.sh /path/to/voice-note.ogg
```

- [ ] **Step 5: Verify the test passes and lint**

Run: `bats test/bats/plugins.bats` → Expected: PASS (1 test).
Run: `shellcheck plugins/faster-whisper/transcribe.sh` → Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add test/bats/plugins.bats plugins/faster-whisper/
git commit -m "feat: faster-whisper transcription plugin"
```

---

## Task 2: whisper-cpp plugin

**Files:**
- Modify: `test/bats/plugins.bats` (append a test)
- Create: `plugins/whisper-cpp/transcribe.sh`
- Create: `plugins/whisper-cpp/README.md`

- [ ] **Step 1: Append the failing test** — add to `test/bats/plugins.bats`:

```bash
@test "plugin whisper-cpp has a runnable transcribe.sh and a README" {
  assert_plugin whisper-cpp
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats test/bats/plugins.bats`
Expected: the new `whisper-cpp` test FAILS (directory missing); the `faster-whisper` test still passes.

- [ ] **Step 3: Create `plugins/whisper-cpp/transcribe.sh`**

```bash
#!/usr/bin/env bash
# whisper.cpp transcription plugin for wabox-bot.
#
# Contract: audio path is the last argument; transcript printed to stdout.
# whisper-cli only reads 16 kHz mono WAV, so we convert with ffmpeg first.
set -euo pipefail

audio="${1:?usage: transcribe.sh <audio-file>}"
bin="${WABOX_WHISPERCPP_BIN:-whisper-cli}"
model="${WABOX_WHISPERCPP_MODEL:?set WABOX_WHISPERCPP_MODEL to the path of a ggml model}"
lang="${WABOX_TRANSCRIBE_LANG:-auto}"

if [[ ! -f "$model" ]]; then
  printf 'whisper-cpp: model not found: %s\n' "$model" >&2
  exit 1
fi

wav="$(mktemp --suffix=.wav)"
trap 'rm -f "$wav"' EXIT
ffmpeg -nostdin -loglevel error -y -i "$audio" -ar 16000 -ac 1 -c:a pcm_s16le "$wav"

# -np: no progress prints, -nt: no timestamps → clean transcript on stdout.
"$bin" -m "$model" -f "$wav" -l "$lang" -np -nt
```

Then: `chmod +x plugins/whisper-cpp/transcribe.sh`

- [ ] **Step 4: Create `plugins/whisper-cpp/README.md`**

```markdown
# whisper.cpp plugin

Wraps [`whisper.cpp`](https://github.com/ggerganov/whisper.cpp)'s `whisper-cli`.
The leanest fully-offline option; needs a ggml model and converts the audio to
16 kHz WAV with ffmpeg.

## Install

    # Arch (AUR)
    yay -S whisper.cpp          # provides `whisper-cli`; whisper.cpp-cuda for NVIDIA
    sudo pacman -S ffmpeg

Download a model, e.g.:

    mkdir -p ~/.local/share/whisper
    curl -L -o ~/.local/share/whisper/ggml-base.bin \
      https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin

## Configure

| Env var | Default | Meaning |
| --- | --- | --- |
| `WABOX_WHISPERCPP_MODEL` | (required) | Path to the ggml `.bin` model. |
| `WABOX_WHISPERCPP_BIN` | `whisper-cli` | Binary name or path. |
| `WABOX_TRANSCRIBE_LANG` | `auto` | Force a language, e.g. `pt`. |

    export WABOX_WHISPERCPP_MODEL=~/.local/share/whisper/ggml-base.bin
    export WABOX_TRANSCRIBE_CMD=/abs/path/to/wabox-bot/plugins/whisper-cpp/transcribe.sh

## Smoke test

    ./transcribe.sh /path/to/voice-note.ogg
```

- [ ] **Step 5: Verify the test passes and lint**

Run: `bats test/bats/plugins.bats` → Expected: PASS (2 tests).
Run: `shellcheck plugins/whisper-cpp/transcribe.sh` → Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add test/bats/plugins.bats plugins/whisper-cpp/
git commit -m "feat: whisper.cpp transcription plugin"
```

---

## Task 3: openai-whisper plugin

**Files:**
- Modify: `test/bats/plugins.bats` (append a test)
- Create: `plugins/openai-whisper/transcribe.sh`
- Create: `plugins/openai-whisper/README.md`

- [ ] **Step 1: Append the failing test** — add to `test/bats/plugins.bats`:

```bash
@test "plugin openai-whisper has a runnable transcribe.sh and a README" {
  assert_plugin openai-whisper
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats test/bats/plugins.bats`
Expected: the new `openai-whisper` test FAILS; the earlier tests still pass.

- [ ] **Step 3: Create `plugins/openai-whisper/transcribe.sh`**

```bash
#!/usr/bin/env bash
# OpenAI Whisper (reference CLI) transcription plugin for wabox-bot.
#
# Contract: audio path is the last argument; transcript printed to stdout. The
# whisper CLI writes output files and prints progress, so we send it to a temp
# dir, silence its stdout/stderr, and cat the resulting .txt.
set -euo pipefail

audio="${1:?usage: transcribe.sh <audio-file>}"
model="${WABOX_OPENAI_WHISPER_MODEL:-base}"
lang="${WABOX_TRANSCRIBE_LANG:-}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

args=(--model "$model" --output_format txt --output_dir "$tmp" --fp16 False)
[[ -n "$lang" ]] && args+=(--language "$lang")

whisper "$audio" "${args[@]}" >/dev/null 2>&1
cat "$tmp"/*.txt
```

Then: `chmod +x plugins/openai-whisper/transcribe.sh`

- [ ] **Step 4: Create `plugins/openai-whisper/README.md`**

```markdown
# OpenAI Whisper plugin

Wraps the reference [openai-whisper](https://github.com/openai/whisper) CLI.
Simplest to install, but heavy (pulls in PyTorch) and slower on CPU.

## Install

    pipx install openai-whisper       # or: pip install --user openai-whisper
    sudo pacman -S ffmpeg             # Arch; whisper requires ffmpeg

## Configure

| Env var | Default | Meaning |
| --- | --- | --- |
| `WABOX_OPENAI_WHISPER_MODEL` | `base` | Model (`tiny`/`base`/`small`/`medium`/`large`). |
| `WABOX_TRANSCRIBE_LANG` | (auto) | Force a language, e.g. `pt`. |

    export WABOX_TRANSCRIBE_CMD=/abs/path/to/wabox-bot/plugins/openai-whisper/transcribe.sh

## Smoke test

    ./transcribe.sh /path/to/voice-note.ogg
```

- [ ] **Step 5: Verify the test passes and lint**

Run: `bats test/bats/plugins.bats` → Expected: PASS (3 tests).
Run: `shellcheck plugins/openai-whisper/transcribe.sh` → Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add test/bats/plugins.bats plugins/openai-whisper/
git commit -m "feat: openai-whisper transcription plugin"
```

---

## Task 4: vosk plugin

**Files:**
- Modify: `test/bats/plugins.bats` (append a test)
- Create: `plugins/vosk/transcribe.sh`
- Create: `plugins/vosk/README.md`

- [ ] **Step 1: Append the failing test** — add to `test/bats/plugins.bats`:

```bash
@test "plugin vosk has a runnable transcribe.sh and a README" {
  assert_plugin vosk
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats test/bats/plugins.bats`
Expected: the new `vosk` test FAILS; the earlier tests still pass.

- [ ] **Step 3: Create `plugins/vosk/transcribe.sh`**

```bash
#!/usr/bin/env bash
# Vosk transcription plugin for wabox-bot.
#
# Contract: audio path is the last argument; transcript printed to stdout. Vosk
# reads 16 kHz mono WAV, so we convert with ffmpeg first. The model is
# language-specific, so WABOX_TRANSCRIBE_LANG does not apply here.
set -euo pipefail

audio="${1:?usage: transcribe.sh <audio-file>}"
model="${WABOX_VOSK_MODEL:?set WABOX_VOSK_MODEL to a Vosk model directory}"

if [[ ! -d "$model" ]]; then
  printf 'vosk: model directory not found: %s\n' "$model" >&2
  exit 1
fi

wav="$(mktemp --suffix=.wav)"
trap 'rm -f "$wav"' EXIT
ffmpeg -nostdin -loglevel error -y -i "$audio" -ar 16000 -ac 1 -c:a pcm_s16le "$wav"

exec python3 - "$wav" "$model" <<'PY'
import sys, json, wave
from vosk import Model, KaldiRecognizer

wav_path, model_path = sys.argv[1:3]
wf = wave.open(wav_path, "rb")
rec = KaldiRecognizer(Model(model_path), wf.getframerate())
parts = []
while True:
    data = wf.readframes(4000)
    if not data:
        break
    if rec.AcceptWaveform(data):
        parts.append(json.loads(rec.Result()).get("text", ""))
parts.append(json.loads(rec.FinalResult()).get("text", ""))
print(" ".join(p for p in parts if p).strip())
PY
```

Then: `chmod +x plugins/vosk/transcribe.sh`

- [ ] **Step 4: Create `plugins/vosk/README.md`**

```markdown
# Vosk plugin

[Vosk](https://alphacephei.com/vosk/) is a lightweight offline engine — small
models, low CPU use, decent accuracy. The model is **language-specific**, so
`WABOX_TRANSCRIBE_LANG` does not apply; install the model for your language.

## Install

    pipx install vosk         # or: pip install --user vosk
    sudo pacman -S ffmpeg     # Arch

Download and unzip a model, e.g. Portuguese:

    curl -LO https://alphacephei.com/vosk/models/vosk-model-small-pt-0.3.zip
    unzip vosk-model-small-pt-0.3.zip -d ~/.local/share/vosk

## Configure

| Env var | Default | Meaning |
| --- | --- | --- |
| `WABOX_VOSK_MODEL` | (required) | Path to the unzipped model directory. |

    export WABOX_VOSK_MODEL=~/.local/share/vosk/vosk-model-small-pt-0.3
    export WABOX_TRANSCRIBE_CMD=/abs/path/to/wabox-bot/plugins/vosk/transcribe.sh

## Smoke test

    ./transcribe.sh /path/to/voice-note.ogg
```

- [ ] **Step 5: Verify the test passes and lint**

Run: `bats test/bats/plugins.bats` → Expected: PASS (4 tests).
Run: `shellcheck plugins/vosk/transcribe.sh` → Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add test/bats/plugins.bats plugins/vosk/
git commit -m "feat: vosk transcription plugin"
```

---

## Task 5: openai-compatible plugin

**Files:**
- Modify: `test/bats/plugins.bats` (append a test)
- Create: `plugins/openai-compatible/transcribe.sh`
- Create: `plugins/openai-compatible/README.md`

- [ ] **Step 1: Append the failing test** — add to `test/bats/plugins.bats`:

```bash
@test "plugin openai-compatible has a runnable transcribe.sh and a README" {
  assert_plugin openai-compatible
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats test/bats/plugins.bats`
Expected: the new `openai-compatible` test FAILS; the earlier tests still pass.

- [ ] **Step 3: Create `plugins/openai-compatible/transcribe.sh`**

```bash
#!/usr/bin/env bash
# OpenAI-compatible /audio/transcriptions plugin for wabox-bot.
#
# Contract: audio path is the last argument; transcript printed to stdout.
# Works with any OpenAI-compatible endpoint (OpenAI, Groq, …). response_format
# = text makes the API return a plain transcript. The audio leaves the machine.
set -euo pipefail

audio="${1:?usage: transcribe.sh <audio-file>}"
url="${WABOX_STT_API_URL:-https://api.openai.com/v1/audio/transcriptions}"
key="${WABOX_STT_API_KEY:?set WABOX_STT_API_KEY to your API key}"
model="${WABOX_STT_API_MODEL:-whisper-1}"
lang="${WABOX_TRANSCRIBE_LANG:-}"

args=(-fsS "$url"
  -H "Authorization: Bearer $key"
  -F "model=$model"
  -F "response_format=text"
  -F "file=@$audio")
[[ -n "$lang" ]] && args+=(-F "language=$lang")

curl "${args[@]}"
```

Then: `chmod +x plugins/openai-compatible/transcribe.sh`

- [ ] **Step 4: Create `plugins/openai-compatible/README.md`**

```markdown
# OpenAI-compatible API plugin

Sends the audio to any OpenAI-compatible `/audio/transcriptions` endpoint via
`curl`. No local model or GPU — but the audio leaves your machine and you need
an API key. Works with OpenAI and Groq (and other compatible providers).

## Install

    sudo pacman -S curl    # Arch (usually already present)

## Configure

| Env var | Default | Meaning |
| --- | --- | --- |
| `WABOX_STT_API_KEY` | (required) | Your API key. |
| `WABOX_STT_API_URL` | `https://api.openai.com/v1/audio/transcriptions` | Endpoint. |
| `WABOX_STT_API_MODEL` | `whisper-1` | Model name. |
| `WABOX_TRANSCRIBE_LANG` | (auto) | Force a language, e.g. `pt`. |

OpenAI:

    export WABOX_STT_API_KEY=sk-...
    export WABOX_TRANSCRIBE_CMD=/abs/path/to/wabox-bot/plugins/openai-compatible/transcribe.sh

Groq:

    export WABOX_STT_API_URL=https://api.groq.com/openai/v1/audio/transcriptions
    export WABOX_STT_API_KEY=gsk-...
    export WABOX_STT_API_MODEL=whisper-large-v3
    export WABOX_TRANSCRIBE_CMD=/abs/path/to/wabox-bot/plugins/openai-compatible/transcribe.sh

## Smoke test

    ./transcribe.sh /path/to/voice-note.ogg
```

- [ ] **Step 5: Verify the test passes and lint**

Run: `bats test/bats/plugins.bats` → Expected: PASS (5 tests).
Run: `shellcheck plugins/openai-compatible/transcribe.sh` → Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add test/bats/plugins.bats plugins/openai-compatible/
git commit -m "feat: openai-compatible API transcription plugin"
```

---

## Task 6: Index README + CI + docs wiring

**Files:**
- Create: `plugins/README.md`
- Modify: `.github/workflows/ci.yml`
- Modify: `README.md`
- Modify: `CONTRIBUTING.md`

- [ ] **Step 1: Create `plugins/README.md`**

```markdown
# Transcription plugins

Ready-made transcribers for wabox-bot's `WABOX_TRANSCRIBE_CMD` (inbound audio /
voice notes). Each subfolder is a self-contained plugin: a `transcribe.sh`
entrypoint plus a README with install and configuration steps.

## The contract

wabox-bot word-splits `WABOX_TRANSCRIBE_CMD`, appends the audio file path as the
**last argument**, and reads the transcript from **stdout**. Empty/whitespace
output or a non-zero exit is treated as a failure. Point the env var at a
plugin's script (use an absolute path):

    export WABOX_TRANSCRIBE_CMD=/abs/path/to/wabox-bot/plugins/<name>/transcribe.sh

Inbound WhatsApp audio is Opus-in-OGG; each plugin handles the format (converting
with ffmpeg where the engine needs WAV).

## Language

Every plugin honors `WABOX_TRANSCRIBE_LANG` (e.g. `pt`, `en`); leave it empty for
auto-detection. Exception: **vosk**'s language is fixed by the installed model,
so it ignores this variable.

## Plugins

| Plugin | Runs | Needs |
| --- | --- | --- |
| [`faster-whisper`](faster-whisper/) | locally (CPU/GPU, fast) | Python + `faster-whisper` |
| [`whisper-cpp`](whisper-cpp/) | locally (compiled, lean) | `whisper-cli` + `ffmpeg` + a ggml model |
| [`openai-whisper`](openai-whisper/) | locally (reference) | Python + `openai-whisper` + `ffmpeg` |
| [`vosk`](vosk/) | locally (lightweight) | Python + `vosk` + `ffmpeg` + a model |
| [`openai-compatible`](openai-compatible/) | remote API | `curl` + an API key (OpenAI, Groq, …) |
```

- [ ] **Step 2: Add the plugins shellcheck line to CI**

In `.github/workflows/ci.yml`, the shellcheck step ends with:

```yaml
          shellcheck install.sh
          shellcheck examples/aider.sh
```

Add one line after it:

```yaml
          shellcheck install.sh
          shellcheck examples/aider.sh
          shellcheck plugins/*/transcribe.sh
```

- [ ] **Step 3: Add a pointer in `README.md`**

In `README.md`, immediately after the line:

```markdown
Backend-specific env vars (for example `CLAUDE_BIN`, `CLAUDE_ARGS`,
```

…there is a paragraph about backend env vars. Find the blank line right BEFORE that "Backend-specific env vars" paragraph and insert this paragraph there (so it sits between the config table and the backend-env paragraph):

```markdown
Ready-made transcribers for `WABOX_TRANSCRIBE_CMD` (faster-whisper, whisper.cpp,
OpenAI Whisper, Vosk, and any OpenAI-compatible API such as Groq) live in
[`plugins/`](plugins/) — each with its own install and configuration README.

```

- [ ] **Step 4: Add `plugins/` to the CONTRIBUTING Project layout**

In `CONTRIBUTING.md`, the Project layout code block contains:

```
examples/               # systemd unit, stubs for additional backends
test/bats/              # bats tests; run with `bats test/bats/`
```

Insert a `plugins/` line between them:

```
examples/               # systemd unit, stubs for additional backends
plugins/                # ready-made WABOX_TRANSCRIBE_CMD transcribers, one folder each
test/bats/              # bats tests; run with `bats test/bats/`
```

- [ ] **Step 5: Verify the full suite + full CI lint set**

Run: `bats test/bats/`
Expected: all PASS (includes the 5 plugin structure tests).

Run: `shellcheck -x bin/wabox-bot && shellcheck lib/backends/*.sh && shellcheck install.sh && shellcheck examples/aider.sh && shellcheck plugins/*/transcribe.sh`
Expected: no output (exit 0).

- [ ] **Step 6: Commit**

```bash
git add plugins/README.md .github/workflows/ci.yml README.md CONTRIBUTING.md
git commit -m "docs: index transcription plugins; lint them in CI"
```

---

## Final Verification

- [ ] Full suite: `bats test/bats/` — expected: all PASS.
- [ ] CI lint set: `shellcheck -x bin/wabox-bot && shellcheck lib/backends/*.sh && shellcheck install.sh && shellcheck examples/aider.sh && shellcheck plugins/*/transcribe.sh` — expected: no output.
- [ ] Each plugin dir has an executable `transcribe.sh` (with shebang) and a `README.md`: `ls -l plugins/*/transcribe.sh`.
