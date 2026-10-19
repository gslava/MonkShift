#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -ne 1 ] || ! [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Expected one release tag: v<major>.<minor>.<patch>." >&2
    exit 2
fi
MONK_TAG_VERSION="${1#v}"
MONK_APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
if [ "$MONK_TAG_VERSION" != "$MONK_APP_VERSION" ]; then
    echo "Tag $1 does not match app version $MONK_APP_VERSION in Resources/Info.plist." >&2
    exit 1
fi
echo "Release tag $1 matches the app version."
