#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT_DIR/Scripts/build-quicklook.sh"

INSTALL_DIR="$HOME/Library/QuickLook"
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/LightDataQuickLook.qlgenerator"
cp -R "$ROOT_DIR/.build/quicklook/LightDataQuickLook.qlgenerator" "$INSTALL_DIR/"

qlmanage -r >/dev/null
qlmanage -r cache >/dev/null

echo "Installed $INSTALL_DIR/LightDataQuickLook.qlgenerator"
