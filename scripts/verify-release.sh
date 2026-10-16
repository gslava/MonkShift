#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
MONK_EXPECTED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
MONK_ARCHIVE="${1:-$PWD/dist/MonkShift-$MONK_EXPECTED_VERSION-universal.zip}"
if [ ! -f "$MONK_ARCHIVE" ] || [ ! -f "$MONK_ARCHIVE.sha256" ]; then
    echo "Archive and adjacent .sha256 file are required: $MONK_ARCHIVE" >&2
    exit 1
fi
MONK_ARCHIVE_DIR="$(cd "$(dirname "$MONK_ARCHIVE")" && pwd)"
MONK_ARCHIVE_NAME="$(basename "$MONK_ARCHIVE")"
MONK_ARCHIVE="$MONK_ARCHIVE_DIR/$MONK_ARCHIVE_NAME"
(cd "$MONK_ARCHIVE_DIR" && shasum -a 256 -c "$MONK_ARCHIVE_NAME.sha256")
mkdir -p build
MONK_VERIFY_DIR="$(mktemp -d "$PWD/build/release-verify.XXXXXX")"
trap 'rm -rf "$MONK_VERIFY_DIR"' EXIT
ditto -x -k "$MONK_ARCHIVE" "$MONK_VERIFY_DIR"
MONK_VERIFY_APP="$MONK_VERIFY_DIR/MonkShift.app"
plutil -lint "$MONK_VERIFY_APP/Contents/Info.plist"
MONK_BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MONK_VERIFY_APP/Contents/Info.plist")"
MONK_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$MONK_VERIFY_APP/Contents/Info.plist")"
MONK_BUNDLE_ICON="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$MONK_VERIFY_APP/Contents/Info.plist")"
MONK_BUNDLE_MINIMUM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$MONK_VERIFY_APP/Contents/Info.plist")"
test "$MONK_BUNDLE_VERSION" = "$MONK_EXPECTED_VERSION"
test "$MONK_BUNDLE_ID" = "app.monkshift.MonkShift"
test "$MONK_BUNDLE_ICON" = "AppIcon.icns"
test "$MONK_BUNDLE_MINIMUM" = "14.0"
test -s "$MONK_VERIFY_APP/Contents/Resources/AppIcon.icns"
test -s "$MONK_VERIFY_APP/Contents/Resources/LICENSE"
test -x "$MONK_VERIFY_APP/Contents/MacOS/MonkShift"
lipo "$MONK_VERIFY_APP/Contents/MacOS/MonkShift" -verify_arch arm64 x86_64
codesign --verify --strict --all-architectures "$MONK_VERIFY_APP"
case "$(codesign -dv "$MONK_VERIFY_APP" 2>&1)" in
    *Signature=adhoc*) ;;
    *) echo "Expected the documented ad-hoc signature." >&2; exit 1 ;;
esac
MONK_EXPECTED_SHA="$(shasum -a 256 "$MONK_ARCHIVE" | awk '{print $1}')"
ruby -c Casks/monkshift.rb
ruby -e '
  text = File.read(ARGV[0])
  abort "Cask checksum does not match archive" unless text.include?(%Q[sha256 "#{ARGV[1]}"])
  abort "Cask version does not match bundle" unless text.include?(%Q[version "#{ARGV[2]}"])
' Casks/monkshift.rb "$MONK_EXPECTED_SHA" "$MONK_EXPECTED_VERSION"
echo "Verified Universal archive, checksum, signature, icon, bundle metadata and cask. App was not launched."
