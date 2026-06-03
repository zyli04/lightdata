#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/.build/app/LightData.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$ROOT_DIR"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$ROOT_DIR/.build/release/LightData" "$MACOS_DIR/LightData"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>LightData</string>
  <key>CFBundleDisplayName</key>
  <string>LightData</string>
  <key>CFBundleIdentifier</key>
  <string>local.lightdata.app</string>
  <key>CFBundleVersion</key>
  <string>0.1.0</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleExecutable</key>
  <string>LightData</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Delimited and Structured Data</string>
      <key>CFBundleTypeRole</key>
      <string>Editor</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>csv</string>
        <string>tsv</string>
        <string>json</string>
        <string>jsonl</string>
        <string>xlsx</string>
        <string>parquet</string>
        <string>pq</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# App icon: if Resources/AppIcon.png (1024x1024) exists, generate AppIcon.icns
# from it; otherwise use a prebuilt Resources/AppIcon.icns if present.
ICON_PNG="$ROOT_DIR/Resources/AppIcon.png"
ICON_ICNS="$ROOT_DIR/Resources/AppIcon.icns"
if [ -f "$ICON_PNG" ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size * 2))" "$((size * 2))" "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$ICON_ICNS"
  rm -rf "$(dirname "$ICONSET")"
fi
if [ -f "$ICON_ICNS" ]; then
  cp "$ICON_ICNS" "$RESOURCES_DIR/AppIcon.icns"
else
  echo "Note: no Resources/AppIcon.png or Resources/AppIcon.icns found; building without a custom icon."
fi

codesign --force --deep --sign - "$APP_DIR"

echo "Built $APP_DIR"
