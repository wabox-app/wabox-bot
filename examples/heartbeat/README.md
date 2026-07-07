# Heartbeat: proactive messages on a schedule

wabox-bot is reactive — it only speaks when a message comes in. A *heartbeat*
adds the missing half: a scheduler (cron or a systemd timer) runs
`wabox-bot prompt <slug> "<standing instruction>"` on an interval, the agent
checks whatever you told it to, and it messages you **only when it has something
to say**. When it doesn't, it replies with the `NOOP` sentinel and nothing is
sent.

There is no scheduler inside wabox-bot by design — cron and systemd already own
time, and keeping wabox-bot with no control plane keeps its security story
simple. These are examples you copy and edit, not a bot feature you enable.

Files here:

- `standing-prompt.txt` — the instruction sent to the agent every tick. Its
  whole content is passed verbatim as the prompt, so edit it to taste.
- `crontab.example` — a one-line cron job.
- `wabox-heartbeat.service` + `wabox-heartbeat.timer` — the systemd user-timer
  equivalent.

## 1. Find the conversation slug

The heartbeat posts into one existing conversation. Slugs are one-way hashes of
the chat identity, so list them and pick the one you want:

```sh
wabox-bot state --json \
  | jq -r '.conversations[] | "\(.slug)\t\(.conv_key)\t\(.last_message.text_preview // "")"'
```

Each row is `slug <tab> JID <tab> last message preview` — copy the slug of the
chat you want the heartbeat to speak into. (The conversation must have exchanged
at least one message so wabox-bot knows the JID to reply on.)

## 2. Write the standing prompt

Copy `standing-prompt.txt` somewhere stable (e.g.
`~/.config/wabox-bot/standing-prompt.txt`) and edit it for what you actually
want checked. The two rules that make suppression work:

- reply with **exactly `NOOP`** when there's nothing worth sending;
- keep real replies short — this runs often.

`NOOP` is the default sentinel; set `WABOX_PROMPT_NOOP` to change the token if it
collides with your prompt language.

## 3a. Install with cron

Edit the slug and paths in `crontab.example`, then `crontab -e` and paste the
line. The trailing `|| [ $? -eq 5 ]` turns the NOOP exit code (5) back into
success so a quiet heartbeat isn't logged as a cron failure.

## 3b. Install with a systemd user timer

Edit the slug and paths in `wabox-heartbeat.service`, then:

```sh
mkdir -p ~/.config/systemd/user
cp wabox-heartbeat.service wabox-heartbeat.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now wabox-heartbeat.timer
systemctl --user list-timers wabox-heartbeat.timer   # confirm the next run
```

`SuccessExitStatus=5` in the service does the same job as cron's `|| [ $? -eq 5 ]`:
a suppressed heartbeat counts as success, a real error (usage `1`, lock busy
`3`, timeout `124`) still marks the unit failed.

## Notes and caveats

- **A heartbeat is a real turn in the session.** The agent sees each heartbeat
  as prior conversation history, so a later "what did you remind me about?"
  works — but heartbeats also grow the session and count toward its context.
  `/clear` resets it as usual. Keep standing prompts small.
- **A long heartbeat delays inbound replies for that same conversation.** The
  heartbeat and the daemon share the per-conversation lock, so while a heartbeat
  turn runs, a message you send in that chat waits for it to finish (the same
  wait as any busy turn). If a heartbeat is already running when the next tick
  fires, the new one exits `3` (lock busy) rather than piling up.
- **Permission-gated tools park a question.** If a heartbeat turn tries a tool
  that isn't pre-allowed, the agent's yes/no question is what gets delivered —
  answer it in the chat or with `wabox-bot answer <slug> <yes|no>`. Prefer
  standing prompts that avoid gated tools, or switch the conversation to a
  pre-allowed toolset with `/mode`.
