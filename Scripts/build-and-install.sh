#!/bin/bash
# Rebuild LightData and (re)install it into /Applications so the Launchpad/Finder
# copy is updated. Usage: Scripts/build-and-install.sh [Debug|Release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-Release}"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DD=".build/xcode-dd"

echo "▸ Building LightData ($CONFIG)…"
xcodebuild -project LightData.xcodeproj -scheme LightData \
  -configuration "$CONFIG" -derivedDataPath "$DD" build >/dev/null

APP="$DD/Build/Products/$CONFIG/LightData.app"
[ -d "$APP" ] || { echo "✗ build product not found: $APP"; exit 1; }

echo "▸ Installing to /Applications…"
osascript -e 'tell application "LightData" to quit' 2>/dev/null || true
pkill -x LightData 2>/dev/null || true
sleep 1
rm -rf /Applications/LightData.app
cp -R "$APP" /Applications/LightData.app

echo "▸ Refreshing icon cache…"
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f /Applications/LightData.app
rm -rf "$(getconf DARWIN_USER_CACHE_DIR)/com.apple.iconservices.store" 2>/dev/null || true
killall iconservicesagent Dock Finder 2>/dev/null || true

echo "✓ Installed /Applications/LightData.app ($CONFIG)"
