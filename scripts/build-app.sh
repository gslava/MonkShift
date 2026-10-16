#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
MONK_BUILD_MODE="${1:---universal}"
case "$MONK_BUILD_MODE" in
    --universal) MONK_ARCHITECTURES=(arm64 x86_64) ;;
    --native) MONK_ARCHITECTURES=("$(uname -m)") ;;
    *) echo "Usage: bash scripts/build-app.sh [--universal|--native]" >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
    echo "Usage: bash scripts/build-app.sh [--universal|--native]" >&2
    exit 2
fi
MONK_BINARIES=()
for MONK_ARCH in "${MONK_ARCHITECTURES[@]}"; do
    MONK_SWIFT_ARGS=(--disable-sandbox --scratch-path ".build/distribution-$MONK_ARCH"
        --cache-path .build/cache --config-path .build/config --security-path .build/security
        --triple "$MONK_ARCH-apple-macosx14.0" -c release)
    swift build "${MONK_SWIFT_ARGS[@]}" --product MonkShift
    MONK_BIN_DIR="$(swift build "${MONK_SWIFT_ARGS[@]}" --show-bin-path)"
    MONK_BINARIES+=("$MONK_BIN_DIR/MonkShift")
done
bash scripts/build-icon.sh
MONK_APP="$PWD/build/MonkShift.app"
MONK_STAGE="$PWD/build/package-staging/MonkShift.app"
# These two fixed paths contain generated app bundles only.
rm -rf "$MONK_STAGE"
mkdir -p "$MONK_STAGE/Contents/MacOS" "$MONK_STAGE/Contents/Resources"
if [ "${#MONK_BINARIES[@]}" -eq 2 ]; then
    lipo -create "${MONK_BINARIES[@]}" -output "$MONK_STAGE/Contents/MacOS/MonkShift"
else
    cp "${MONK_BINARIES[0]}" "$MONK_STAGE/Contents/MacOS/MonkShift"
fi
chmod +x "$MONK_STAGE/Contents/MacOS/MonkShift"
cp Resources/Info.plist "$MONK_STAGE/Contents/Info.plist"
cp LICENSE "$MONK_STAGE/Contents/Resources/LICENSE"
cp build/AppIcon.icns "$MONK_STAGE/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --force --sign - --options runtime \
    --entitlements Resources/MonkShift.entitlements "$MONK_STAGE"
/usr/bin/codesign --verify --strict --all-architectures "$MONK_STAGE"
rm -rf "$MONK_APP"
mv "$MONK_STAGE" "$MONK_APP"
echo "Built: $MONK_APP ($(lipo -archs "$MONK_APP/Contents/MacOS/MonkShift"), ad-hoc signed)"
