# Claude Usage (macOS)

The Mac version of the widget: a menu-bar ring showing your 5-hour session
usage, a popover with every limit, and an optional floating card that matches the
Windows widget row for row. English and Traditional Chinese.

It's a native Swift app, and building it needs nothing beyond the Xcode Command
Line Tools. There's no Xcode project, no dependencies, and no second sign-in: it
reads the login Claude Code already has.

## Install

```
xcode-select --install          # once, if you don't have the tools
cd mac
./build.sh --install            # builds, copies to ~/Applications, launches
```

Look for a small ring and a percentage in the menu bar. There is no Dock icon.
The first launch also opens the floating card, so you can see it working.
Launching the app again while it is running opens the popover (or the card, if
the menu bar is hiding the ring). Turn on **Open at login** (gear menu, or
right-click the floating card) so it starts with the Mac.

Other build modes: `./build.sh` (build only), `./build.sh --test` (run the logic
tests), `./build.sh --universal` (Apple silicon + Intel binary).

Requires macOS 13 or later.

## What you see

| Where | What |
| --- | --- |
| Menu bar | Ring plus the percentage. Green below 75%, amber at 75%, red at 90% or when the server marks it critical. Hover it for every limit at once. |
| Click the ring | Popover: account, every limit with its full countdown and reset time, and buttons for Refresh, Show widget, and the gear menu. Drag it away from the menu bar and it becomes its own window that you can move anywhere; it follows the Keep on top setting and closes with its close button. |
| Gear menu | What the menu bar shows (5-hour / weekly / whichever is highest), language, keep widget on top, open at login, copy diagnostics, quit |
| Floating widget | The Windows card: 224pt wide, one 18pt line per limit with the bar behind the text. Drag it by any part of the card to anywhere on any display; it remembers where you left it. **Keep on top** (on by default) keeps it above other apps; turn it off and it behaves like an ordinary window that other apps can cover and a click brings forward. Right-click it for refresh, keep on top, open at login, transparency, hide and quit. |

## Where the login comes from

Claude Code on macOS keeps its OAuth login in either of two places, and the app
checks both:

1. The **login Keychain**, generic password `Claude Code-credentials` (plus any
   suffixed variant created by `CLAUDE_CONFIG_DIR`)
2. `~/.claude/.credentials.json`

Logins are ranked by expiry, never by the order they were found, so a stale login
can't beat the live one.

The Keychain is read through `/usr/bin/security`, the same tool Claude Code uses
to write the item. That tool is already on the item's access list, so you don't
get a "wants to use your confidential information" prompt.

## Staying signed in: the one difference from Windows

Refresh tokens **rotate**: each one works once, and the server issues a new one
when it is used. The Windows widget stores its own copy of the rotated token and
never touches Claude Code's file. The side effect is that the first time the widget
refreshes, the copy Claude Code holds stops working.

The Mac app writes the refreshed pair back into the Keychain item or file it came
from, updating only the three token fields and leaving the rest untouched. The
widget and Claude Code then share one chain, and neither logs the other out. It
refreshes only after the access token has expired. While you're using Claude Code,
it usually renews the token first, and the app just picks up the new one. If a
write-back fails, the new refresh token goes into the app's own Keychain item
(`com.kryptohead.claude-usage`) so the chain isn't lost.

A **"no login"** or **"auth"** status means run `claude` in Terminal, then `/login`.
`claude setup-token` tokens don't work: the usage endpoint rejects them with 403.

## Diagnostics

Choose **Copy diagnostics** from the gear menu, or run:

```
~/Applications/Claude\ Usage.app/Contents/MacOS/ClaudeUsage --diagnose
```

It prints every login found with its expiry, the refresh endpoints that respond, the
login that served the request, the account, the rows as displayed, and the raw
response.

| Status | Meaning |
| --- | --- |
| `live` / `2m ago` | Fresh data |
| `no login` | No Claude Code login on this Mac |
| `auth` | The login expired and can't be refreshed. Run `/login`. |
| `throttled` | Rate limited (429). Backing off; the last good numbers stay on screen. |
| `offline` | Network or endpoint error. Copy diagnostics. |

## Notes

- Polls every 180 s and doubles the interval on each failure, capping at about
  96 min. Don't go faster: the endpoint rate-limits hard, and the `User-Agent:
  claude-code/...` header is what keeps requests out of the harshest bucket.
- Rows come from the response's `limits` array, with the older named fields as a
  fallback. Codename placeholders in the payload are ignored. Money is in minor
  units and gets scaled by its exponent.
- `--snapshot <dir>` renders the popover and widget to PNGs in both languages
  from live data, which is handy for checking layout without clicking anything.
- Startup events go to `~/Library/Logs/ClaudeUsage.log` (never tokens).
- **Open at login** registers with `SMAppService` (it appears under System
  Settings > General > Login Items). If macOS refuses that for an ad-hoc-signed
  build, the app writes `~/Library/LaunchAgents/com.kryptohead.claude-usage.plist`
  instead. `--check-login-item` switches it on and off again and prints the result.
- Settings live in the app's standard defaults (`com.kryptohead.claude-usage`).
  No token is ever written to disk outside the Keychain or Claude Code's own file.

## Files

| File | Purpose |
| --- | --- |
| `Sources/UsageCore.swift` | Payload → rows, countdowns, money, EN/繁中 strings. Foundation only. |
| `Sources/Credentials.swift` | Keychain/file discovery, ranking, write-back |
| `Sources/UsageClient.swift` | Token refresh (single-flight), API calls, diagnostics |
| `Sources/App.swift` | Menu bar, popover, floating panel, login item |
| `Tests/main.swift` | 52 checks, including a rotating-token stub server |
| `Tools/MakeIcon.swift` | Draws the app icon at build time |
| `build.sh`, `Info.plist` | Build without Xcode |
