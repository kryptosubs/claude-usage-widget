# Changelog

Versioning: MAJOR (rewrite) · MINOR (new capability) · PATCH (fixes).

The version here is what the card on **kryptohead.com** shows. Nothing links the
two automatically, so bump this file and the card's `sub` in
`kryptosubs/kryptohead-home/lib/cards.ts` in the same breath, or they drift.
Both languages of that card live in `cards.ts`; the `components/i18n.tsx` half
this note used to point at was removed, because keeping two files in step by
hand is what produced a version bumped on one side only.

## v1.2.1 — 2026-09-22

**Fixed (Mac): launching the app could look like nothing happened.** It is a
menu-bar-only app with no Dock icon and no window, so a launch while it was
already running did nothing visible, and a ring hidden by a crowded menu bar
looked the same as no app at all. Now a second launch hands over to the running
instance, which opens its popover, or opens the floating card when the menu-bar
item is not on screen. The first launch always shows the card, and there is only
ever one instance. Startup events are logged to `~/Library/Logs/ClaudeUsage.log`.

## v1.2 — 2026-09-22

**macOS version** (`mac/`). A native Swift menu-bar app built with nothing
but the Xcode Command Line Tools (`./build.sh --install`). It adds a ring and a
percentage to the menu bar, a popover with every limit, and an optional floating
card that reproduces the Windows compact rows at the same 224pt width. It reads
Claude Code's login from the macOS Keychain (`Claude Code-credentials`, through
`/usr/bin/security`, so there is no access prompt) or from
`~/.claude/.credentials.json`, ranked by expiry as on Windows. English and
Traditional Chinese, switchable from the gear menu. Launch at login uses
`SMAppService`.

**On the Mac, refreshed tokens are written back.** Refresh tokens rotate, so a
widget that keeps its own copy (the Windows approach) logs Claude Code out the
first time it refreshes. The Mac app writes the new pair back into the source
it read, changing only the token fields, so both clients stay on one chain. A
refresh happens only after the access token has expired, and never twice in
parallel: token resolution is single-flight, because a second concurrent refresh
would spend the same rotating token. If the write-back fails, the new refresh
token goes into the app's own Keychain item and is tried first next time.

52 checks run under `./build.sh --test`. They include a stub token server that
rotates tokens like the real one: three consecutive refreshes succeed, the
chain is written back, the fallback copy is used when a write-back fails, and
parallel callers share one refresh. The network is stubbed at the transport
layer, never at our own functions. The build was verified on macOS 27 (Apple
silicon) against the live endpoint.

The Windows widget is unchanged in this release.

## v1.1 — 2026-09-15

**Compact layout.** Each limit used three stacked lines — label and percent,
bar, reset — costing 47px. The bar is now painted behind the row's text instead
of occupying a line and a column of its own, so a metric is one 18px line. That
is the only change that saves height and width at once. Labels are abbreviated
(`5h`, `7d`, `Opus`), the account email doubles as the title, and the countdown
drops its prose (`4h25m  4:20 PM`). Hovering a row still gives the full label
and reset time, and `Diagnose.cmd` keeps the long form. The card is 224x96 for
three limits, down from 292x211 — about a third of the area, same information.

Widths were measured rather than guessed: at 216px the Opus and Sonnet rows
overflowed into an ellipsis, which drops information on a Max plan. The suite
now carries a row-fit guard so that cannot creep back in.

**Fixed: a usage 401 was read as a generic failure.** `Get-Usage` wraps its
error to name which call failed, which moves the original exception — the only
one carrying `.Response` — one level down. Callers read the wrapper and got a
status of 0, so the 401 branch was dead code: `Diagnose.cmd` printed the
failure without its "run /login" guidance, and the widget showed `offline`
rather than `auth` while skipping the cache reset that lets it notice a fresh
login without being restarted.

**Fixed:** the default window position still offset for the old 292px card, so
a first run sat too far from the screen edge.

## v1.0 — 2026-08-28

**Version assigned retroactively on 2026-08-30.** This widget shipped without a
version number; 1.0 is the state it was already in, dated to the day the repo
was created, so that the next release has something to count from.

What it is at 1.0:

- Always-on-top Windows desktop widget showing live Claude usage: the 5-hour
  session window, weekly caps, per-model caps and extra credits, each with a
  bar and a countdown to reset.
- One PowerShell script on Windows' built-in WPF — no Node, no Electron, no
  build step, no second sign-in.
- Reads the OAuth token Claude Code already stored, across a native Windows
  install and every WSL distro, ranking logins by expiry so a dead token from
  an abandoned install does not win.
- Renews its own credential and keeps the rotated refresh token, which is what
  lets it stay signed in indefinitely without touching Claude Code's own
  credentials file.
- Owner-only ACL on `widget-state.json`, because that file holds a refresh
  token.
