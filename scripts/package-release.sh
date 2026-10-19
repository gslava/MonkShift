#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
MONK_REPOSITORY="${MONKSHIFT_REPOSITORY:-gslava/MonkShift}"
if ! [[ "$MONK_REPOSITORY" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    echo "MONKSHIFT_REPOSITORY must be a GitHub OWNER/REPO." >&2
    exit 2
fi
MONK_RELEASE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
if ! [[ "$MONK_RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Expected a numeric major.minor.patch app version." >&2
    exit 2
fi
bash scripts/build-app.sh --universal
mkdir -p dist Casks
MONK_ARCHIVE_NAME="MonkShift-$MONK_RELEASE_VERSION-universal.zip"
MONK_ARCHIVE="$PWD/dist/$MONK_ARCHIVE_NAME"
ditto -c -k --sequesterRsrc --keepParent build/MonkShift.app "$MONK_ARCHIVE"
MONK_RELEASE_SHA="$(shasum -a 256 "$MONK_ARCHIVE" | awk '{print $1}')"
printf '%s  %s\n' "$MONK_RELEASE_SHA" "$MONK_ARCHIVE_NAME" > "$MONK_ARCHIVE.sha256"
MONK_DMG_NAME="MonkShift-$MONK_RELEASE_VERSION-universal.dmg"
MONK_DMG="$PWD/dist/$MONK_DMG_NAME"
bash scripts/create-dmg.sh build/MonkShift.app "$MONK_DMG"
MONK_DMG_SHA="$(shasum -a 256 "$MONK_DMG" | awk '{print $1}')"
printf '%s  %s\n' "$MONK_DMG_SHA" "$MONK_DMG_NAME" > "$MONK_DMG.sha256"
cat > Casks/monkshift.rb <<RUBY
cask "monkshift" do
  version "$MONK_RELEASE_VERSION"
  sha256 "$MONK_RELEASE_SHA"

  url "https://github.com/$MONK_REPOSITORY/releases/download/v#{version}/MonkShift-#{version}-universal.zip"
  name "MonkShift"
  desc "Offline focus controls for Dock, Stage Manager and display settings"
  homepage "https://github.com/$MONK_REPOSITORY"

  depends_on macos: :sonoma

  app "MonkShift.app"

  uninstall quit: "app.monkshift.MonkShift"

  caveats <<~EOS
    MonkShift is ad-hoc signed and is not notarized with an Apple Developer ID.
    macOS may require approval in System Settings > Privacy & Security on first launch.
    Grant Automation access to System Events when MonkShift asks.
    Restore All Changes before uninstalling if you want your previous settings back.
    Saved restore records are retained in ~/Library/Application Support/MonkShift.
  EOS
end
RUBY
cp Casks/monkshift.rb dist/monkshift.rb
cat > dist/release.json <<JSON
{
  "version": "$MONK_RELEASE_VERSION",
  "tag": "v$MONK_RELEASE_VERSION",
  "repository": "$MONK_REPOSITORY",
  "archive": "$MONK_ARCHIVE_NAME",
  "sha256": "$MONK_RELEASE_SHA",
  "url": "https://github.com/$MONK_REPOSITORY/releases/download/v$MONK_RELEASE_VERSION/$MONK_ARCHIVE_NAME",
  "dmg": {
    "archive": "$MONK_DMG_NAME",
    "sha256": "$MONK_DMG_SHA",
    "url": "https://github.com/$MONK_REPOSITORY/releases/download/v$MONK_RELEASE_VERSION/$MONK_DMG_NAME"
  },
  "architectures": ["arm64", "x86_64"],
  "minimum_macos": "14.0",
  "signature": "ad-hoc",
  "notarized": false
}
JSON
bash scripts/verify-release.sh "$MONK_ARCHIVE" "$MONK_DMG"
echo "Prepared: $MONK_ARCHIVE"
echo "Prepared: $MONK_DMG"
echo "Cask: $PWD/Casks/monkshift.rb"
echo "Nothing has been uploaded or published."
