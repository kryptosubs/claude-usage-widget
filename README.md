# Claude Usage Widget (Windows)

A small always-on-top desktop widget showing live Claude usage: the 5-hour session
window, the weekly cap, per-model weekly caps, and extra-usage credits — each with a
progress bar and a countdown to reset.

No Node, no Electron, no build step, no second login. It's one PowerShell script that
uses Windows' built-in WPF and reads the OAuth token Claude Code already stored on
this PC.

## Setup (2 steps)

1. Put this folder anywhere you like (e.g. `C:\Tools\claude-usage-widget`).
2. Double-click **`Start-Widget.vbs`**.

That's it. If you also want it to start with Windows, double-click
`Install-Startup.cmd` once (run it again to remove it), or use the tray icon's
**Run at Windows startup** item.

If Windows blocks the `.vbs`, right-click `ClaudeUsageWidget.ps1` →
**Run with PowerShell** instead.

## Where the token comes from

The widget finds **every** Claude Code login on the machine and uses the freshest one:

1. `CLAUDE_CODE_OAUTH_TOKEN` (if you set it — wins outright)
2. `%USERPROFILE%\.claude\.credentials.json` — Claude Code installed on Windows
3. Every WSL distro, read via `wsl.exe -d <distro> -e bash -lc 'cat ~/.claude/.credentials.json'`

This matters: a native-Windows install you abandoned months ago and a live WSL install
commonly coexist, and taking whichever turns up first means authenticating with a dead
token. Logins are ranked by token expiry, so the one you actually use wins.

Expired tokens are refreshed against `https://api.anthropic.com/v1/oauth/token`. (The
old `console.anthropic.com` host is retired and returns 404.) A failed refresh is not
fatal — the widget falls back to the freshest stored token. It never writes to Claude
Code's own credentials files.

## Fastest way to get it working (WSL)

From inside WSL, after unzipping this folder on Windows:

```
bash /mnt/c/Users/<you>/Downloads/claude-usage-widget/setup-wsl-auth.sh
```

It checks your existing login, signs you in if it has expired, then prints the
account email and your live usage so you can see it working.

The bare minimum, if you'd rather not run the script: start `claude` in WSL, use
`/login`, and start the widget. Nothing else is needed — the widget reads that login.

## Which account is measured

Chat, Cowork, and Claude Code all draw from **one shared usage pool per account** — a
heavy coding session eats into what's left for chat, and vice versa. So the widget
shows the usage for whichever account its token belongs to, covering every surface that
account uses.

The widget displays that account's email under the title, so you can confirm it is
reading the account you care about rather than some other login left on the machine.

To point it at a specific account, sign in as that account in Claude Code
(`/login`), then restart the widget. Its credentials file is what the widget reads.

### Keeping it signed in (long-lasting credential)

There is no long-lived token you can paste in. `claude setup-token` produces a
one-year token, but **the usage endpoint rejects `sk-ant-oat01-...` tokens with HTTP
403** — they are scoped to model requests only. Verified against a real token, not
assumed. A Console API key doesn't work either: it bills separately and wouldn't
report your subscription's usage.

What actually lasts is the `/login` credential, kept alive automatically:

1. Sign in once: run `claude` (in WSL if that's where you use it) and `/login`.
2. Start the widget and leave it running — add it to startup with
   `Install-Startup.cmd` or the tray menu's **Run at Windows startup**.

From then on the widget renews itself. When its access token expires it refreshes,
stores the result in `widget-state.json`, and **keeps the rotated refresh token the
server returns**. That last part matters: OAuth refresh tokens rotate — the one you
just spent is invalidated — so a client that replays the original copy works exactly
once and then fails forever. The widget advances the chain instead, which is what
lets it stay signed in indefinitely without you touching it, and without ever writing
to Claude Code's own credentials file.

The chain only advances while the widget runs. If it's left off long enough for the
stored refresh token to expire, it falls back to the credentials file; if that is
stale too, it shows `auth` and you run `/login` once more. `Diagnose.cmd` prints
`self-renewing` once the widget holds its own token.

Because that file now holds a refresh token, the widget sets an owner-only ACL on
`widget-state.json` — it does not rely on wherever you happened to unzip the folder.
Treat it like a password: don't commit it or copy it to another machine. `.gitignore`
already excludes it.

## When something goes wrong

Double-click **`Diagnose.cmd`**. It prints, in order: every Claude Code login it
found (Windows *and* every WSL distro), each one's expiry and
whether it has a refresh token, which refresh endpoints are alive, which login actually
served the request, the account email, and the raw usage response.

| Widget shows | Meaning |
| --- | --- |
| `no token` | No Claude Code login found anywhere — run `claude` once |
| `auth` | Every login on the machine is dead — run `claude` once, in whichever environment you actually use it (WSL counts) |
| `throttled` | Rate limited (429) — backing off, last good numbers still shown |
| `offline` | Network or endpoint error — run `Diagnose.cmd` |

## Controls

| Action | Result |
| --- | --- |
| **X button** (top right) | Close the widget and quit |
| **Esc** | Same |
| Right-click the widget | Refresh, hide to tray, close |
| Drag | Move the widget (position is remembered) |
| Double-click | Refresh now |
| Tray icon (right-click) | Show/hide, refresh, startup toggle, transparency, exit |
| Tray icon (hover) | 5h and 7d percentages at a glance |

The widget is a borderless window, so it has no title bar of its own — the X in its
top-right corner is the close button. Windows 11 hides new tray icons in the "^"
overflow by default, so don't rely on finding the tray icon to quit; the X and
right-click menu are always there. Closing shuts the process down completely.

## Notes

- Polls every 180 s by default. The usage endpoint rate-limits hard, so don't go
  lower — on a 429 the widget backs off automatically (up to ~16 min) and keeps
  showing the last good numbers with a `throttled` marker.
- Change the interval with `-RefreshSeconds`, e.g.
  `powershell -STA -File ClaudeUsageWidget.ps1 -RefreshSeconds 300`.
- Rows come from the response's `limits` array when present: an explicit 0-100
  `percent`, the server's own `severity`, and a `scope` that names per-model or
  per-surface caps, so new limit kinds appear without a code change. The older
  named fields (`five_hour`, `seven_day`, ...) are the fallback. Internal codename
  buckets in the response are ignored - they aren't in `limits`.
- Bars turn amber at 75% and red at 90%, or earlier if the server marks the limit
  warning/critical. Whichever is more severe wins.
- A scoped weekly cap with no usage and no reset window is hidden until it applies.
- Each row shows the countdown plus the wall-clock time it lands on, in your own
  time zone and locale: "resets in 4h 25m (4:20 PM)" today, "(Tue 3:00 PM)" within
  the week, "(Sep 9 11:55 AM)" beyond it.
- Settings, window position and the renewed credential live in `widget-state.json`
  beside the script (owner-only ACL; never commit it).
- `/api/oauth/usage` is undocumented and used internally by Claude Code's own usage
  HUD. If Anthropic changes the `anthropic-beta: oauth-2025-04-20` header value, the
  widget will show `auth` and you'll need to bump that string in the script.
- If percentages ever look off by 100x, set `"ScaleOverride"` in `widget-state.json`
  to `"percent"` or `"fraction"` (default `"auto"`).
