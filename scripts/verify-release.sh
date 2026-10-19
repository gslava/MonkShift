#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -gt 2 ]; then
    echo "Usage: bash scripts/verify-release.sh [archive.zip] [image.dmg]" >&2
    exit 2
fi
MONK_EXPECTED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
MONK_ARCHIVE="${1:-$PWD/dist/MonkShift-$MONK_EXPECTED_VERSION-universal.zip}"
MONK_DMG="${2:-${MONK_ARCHIVE%.zip}.dmg}"
if [ ! -f "$MONK_ARCHIVE" ] || [ ! -f "$MONK_ARCHIVE.sha256" ]; then
    echo "Archive and adjacent .sha256 file are required: $MONK_ARCHIVE" >&2
    exit 1
fi
if [ ! -f "$MONK_DMG" ] || [ ! -f "$MONK_DMG.sha256" ]; then
    echo "DMG and adjacent .sha256 file are required: $MONK_DMG" >&2
    exit 1
fi
MONK_ARCHIVE_DIR="$(cd "$(dirname "$MONK_ARCHIVE")" && pwd)"
MONK_ARCHIVE_NAME="$(basename "$MONK_ARCHIVE")"
MONK_ARCHIVE="$MONK_ARCHIVE_DIR/$MONK_ARCHIVE_NAME"
(cd "$MONK_ARCHIVE_DIR" && shasum -a 256 -c "$MONK_ARCHIVE_NAME.sha256")
MONK_DMG_DIR="$(cd "$(dirname "$MONK_DMG")" && pwd)"
MONK_DMG_NAME="$(basename "$MONK_DMG")"
MONK_DMG="$MONK_DMG_DIR/$MONK_DMG_NAME"
(cd "$MONK_DMG_DIR" && shasum -a 256 -c "$MONK_DMG_NAME.sha256")
hdiutil verify "$MONK_DMG"
mkdir -p build
MONK_VERIFY_DIR="$(mktemp -d "$PWD/build/release-verify.XXXXXX")"
MONK_DMG_MOUNT="$MONK_VERIFY_DIR/dmg"
MONK_DMG_MOUNTED=false
cleanup() {
    MONK_VERIFY_STATUS=$?
    if "$MONK_DMG_MOUNTED"; then
        if ! hdiutil detach "$MONK_DMG_MOUNT" -quiet; then
            echo "Could not eject the verification image at $MONK_DMG_MOUNT; temporary files retained." >&2
            return 1
        fi
    fi
    rm -rf "$MONK_VERIFY_DIR"
    return "$MONK_VERIFY_STATUS"
}
trap cleanup EXIT
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
if [ ! -s "$MONK_VERIFY_APP/Contents/Resources/Metadata.appintents/extract.actionsdata" ] || \
   [ ! -s "$MONK_VERIFY_APP/Contents/Resources/Metadata.appintents/version.json" ]; then
    echo "Release app is missing Apple Shortcuts metadata. Build with full Xcode." >&2
    exit 1
fi
test -x "$MONK_VERIFY_APP/Contents/MacOS/MonkShift"
lipo "$MONK_VERIFY_APP/Contents/MacOS/MonkShift" -verify_arch arm64 x86_64
codesign --verify --strict --all-architectures "$MONK_VERIFY_APP"
case "$(codesign -dv "$MONK_VERIFY_APP" 2>&1)" in
    *Signature=adhoc*) ;;
    *) echo "Expected the documented ad-hoc signature." >&2; exit 1 ;;
esac
mkdir "$MONK_DMG_MOUNT"
hdiutil attach "$MONK_DMG" -readonly -nobrowse -noautoopen -mountpoint "$MONK_DMG_MOUNT" -quiet
MONK_DMG_MOUNTED=true
test -L "$MONK_DMG_MOUNT/Applications"
test "$(readlink "$MONK_DMG_MOUNT/Applications")" = "/Applications"
test -s "$MONK_DMG_MOUNT/Read Me.txt"
codesign --verify --strict --all-architectures "$MONK_DMG_MOUNT/MonkShift.app"
diff -qr "$MONK_VERIFY_APP" "$MONK_DMG_MOUNT/MonkShift.app"
MONK_EXPECTED_SHA="$(shasum -a 256 "$MONK_ARCHIVE" | awk '{print $1}')"
MONK_EXPECTED_DMG_SHA="$(shasum -a 256 "$MONK_DMG" | awk '{print $1}')"
ruby -rjson -e '
  release = JSON.parse(File.read(ARGV[0]))
  version, zip_name, zip_sha, dmg_name, dmg_sha = ARGV[1..-1]
  repository = release.fetch("repository")
  abort "Invalid release repository" unless repository.match?(/\A[A-Za-z0-9][A-Za-z0-9_.-]*\/[A-Za-z0-9][A-Za-z0-9_.-]*\z/)
  base = "https://github.com/#{repository}/releases/download/v#{version}"
  expected = {"version" => version, "tag" => "v#{version}", "archive" => zip_name,
    "sha256" => zip_sha, "url" => "#{base}/#{zip_name}", "minimum_macos" => "14.0",
    "signature" => "ad-hoc", "notarized" => false,
    "dmg" => {"archive" => dmg_name, "sha256" => dmg_sha, "url" => "#{base}/#{dmg_name}"}}
  abort "Release metadata does not match the verified downloads" unless expected.all? { |key, value| release[key] == value }
  abort "Release architectures do not match" unless release.fetch("architectures").sort == ["arm64", "x86_64"]
' "$MONK_ARCHIVE_DIR/release.json" "$MONK_EXPECTED_VERSION" "$MONK_ARCHIVE_NAME" "$MONK_EXPECTED_SHA" "$MONK_DMG_NAME" "$MONK_EXPECTED_DMG_SHA"
MONK_RELEASE_CASK="$MONK_ARCHIVE_DIR/monkshift.rb"
if [ ! -f "$MONK_RELEASE_CASK" ]; then MONK_RELEASE_CASK="$PWD/Casks/monkshift.rb"; fi
ruby -c "$MONK_RELEASE_CASK"
ruby -e '
  text = File.read(ARGV[0])
  abort "Cask checksum does not match archive" unless text.include?(%Q[sha256 "#{ARGV[1]}"])
  abort "Cask version does not match bundle" unless text.include?(%Q[version "#{ARGV[2]}"])
' "$MONK_RELEASE_CASK" "$MONK_EXPECTED_SHA" "$MONK_EXPECTED_VERSION"
echo "Verified Universal ZIP and DMG, checksums, matching apps, Applications link, signature, Shortcuts metadata and cask. App was not launched."
