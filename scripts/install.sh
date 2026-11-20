#!/bin/bash
# Installs FlowScribe.app into ~/Applications.
#
# NOTE: This script deliberately does NOT run `swift build`. Build the release
# binary yourself first with:
#
#   swift build -c release
#
# then run this script, passing the path to the built executable (or let the
# script look for it in the default location).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="FlowScribe"
APP_DIR="${HOME}/Applications/${APP_NAME}.app"
MACOS_DIR="${APP_DIR}/Contents/MacOS"
RESOURCES_DIR="${APP_DIR}/Contents/Resources"
CLI_PATH="${HOME}/.local/bin/flowscribe"

# Locate the release binary (override with FLOWSCRIBE_BIN=/path/to/flow ...).
DEFAULT_BIN="${REPO_DIR}/.build/release/FlowScribe"
BIN="${FLOWSCRIBE_BIN:-$DEFAULT_BIN}"

if [ ! -x "$BIN" ]; then
    echo "error: executable not found at $BIN"
    echo "       build it first:  swift build -c release"
    echo "       or point at it:  FLOWSCRIBE_BIN=/path/to/binary $0"
    exit 1
fi

echo "Assembling ${APP_DIR} ..."
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "${REPO_DIR}/Resources/FlowScribe.icns" "$RESOURCES_DIR/FlowScribe.icns"

cat > "${APP_DIR}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>FlowScribe</string>
    <key>CFBundleIdentifier</key>
    <string>com.flowscribe.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>FlowScribe</string>
    <key>CFBundleIconFile</key>
    <string>FlowScribe.icns</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>FlowScribe records short microphone clips locally and sends them to OpenAI for transcription. Audio is never stored after the transcript is delivered.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>FlowScribe returns focus to the app you were typing in.</string>
</dict>
</plist>
PLIST

# Replace the executable by rename so running MCP processes keep their original binary.
STAGED_BIN="$(mktemp "$MACOS_DIR/.FlowScribe.XXXXXX")"
trap 'rm -f "$STAGED_BIN"' EXIT
cp "$BIN" "$STAGED_BIN"
chmod 755 "$STAGED_BIN"
mv -f "$STAGED_BIN" "$MACOS_DIR/FlowScribe"

# Clear stale quarantine/extended attributes if present.
xattr -cr "$APP_DIR" 2>/dev/null || true

# SwiftPM's executable is linker-signed. Sign the assembled bundle itself with
# a stable identifier and designated requirement so macOS Accessibility tracks
# FlowScribe across local rebuilds instead of tying permission to one binary hash.
codesign --force --deep --sign - \
    --identifier "com.flowscribe.app" \
    --requirements '=designated => identifier "com.flowscribe.app"' \
    "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

mkdir -p "$(dirname "$CLI_PATH")"
if [ ! -e "$CLI_PATH" ] && [ ! -L "$CLI_PATH" ]; then
    ln -s "$MACOS_DIR/FlowScribe" "$CLI_PATH"
elif [ "$(readlink "$CLI_PATH" || true)" != "$MACOS_DIR/FlowScribe" ]; then
    echo "CLI link skipped because $CLI_PATH already exists. Use $MACOS_DIR/FlowScribe directly." >&2
fi

echo "Installed. Launch with:"
echo "  open ${APP_DIR}"
echo ""
echo "Next steps:"
echo "  1. Export OPENAI_API_KEY in the shell you launch from, or set a key via the menu bar app's Settings."
echo "  2. Grant Microphone permission when prompted."
echo "  3. Grant Accessibility permission for automatic pasting (optional; clipboard fallback otherwise)."
