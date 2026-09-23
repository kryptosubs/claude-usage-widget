#!/bin/bash
# Build "Claude Usage.app" with nothing but the Xcode Command Line Tools.
#
#   ./build.sh              build into ./build
#   ./build.sh --install    build, copy to ~/Applications, and launch
#   ./build.sh --test       run the logic tests (no app build)
#   ./build.sh --universal  build for Apple silicon + Intel
#
# First time on a Mac without the tools:  xcode-select --install

set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
    echo "swiftc not found. Run: xcode-select --install" >&2
    exit 1
fi

CORE=(Sources/UsageCore.swift Sources/Credentials.swift Sources/UsageClient.swift)
MIN_OS=13.0

if [[ "${1:-}" == "--test" ]]; then
    mkdir -p build
    swiftc -O -target "$(uname -m)-apple-macos$MIN_OS" "${CORE[@]}" Tests/main.swift -o build/tests
    ./build/tests
    exit $?
fi

APP="build/Claude Usage.app"
BIN="$APP/Contents/MacOS/ClaudeUsage"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

compile() {  # $1 = arch, $2 = output
    swiftc -O -parse-as-library -target "$1-apple-macos$MIN_OS" \
        "${CORE[@]}" Sources/App.swift -o "$2"
}

if [[ "${1:-}" == "--universal" ]]; then
    compile arm64  build/ClaudeUsage-arm64
    compile x86_64 build/ClaudeUsage-x86_64
    lipo -create build/ClaudeUsage-arm64 build/ClaudeUsage-x86_64 -output "$BIN"
    rm -f build/ClaudeUsage-arm64 build/ClaudeUsage-x86_64
else
    compile "$(uname -m)" "$BIN"
fi

cp Info.plist "$APP/Contents/Info.plist"

# app icon (cosmetic: a failure here never fails the build)
if swift Tools/MakeIcon.swift build/AppIcon.iconset >/dev/null 2>&1 \
   && iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then
    :
else
    echo "(icon skipped)"
fi
rm -rf build/AppIcon.iconset

# ad-hoc signature: required on Apple silicon, and lets Login Items register it
codesign --force --sign - --timestamp=none "$APP" >/dev/null
echo "built: $APP"

if [[ "${1:-}" == "--install" ]]; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
    pkill -x ClaudeUsage 2>/dev/null || true
    rm -rf "$DEST/Claude Usage.app"
    ditto "$APP" "$DEST/Claude Usage.app"
    open "$DEST/Claude Usage.app"
    echo "installed: $DEST/Claude Usage.app (look for the ring in the menu bar)"
fi
