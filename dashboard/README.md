# ai-usage

A personal AI usage and quota dashboard that runs on the Mac Studio and opens
from the iPad. 個人 AI 用量與額度儀表板，跑在 Mac Studio 上，iPad 也能開。

It answers one question first: **will the Claude weekly cap last until it
resets?** Then it shows every Claude limit, a chart of the week against an even
pace, Claude Code tokens by project, what Ollama is doing, and the monthly cost
of each plan. English and Traditional Chinese.

Standard library Python only. No database, no cloud service, and it never touches
the Claude login.

## Install

It lives in the `dashboard/` folder of `kryptosubs/claude-usage-widget`, next
to the menu-bar app whose snapshot it reads:

```
cd ~/code/claude-usage-widget && git pull
cd dashboard && bash install.sh
```

The installer runs the tests, writes a LaunchAgent (`com.kryptohead.ai-usage`)
so the server starts at login, and prints the links:

```
On this Mac:    http://127.0.0.1:8787/
iPad / LAN:     http://192.168.86.26:8787/?k=<key>
```

Open the iPad link once. The key is then kept in a cookie and dropped from the
address bar. Over Tailscale the same LAN address works through the Apple TV
subnet router. Requests from the Mac itself need no key.

Update: `git pull`, then `bash install.sh` again. Remove: `bash uninstall.sh`.

## Where the numbers come from

| What | Source | Fresh |
| --- | --- | --- |
| Claude limits (5-hour, weekly, per model, extra usage) | `~/Library/Application Support/ClaudeUsage/latest.json`, written by the Claude Usage menu-bar app v1.3+ | every 3 min |
| Burn rate and projection | `history.jsonl` next to it (one reading per fetch, 35 days) | every 3 min |
| Claude Code tokens by project and day | `~/.claude/projects/**/*.jsonl`, Claude Code's own transcripts | every minute |
| Ollama models, memory, requests per day | `http://127.0.0.1:11434/api/{ps,tags,version}` and `~/.ollama/logs/server*.log` | every minute |
| Plans and prices | `~/Library/Application Support/ai-usage/config.json` | when you edit it |

Gemini, Grok and Muse have no usage API, so they appear only as plans with a
price. Chat, Cowork and the browser agents draw on the same Claude limit as
Claude Code, but only Claude Code keeps transcripts on this Mac, so the
by-project view covers Claude Code alone. The limit bars cover everything.

**Why the menu-bar app and not a direct call:** the Claude usage endpoint needs
Claude Code's OAuth login, and its refresh tokens rotate. Two programs refreshing
on their own spend the same token and log each other out. The menu-bar app
already handles that (single-flight refresh, written back to the Keychain), so
it stays the only reader of the login and hands the numbers over in a file.

## How the projection works

The weekly window is the seven days before `resets_at`. The burn rate is the
slope of the readings over the last 24 hours (at least 3 hours of them), or the
average since the window opened when there isn't that much history yet.
Projection = now + (100 − used) ÷ rate. If that lands before the reset, the top
card says when the cap runs out. "Even pace" is a straight line from 0% at the
window start to 100% at the reset: 14.3% a day.

## Commands

```
python3 aiusage.py serve     # what the LaunchAgent runs
python3 aiusage.py once      # print everything collected as JSON
python3 aiusage.py url       # print the links again
python3 -m unittest discover -s tests
```

## Security

- Listens on port 8787 on all interfaces so the iPad can reach it. Anything not
  from the Mac itself needs the key (`~/Library/Application Support/ai-usage/key`,
  0600). Compared in constant time; stored as an HttpOnly, SameSite=Strict cookie.
- Strict Content-Security-Policy: no inline scripts or styles, nothing loaded
  except this server and Google Fonts.
- Holds no credentials. The Claude snapshot it reads contains no token.
- Plain HTTP on the home network; over Tailscale the tunnel is encrypted.

## Files

| File | Purpose |
| --- | --- |
| `aiusage.py` | Collectors, burn-rate math, HTTP server |
| `web/` | The dashboard (`index.html`, `app.js`, `style.css`) |
| `config.example.json` | Plans and Ollama settings, copied on first install |
| `install.sh`, `uninstall.sh` | LaunchAgent setup |
| `tests/test_aiusage.py` | Fixture home, stub Ollama server, end-to-end checks |
