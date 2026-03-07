#!/bin/bash
# deploy_to_phone.sh — Build and install TerminalApp to the connected iPhone.
# Can be run locally or via SSH from the Mac Mini.
#
# Usage: ./deploy_to_phone.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Unlock keychain for codesign (required when running via SSH)
CRED_FILE="$HOME/Documents/Claude code/credentials.py"
if [[ -f "$CRED_FILE" ]]; then
    KC_PASS=$(python3 -c "exec(open('$CRED_FILE').read()); print(KEYCHAIN_PASSWORD)" 2>/dev/null || echo "")
else
    KC_PASS=""
fi
if [[ -n "$KC_PASS" ]]; then
    security unlock-keychain -p "$KC_PASS" ~/Library/Keychains/login.keychain-db 2>/dev/null || true
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1 || true
fi

echo "=== Pulling latest code ==="
git fetch origin && git reset --hard origin/main

echo "=== Building TerminalApp ==="
xcodebuild -scheme TerminalApp \
    -destination 'generic/platform=iOS' \
    -configuration Debug \
    -allowProvisioningUpdates \
    -quiet \
    2>&1 | tail -5

APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/TerminalApp-*/Build/Products/Debug-iphoneos/TerminalApp.app -maxdepth 0 2>/dev/null | head -1)
if [[ -z "$APP_PATH" ]]; then
    echo "ERROR: Build product not found"
    exit 1
fi

echo "=== Installing to iPhone ==="
DEVICE_ID=$(xcrun devicectl list devices 2>/dev/null | grep -i iphone | awk '{for(i=1;i<=NF;i++) if($i ~ /^[A-F0-9]{8}-/) print $i}' | head -1)
if [[ -z "$DEVICE_ID" ]]; then
    echo "ERROR: No iPhone found. Is it connected/paired?"
    exit 1
fi

xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" 2>&1

echo "=== Done! TerminalApp installed ==="
