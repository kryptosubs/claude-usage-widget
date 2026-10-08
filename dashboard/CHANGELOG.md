# Changelog

## v1.0.0 — 2026-10-08

First release. A local dashboard on the Mac Studio for personal AI usage:

- **Next wall:** whether the Claude weekly cap lasts until the reset, from the
  burn rate over the last 24 hours, with the time it runs out when it won't.
- Every Claude limit (5-hour, weekly, per model, extra usage) with countdowns,
  read from the Claude Usage menu-bar app's snapshot (v1.3+). The dashboard
  never reads or refreshes the Claude login itself.
- The week charted against an even pace, with the projection drawn to the cap.
- Claude Code tokens by project and by day, from Claude Code's transcripts,
  de-duplicated by message.
- Ollama: installed and loaded models, memory held against the Mac's total,
  requests per day from the server log, primary and backup marked.
- Plans and monthly cost, with Gemini, Grok and Muse marked as having no meter.
- English and Traditional Chinese, light and dark, phone width.
- LaunchAgent install; LAN/Tailscale access gated by a key; strict CSP.
