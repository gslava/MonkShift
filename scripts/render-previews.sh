#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
MONK_UPDATE_README=false
case "${1:-}" in
    "") ;;
    --readme) MONK_UPDATE_README=true ;;
    *) echo "Usage: bash scripts/render-previews.sh [--readme]" >&2; exit 2 ;;
esac
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
swift run --disable-sandbox --scratch-path .build/preview --cache-path .build/cache \
    --config-path .build/config --security-path .build/security -Xswiftc -DMONKSHIFT_PREVIEW MonkShift "$PWD/build/previews"
if "$MONK_UPDATE_README"; then
    mkdir -p docs/images
    cp build/previews/controls-monkSession-light.png docs/images/controls-light.png
    cp build/previews/controls-monkSession-dark.png docs/images/controls-dark.png
    cp build/previews/permission-light.png docs/images/permission-light.png
    cp build/previews/intensity-menu-active-light.png docs/images/intensity-menu-light.png
    cp build/previews/intensity-menu-off-dark.png docs/images/intensity-menu-off-dark.png
    cp build/previews/focus-dimming-light.png docs/images/focus-dimming-light.png
    cp build/previews/focus-dimming-dark.png docs/images/focus-dimming-dark.png
    cp build/previews/dimming-menu-active-light.png docs/images/dimming-menu-light.png
    cp build/previews/dimming-menu-off-dark.png docs/images/dimming-menu-off-dark.png
    echo "Updated fixture screenshots in docs/images."
fi
