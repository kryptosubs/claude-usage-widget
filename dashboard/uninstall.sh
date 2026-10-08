#!/bin/bash
# Stop ai-usage and remove its LaunchAgent. Leaves config, key and log in place.
set -euo pipefail
LABEL="com.kryptohead.ai-usage"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
echo "Stopped. Config and access key remain in ~/Library/Application Support/ai-usage."
