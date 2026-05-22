#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/QuickLook/LightDataQuickLook"
OUT_DIR="$ROOT_DIR/.build/quicklook/LightDataQuickLook.qlgenerator"
CONTENTS_DIR="$OUT_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

rm -rf "$OUT_DIR"
mkdir -p "$MACOS_DIR"

cp "$SOURCE_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"

clang -bundle \
  -fobjc-arc \
  -framework Foundation \
  -framework QuickLook \
  "$SOURCE_DIR/GeneratePreviewForURL.m" \
  -o "$MACOS_DIR/LightDataQuickLook"

echo "Built $OUT_DIR"
