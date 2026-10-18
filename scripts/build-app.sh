#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
MONK_ARCHITECTURES=(arm64 x86_64)
MONK_INCLUDE_APP_SHORTCUTS=true
for MONK_ARGUMENT in "$@"; do
    case "$MONK_ARGUMENT" in
        --universal) MONK_ARCHITECTURES=(arm64 x86_64) ;;
        --native) MONK_ARCHITECTURES=("$(uname -m)") ;;
        --without-app-shortcuts) MONK_INCLUDE_APP_SHORTCUTS=false ;;
        *) echo "Usage: bash scripts/build-app.sh [--universal|--native] [--without-app-shortcuts]" >&2; exit 2 ;;
    esac
done
if "$MONK_INCLUDE_APP_SHORTCUTS"; then
    if ! MONK_INTENTS_PROCESSOR="$(xcrun --find appintentsmetadataprocessor 2>/dev/null)"; then
        echo "Apple Shortcuts metadata requires full Xcode. Set DEVELOPER_DIR to Xcode.app/Contents/Developer." >&2
        echo "For a local build without Apple Shortcuts actions, add --without-app-shortcuts." >&2
        exit 1
    fi
fi
MONK_BINARIES=()
MONK_CONST_VALUES=()
MONK_TARGET_ARGS=()
for MONK_ARCH in "${MONK_ARCHITECTURES[@]}"; do
    MONK_CONST_VALUES_PATH="$PWD/.build/distribution-$MONK_ARCH/MonkShift.swiftconstvalues"
    MONK_SWIFT_ARGS=(--disable-sandbox --scratch-path ".build/distribution-$MONK_ARCH"
        --cache-path .build/cache --config-path .build/config --security-path .build/security
        --triple "$MONK_ARCH-apple-macosx14.0" -c release
        -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file
        -Xswiftc -Xfrontend -Xswiftc "$PWD/Resources/AppIntentsProtocols.json"
        -Xswiftc -emit-const-values-path -Xswiftc "$MONK_CONST_VALUES_PATH")
    swift build "${MONK_SWIFT_ARGS[@]}" --product MonkShift
    MONK_BIN_DIR="$(swift build "${MONK_SWIFT_ARGS[@]}" --show-bin-path)"
    MONK_BINARIES+=("$MONK_BIN_DIR/MonkShift")
    MONK_CONST_VALUES+=("$MONK_CONST_VALUES_PATH")
    MONK_TARGET_ARGS+=(--target-triple "$MONK_ARCH-apple-macosx14.0")
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
if "$MONK_INCLUDE_APP_SHORTCUTS"; then
    MONK_CONST_VALUES_LIST="$PWD/.build/app-intents-const-values.txt"
    printf '%s\n' "${MONK_CONST_VALUES[@]}" > "$MONK_CONST_VALUES_LIST"
    MONK_SWIFT_COMPILER="$(xcrun --find swiftc)"
    MONK_TOOLCHAIN_DIR="$(dirname "$(dirname "$(dirname "$MONK_SWIFT_COMPILER")")")"
    MONK_XCODE_VERSION="$(xcodebuild -version | awk '/Build version/ {print $3}')"
    "$MONK_INTENTS_PROCESSOR" --module-name MonkShift \
        --bundle-identifier app.monkshift.MonkShift \
        --toolchain-dir "$MONK_TOOLCHAIN_DIR" --sdk-root "$(xcrun --show-sdk-path)" \
        --xcode-version "$MONK_XCODE_VERSION" --platform-family macOS --deployment-target 14.0 \
        "${MONK_TARGET_ARGS[@]}" --binary-file "$MONK_STAGE/Contents/MacOS/MonkShift" \
        --source-file-list "$MONK_BIN_DIR/MonkShift.build/sources" \
        --swift-const-vals-list "$MONK_CONST_VALUES_LIST" --compile-time-extraction \
        --output "$MONK_STAGE/Contents/Resources"
    test -s "$MONK_STAGE/Contents/Resources/Metadata.appintents/extract.actionsdata"
    test -s "$MONK_STAGE/Contents/Resources/Metadata.appintents/version.json"
else
    echo "Development build: Apple Shortcuts actions are excluded. Global keyboard shortcuts remain available."
fi
/usr/bin/codesign --force --sign - --options runtime \
    --entitlements Resources/MonkShift.entitlements "$MONK_STAGE"
/usr/bin/codesign --verify --strict --all-architectures "$MONK_STAGE"
rm -rf "$MONK_APP"
mv "$MONK_STAGE" "$MONK_APP"
echo "Built: $MONK_APP ($(lipo -archs "$MONK_APP/Contents/MacOS/MonkShift"), ad-hoc signed)"
