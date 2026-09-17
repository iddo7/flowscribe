#!/bin/bash
# Removes FlowScribe.app from ~/Applications and offers to delete the saved Keychain item.

set -euo pipefail

APP_DIR="${HOME}/Applications/FlowScribe.app"

if [ -d "$APP_DIR" ]; then
    osascript -e 'tell application "FlowScribe" to quit' 2>/dev/null || true
    sleep 1
    rm -rf "$APP_DIR"
    echo "Removed ${APP_DIR}"
else
    echo "No FlowScribe.app found in ${HOME}/Applications"
fi

read -r -p "Also delete the saved OpenAI API key from your Keychain? [y/N] " answer
if [[ "${answer:-N}" =~ ^[Yy]$ ]]; then
    security delete-generic-password -s "com.flowscribe.app" -a "openai-api-key" 2>/dev/null \
        && echo "Keychain item deleted." \
        || echo "No matching Keychain item found (or deletion denied)."
fi
