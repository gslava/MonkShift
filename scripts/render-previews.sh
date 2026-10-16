#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
swift run --disable-sandbox --scratch-path .build/preview --cache-path .build/cache \
    --config-path .build/config --security-path .build/security -Xswiftc -DMONKSHIFT_PREVIEW MonkShift "$PWD/build/previews"
