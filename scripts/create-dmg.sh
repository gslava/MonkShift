#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -ne 2 ]; then
    echo "Usage: bash scripts/create-dmg.sh <MonkShift.app> <output.dmg>" >&2
    exit 2
fi
MONK_DMG_APP="$(cd "$1" && pwd)"
MONK_DMG_OUTPUT="$2"
if [[ "$MONK_DMG_OUTPUT" != *.dmg ]]; then
    echo "Output must have a .dmg extension." >&2
    exit 2
fi
MONK_DMG_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MONK_DMG_APP/Contents/Info.plist")"
MONK_DMG_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$MONK_DMG_APP/Contents/Info.plist")"
test "$MONK_DMG_BUNDLE_ID" = "app.monkshift.MonkShift"
codesign --verify --strict --all-architectures "$MONK_DMG_APP"
mkdir -p build "$(dirname "$MONK_DMG_OUTPUT")"
MONK_DMG_STAGE="$(mktemp -d "$PWD/build/dmg-staging.XXXXXX")"
trap 'rm -rf "$MONK_DMG_STAGE"' EXIT
ditto "$MONK_DMG_APP" "$MONK_DMG_STAGE/MonkShift.app"
ln -s /Applications "$MONK_DMG_STAGE/Applications"
cat > "$MONK_DMG_STAGE/Read Me.txt" <<'TEXT'
Install MonkShift

Drag MonkShift.app onto Applications, then eject this disk image.
Open MonkShift from Applications and grant Automation access to System Events.
Use Restore All Changes before uninstalling to recover your earlier settings.

This app is ad-hoc signed and is not notarized with an Apple Developer ID.
macOS may require per-app approval in System Settings > Privacy & Security.
Installation does not change system settings or grant permissions.
TEXT
hdiutil create -volname "MonkShift $MONK_DMG_VERSION" -srcfolder "$MONK_DMG_STAGE" \
    -fs HFS+ -format UDZO -ov "$MONK_DMG_OUTPUT"
hdiutil verify "$MONK_DMG_OUTPUT"
echo "Created: $MONK_DMG_OUTPUT"
