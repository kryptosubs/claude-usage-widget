# Claude Usage Widget (Windows)

A small always-on-top desktop widget showing live Claude usage: the 5-hour session
window, the weekly cap, per-model weekly caps, and extra-usage credits — each with a
progress bar and a countdown to reset.

No Node, no Electron, no build step. It's one PowerShell script that uses Windows'
built-in WPF. It reads the OAuth token Claude Code already stored on this PC, or — if
there is none — signs itself in with Google through claude.ai from a button on the card.

The macOS version lives in [`mac/`](mac/README.md).

## Setup (2 steps)

1. Put this folder anywhere you like (e.g. `C:\Tools\claude-usage-widget`).
2. Double-click **`Start-Widget.vbs`**.

That's it. If you also want it to start with Windows, double-click
`Install-Startup.cmd` once (run it again to remove it), or use the tray icon's
**Run at Windows startup** item.

If Windows blocks the `.vbs`, right-click `ClaudeUsageWidget.ps1` →
**Run with PowerShell** instead.

## Sign in with Google (no Claude Code needed)

When the card shows **no login** or **auth**, a **Sign in with Google...** button
appears under it. Click it and claude.ai opens in your default browser: choose
**Continue with Google** (or whatever your account uses), or just **Authorize** if
the browser is already signed in to claude.ai. The tab then says *Signed in to
Claude Usage* and the card fills in within a second.

It is the same PKCE flow Claude Code's `/login` uses, returning to a one-shot
listener on `127.0.0.1` / `::1` (loopback only: no admin rights, no firewall prompt).
The tokens are saved to `widget-login.dat` beside the script, encrypted with Windows
DPAPI so only your Windows account on this PC can read them, and locked to your
account with an owner-only ACL.

That login is the widget's **own**, on a separate refresh chain from Claude Code's.
It is tried first, the widget keeps it renewed by itself, and it never rotates
Claude Code's token out from under it. Right-click the card (or the tray icon) for
**Sign in again...** and **Sign out**. Signing out only removes the widget's login;
Claude Code's logins below are untouched and are used again if present.

## Where the token comes from

In order:

1. `CLAUDE_CODE_OAUTH_TOKEN` (if you set it — wins outright)
2. The widget's own sign-in, `widget-login.dat` (above)
3. Every Claude Code login on the machine, freshest first:
   - `%USERPROFILE%\.claude\.credentials.json` — Claude Code installed on Windows
   - every WSL distro, read via `wsl.exe -d <distro> -e bash -lc 'cat ~/.claude/.credentials.json'`

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

Double-click **`Diagnose.cmd`**. It prints, in order: the widget's own sign-in (if
any), every Claude Code login it found (Windows *and* every WSL distro), each one's expiry and
whether it has a refresh token, which refresh endpoints are alive, which login actually
served the request, the account email, and the raw usage response.

| Widget shows | Meaning |
| --- | --- |
| `no login` | No login anywhere — click **Sign in with Google...** on the card |
| `auth` | Every login is dead — click **Sign in with Google...** (or `/login` in Claude Code) |
| `throttled` | Rate limited (429) — backing off, last good numbers still shown |
| `offline` | Network or endpoint error — run `Diagnose.cmd` |

## Controls

The layout is deliberately compact: each limit is one 18px line where the progress
bar is painted *behind* the text rather than sitting on its own line, so a metric
costs one line instead of three. Labels are abbreviated (`5h`, `7d`, `Opus`) and the
account email doubles as the title. Hovering a row shows the full label and reset
time. The card is 224x96 for three limits, down from 292x211 - about a third of the
former area, with the same information on screen.

| Action | Result |
| --- | --- |
| Hover a row | Full label and reset time |
| **X button** (top right) | Close the widget and quit |
| **Esc** | Same |
| Right-click the widget | Refresh, hide to tray, sign in / sign in again / sign out, close |
| Drag | Move the widget (position is remembered) |
| Double-click | Refresh now |
| Tray icon (right-click) | Show/hide, refresh, startup toggle, transparency, sign in / out, exit |
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
- Extra-usage money comes back in **minor units** (cents) with an explicit
  `exponent` / `decimal_places`, so it is scaled down before display — reading it
  raw shows every amount 100x too large. Both shapes are handled: the newer
  `spend` object (`amount_minor` + `exponent`) and the older `extra_usage`
  (`used_credits` / `monthly_limit` + `decimal_places`). Non-USD currencies and
  zero-decimal currencies like JPY format correctly.
- Each row shows the countdown plus the wall-clock time it lands on, in your own
  time zone and locale. The widget uses the compact form (`4h25m  4:20 PM`);
  `Diagnose.cmd` prints the long form (`resets in 4h 25m (4:20 PM)`).
- Settings, window position and the renewed credential live in `widget-state.json`
  beside the script (owner-only ACL; never commit it). The Google sign-in lives in
  `widget-login.dat` (DPAPI-encrypted, owner-only; also gitignored).
- Tests: `pwsh -NoProfile -File tests/Run-Tests.ps1` (runs on Windows or Linux; the
  loopback listener is exercised for real, the network is stubbed).
- `/api/oauth/usage` is undocumented and used internally by Claude Code's own usage
  HUD. If Anthropic changes the `anthropic-beta: oauth-2025-04-20` header value, the
  widget will show `auth` and you'll need to bump that string in the script.
- If percentages ever look off by 100x, set `"ScaleOverride"` in `widget-state.json`
  to `"percent"` or `"fraction"` (default `"auto"`).
