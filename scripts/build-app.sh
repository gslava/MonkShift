#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
swift build --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security -c release --product MonkShift
MONK_BIN_DIR="$(swift build --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security -c release --show-bin-path)"
MONK_APP="$PWD/build/MonkShift.app"
mkdir -p "$MONK_APP/Contents/MacOS" "$MONK_APP/Contents/Resources"
cp "$MONK_BIN_DIR/MonkShift" "$MONK_APP/Contents/MacOS/MonkShift"
cp Resources/Info.plist "$MONK_APP/Contents/Info.plist"
cp LICENSE "$MONK_APP/Contents/Resources/LICENSE"
/usr/bin/codesign --force --sign "${MONKSHIFT_SIGN_IDENTITY:--}" --options runtime \
    --entitlements Resources/MonkShift.entitlements "$MONK_APP"
/usr/bin/codesign --verify --strict "$MONK_APP"
echo "Built: $MONK_APP"
