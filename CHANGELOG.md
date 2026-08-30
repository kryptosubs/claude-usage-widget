# Changelog

Versioning: MAJOR (rewrite) · MINOR (new capability) · PATCH (fixes).

The version here is what the card on **kryptohead.com** shows. Nothing links the
two automatically, so bump this file and the card's `sub` in
`kryptosubs/kryptohead-home/lib/cards.ts` — and its zh-Hant twin in
`components/i18n.tsx` — in the same breath, or they drift.

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
