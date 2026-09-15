# Changelog

Versioning: MAJOR (rewrite) · MINOR (new capability) · PATCH (fixes).

The version here is what the card on **kryptohead.com** shows. Nothing links the
two automatically, so bump this file and the card's `sub` in
`kryptosubs/kryptohead-home/lib/cards.ts` in the same breath, or they drift.
Both languages of that card live in `cards.ts`; the `components/i18n.tsx` half
this note used to point at was removed, because keeping two files in step by
hand is what produced a version bumped on one side only.

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
