#!/bin/bash
# Install (or update) ai-usage as a LaunchAgent on this Mac. Safe to run again.
#
#   bash install.sh            run the tests, install, start, print the links
#   bash install.sh --no-test  skip the tests
#
# Needs only Python 3.9+ (the Xcode Command Line Tools provide it).

set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd -P)"
LABEL="com.kryptohead.ai-usage"
APP="$HOME/Library/Application Support/ai-usage"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/ai-usage.log"
SNAP="$HOME/Library/Application Support/ClaudeUsage/latest.json"

PY="$(command -v python3 || true)"
if [[ -z "$PY" ]]; then
    echo "python3 not found. Run: xcode-select --install" >&2
    exit 1
fi
# /usr/bin/python3 is a shim; launchd should run the real interpreter
PY="$("$PY" -c 'import sys; print(sys.executable)')"
if ! "$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)'; then
    echo "Python 3.9 or later is needed ($PY is older)." >&2
    exit 1
fi

if [[ "${1:-}" != "--no-test" ]]; then
    echo "Running tests..."
    "$PY" -m unittest discover -s tests -q
fi

mkdir -p "$APP" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
chmod 700 "$APP"
if [[ ! -f "$APP/config.json" ]]; then
    cp config.example.json "$APP/config.json"
    echo "Created $APP/config.json (plans and prices; edit it any time)."
fi
PORT="$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("port", 8787))' "$APP/config.json")"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>             <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PY</string>
        <string>$ROOT/aiusage.py</string>
        <string>serve</string>
    </array>
    <key>WorkingDirectory</key>  <string>$ROOT</string>
    <key>RunAtLoad</key>         <true/>
    <key>KeepAlive</key>         <true/>
    <key>ProcessType</key>       <string>Background</string>
    <key>StandardOutPath</key>   <string>$LOG</string>
    <key>StandardErrorPath</key> <string>$LOG</string>
</dict>
</plist>
EOF

DOMAIN="gui/$(id -u)"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"

ok=0
for _ in $(seq 1 15); do
    if curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then ok=1; break; fi
    sleep 1
done
if [[ $ok -ne 1 ]]; then
    echo "The server did not answer on port $PORT. Last log lines:" >&2
    tail -n 20 "$LOG" >&2 || true
    exit 1
fi

echo
echo "ai-usage $("$PY" aiusage.py --version) is running and starts at login."
"$PY" aiusage.py url
echo
echo "Open the iPad link once; the key is then remembered as a cookie."
echo "If macOS asks whether Python may accept incoming connections, choose Allow."
if [[ ! -f "$SNAP" ]]; then
    echo
    echo "Claude limits will stay empty until the Claude Usage menu-bar app (v1.3+)"
    echo "writes $SNAP."
    echo "Update it with:  cd \"$ROOT/../mac\" && bash build.sh --install"
fi
