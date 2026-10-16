#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
MONK_ICONSET="$PWD/build/AppIcon.iconset"
mkdir -p "$MONK_ICONSET"
for MONK_ICON_SIZE in 16 32 128 256 512; do
    sips -z "$MONK_ICON_SIZE" "$MONK_ICON_SIZE" Resources/AppIcon.png \
        --out "$MONK_ICONSET/icon_${MONK_ICON_SIZE}x${MONK_ICON_SIZE}.png" >/dev/null
    MONK_RETINA_SIZE=$((MONK_ICON_SIZE * 2))
    sips -z "$MONK_RETINA_SIZE" "$MONK_RETINA_SIZE" Resources/AppIcon.png \
        --out "$MONK_ICONSET/icon_${MONK_ICON_SIZE}x${MONK_ICON_SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$MONK_ICONSET" -o "$PWD/build/AppIcon.icns"
echo "Built: $PWD/build/AppIcon.icns"
