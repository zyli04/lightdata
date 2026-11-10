#!/bin/zsh
# Runs LightData's full automated test suite:
#   1. LightDataCore unit tests (parsers, document model, lazy paging) — fast, headless.
#   2. App integration tests — hosted inside the real app process, driving actual
#      MainWindowController windows (editing, undo, close prompts, lazy copy).
#      These briefly open app windows on screen; that's expected.
#
# Usage: scripts/test.sh [core|app]
set -euo pipefail
cd "$(dirname "$0")/.."

# CI (or a second Xcode install) can point this elsewhere: XCODE=/path/Contents/Developer
XCODE="${XCODE:-/Applications/Xcode.app/Contents/Developer}"
MODE="${1:-all}"

if [[ "$MODE" == "core" || "$MODE" == "all" ]]; then
    echo "==> LightDataCore unit tests"
    (cd LightDataCore && DEVELOPER_DIR="$XCODE" xcrun --toolchain default swift test 2>&1 \
        | grep -E "Executed [0-9]+ tests|error:|failed" | tail -4)
fi

if [[ "$MODE" == "app" || "$MODE" == "all" ]]; then
    echo "==> App integration tests (opens windows briefly)"
    "$XCODE/usr/bin/xcodebuild" test \
        -project LightData.xcodeproj -scheme LightData \
        -configuration Debug -derivedDataPath .build/dd 2>&1 \
        | grep -E "Executed [0-9]+ tests|TEST (SUCCEEDED|FAILED)|: error: -\[|\.swift:[0-9]+:[0-9]+: error:"
fi

echo "==> done"
